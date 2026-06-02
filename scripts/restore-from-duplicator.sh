#!/usr/bin/env bash
# restore-from-duplicator.sh
#
# End-to-end Duplicator Pro restore for sites running on the
# fogrise/truevape/uniquepeturn architecture (nginx + PHP-FPM 8.3 +
# MySQL 8.0 + Redis + WP-CLI in Docker Compose).
#
# Avoids every pitfall hit on truevape.ca:
#   - Never runs installer.php, so no DUPLICATOR_AUTH_KEY / WP_MEMORY_LIMIT
#     residue in wp-config.php
#   - Imports DB after a single, real-domain wp search-replace, so no
#     localhost:9999 references end up in the DB
#   - Runs `wp core update-db` so WooCommerce-style pending migrations
#     don't put the site in 503 maintenance mode
#   - Strips Apache/.htaccess/cache drop-ins/host-specific mu-plugins
#   - Pre-processes SQL for MariaDB -> MySQL 8.0 compatibility
#
# Usage:
#   scripts/restore-from-duplicator.sh <archive.daf> [installer.php]
#
# If installer.php is omitted, the script picks the lone *_installer.php
# next to the archive (or in the project root).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# -------- args --------
ARCHIVE="${1:-}"
INSTALLER="${2:-}"

if [[ -z "$ARCHIVE" ]]; then
  ARCHIVE=$(ls -1 *_archive.daf 2>/dev/null | head -1 || true)
fi
if [[ -z "$INSTALLER" ]]; then
  INSTALLER=$(ls -1 *_installer.php 2>/dev/null | head -1 || true)
fi

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "ERROR: archive not found. Pass it as arg 1 or place *_archive.daf next to docker-compose.yml" >&2
  exit 1
fi
if [[ -z "$INSTALLER" || ! -f "$INSTALLER" ]]; then
  echo "ERROR: installer.php not found. Pass it as arg 2 or place *_installer.php next to docker-compose.yml" >&2
  exit 1
fi

ARCHIVE_ABS=$(readlink -f "$ARCHIVE")
INSTALLER_ABS=$(readlink -f "$INSTALLER")

# Site identity defaults (override via env: SITE_HOST / NEW_URL / NGINX_PORT)
# - SITE_HOST_DEFAULT is auto-derived from the project folder name so this
#   script is reusable across all sister sites without per-site edits.
# - NGINX_PORT_DEFAULT is auto-detected from docker-compose.yml's nginx ports mapping.
SITE_HOST_DEFAULT="${SITE_HOST:-$(basename "$PROJECT_ROOT")}"
NEW_URL_DEFAULT="${NEW_URL:-https://${SITE_HOST_DEFAULT}}"
NGINX_PORT_DEFAULT="${NGINX_PORT:-$(awk '/^[[:space:]]*-[[:space:]]*"[0-9]+:80"/ {gsub(/[":-]/," ",$0); print $1; exit}' "$PROJECT_ROOT/docker-compose.yml" 2>/dev/null || echo 80)}"

# Workspace for extraction (under /tmp so it's wiped on reboot if interrupted)
EXTRACT_DIR="/tmp/dup-restore-$(basename "$PROJECT_ROOT")"

log() { printf '\n\033[1;36m[%(%H:%M:%S)T] %s\033[0m\n' -1 "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# -------- 1. preflight --------
log "Step 1/12: Preflight"

command -v docker >/dev/null || die "docker not in PATH"
docker compose version >/dev/null || die "docker compose plugin not available"

# Stack must be up so we can use the wpcli container for extraction + import
log "Checking stack health..."
SERVICES_UP=$(docker compose ps --status=running --services 2>/dev/null | sort -u)
for svc in db wordpress redis nginx; do
  if ! grep -qx "$svc" <<<"$SERVICES_UP"; then
    die "service '$svc' is not running. Run ./scripts/bootstrap-wordpress.sh first."
  fi
done

# Wait for db to be reachable from inside the network
log "Waiting for MySQL to accept connections..."
for i in {1..30}; do
  if docker compose exec -T db sh -c 'mysqladmin ping -h 127.0.0.1 -u root -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "MySQL not ready after 60s"
done

# Refuse to clobber an installed site unless user passes FORCE=1
if docker compose run --rm wpcli "wp core is-installed --skip-plugins --skip-themes" 2>/dev/null; then
  if [[ "${FORCE:-0}" != "1" ]]; then
    die "WordPress already installed in html/. Re-run with FORCE=1 to wipe and restore."
  fi
  warn "FORCE=1 set — existing site will be wiped."
fi

# -------- 2. extract --------
log "Step 2/12: Extracting DupArchive (this is NOT a zip — using PHP CLI)"

# Resume support: if a complete extraction already exists (dup-installer
# subfolder + at least one wp-content dir), reuse it. Set REEXTRACT=1 to force.
if [[ -d "$EXTRACT_DIR/dup-installer" && -d "$EXTRACT_DIR/wp-content" && "${REEXTRACT:-0}" != "1" ]]; then
  log "Found existing extraction at $EXTRACT_DIR — reusing (set REEXTRACT=1 to force re-extract)"
else
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"

# Run the extractor inside the wpcli container. /tmp is bind-mounted both ways
# (see docker-compose.yml). Project root is bind-mounted ad-hoc as /work.
ARCHIVE_REL=$(realpath --relative-to="$PROJECT_ROOT" "$ARCHIVE_ABS")
INSTALLER_REL=$(realpath --relative-to="$PROJECT_ROOT" "$INSTALLER_ABS")

# Run the extraction as root inside the container so it can freely write to
# /tmp/dup-restore-* (host root-owned). We chown back to 33:33 immediately after.
docker compose run --rm \
  --entrypoint "" \
  --user root \
  -v "$PROJECT_ROOT":/work \
  -v /tmp:/tmp \
  wpcli \
  php /work/scripts/extract-duparchive.php \
      "/work/$INSTALLER_REL" \
      "/work/$ARCHIVE_REL" \
      "$EXTRACT_DIR"

# Hand the extracted tree back to www-data so subsequent rsync/wp-cli ops work
chown -R 33:33 "$EXTRACT_DIR" 2>/dev/null || true
fi  # end resume guard

[[ -d "$EXTRACT_DIR/dup-installer" ]] || die "Extraction failed — no dup-installer/ in $EXTRACT_DIR"

# Locate the SQL dump. Duplicator Pro uses two layouts depending on build mode:
#   - Single-thread (older): dup-installer/dup-database__<HASH>.sql
#   - Multi-thread (4.5+):   dup-installer/dup_descriptors_<HASH>/db_dumps/<TIMESTAMP>-dump.sql
# Exclude any *.processed.sql we may have produced on a previous run.
SQL_FILE=$(find "$EXTRACT_DIR/dup-installer" \
    \( -name 'dup-database__*.sql' -o -name '*-dump.sql' \) \
    ! -name '*.processed.sql' 2>/dev/null | head -1)
[[ -f "$SQL_FILE" ]] || die "No SQL dump found under $EXTRACT_DIR/dup-installer (looked for dup-database__*.sql and *-dump.sql)"

log "Archive extracted to: $EXTRACT_DIR"
log "SQL dump: $SQL_FILE ($(du -h "$SQL_FILE" | cut -f1))"

# -------- 3. show source server version --------
log "Step 3/12: Detecting source DB engine / version"
SRV_LINES=$(grep -m 5 -E 'Server version|MySQL dump|MariaDB' "$SQL_FILE" || true)
echo "$SRV_LINES"

# -------- 4. confirm OLD_URL / NEW_URL --------
log "Step 4/12: Determining URL replacement"
OLD_URL=$(grep -oE "https?://[^']+" "$SQL_FILE" | grep -E "siteurl|home" -B0 -A0 | head -1 || true)
# The above heuristic is fragile; do a more robust scan
OLD_URL=$(awk -F"'" '/INSERT INTO `wp_options`/ && /siteurl/ {for(i=1;i<=NF;i++) if($i ~ /^https?:\/\//) {print $i; exit}}' "$SQL_FILE" || true)
if [[ -z "$OLD_URL" ]]; then
  # Fall back: try first http(s) URL in dump
  OLD_URL=$(grep -oE "https?://[a-zA-Z0-9.-]+" "$SQL_FILE" | head -1 || true)
fi

echo "Detected OLD_URL: ${OLD_URL:-<none>}"
# Allow non-interactive override via env vars: OLD_URL=... NEW_URL=... SKIP_CONFIRM=1
if [[ -n "${NEW_URL:-}" ]]; then
  echo "Using NEW_URL from env: $NEW_URL"
else
  read -r -p "Enter NEW_URL [default: $NEW_URL_DEFAULT]: " NEW_URL_INPUT
  NEW_URL="${NEW_URL_INPUT:-$NEW_URL_DEFAULT}"
fi
if [[ -z "$OLD_URL" ]]; then
  if [[ -n "${OLD_URL_OVERRIDE:-}" ]]; then
    OLD_URL="$OLD_URL_OVERRIDE"
    echo "Using OLD_URL from env: $OLD_URL"
  else
    read -r -p "Could not auto-detect OLD_URL. Enter it manually: " OLD_URL
    [[ -z "$OLD_URL" ]] && die "OLD_URL is required"
  fi
fi

log "Will replace: $OLD_URL  ->  $NEW_URL"
if [[ "${SKIP_CONFIRM:-0}" == "1" ]]; then
  log "SKIP_CONFIRM=1 — proceeding"
else
  read -r -p "Proceed? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user"
fi

# -------- 5. SQL pre-processing for MariaDB -> MySQL 8.0 --------
log "Step 5/12: Pre-processing SQL dump for MariaDB -> MySQL 8.0 compatibility"

# Operate on a copy so the original stays intact
SQL_PROC="${SQL_FILE%.sql}.processed.sql"
rm -f "$SQL_PROC"  # wipe any half-baked previous run
cp -f "$SQL_FILE" "$SQL_PROC"

# 5a. MariaDB 10.10+ uca1400 collations -> MySQL 8.0 0900 equivalents
sed -i \
  -e 's/utf8mb4_uca1400_ai_ci/utf8mb4_0900_ai_ci/g' \
  -e 's/utf8mb4_uca1400_as_cs/utf8mb4_0900_as_cs/g' \
  -e 's/utf8mb4_uca1400_as_ci/utf8mb4_0900_as_ci/g' \
  "$SQL_PROC"

# 5b. Old utf8 (3-byte, deprecated) -> utf8mb4
sed -i -E \
  -e 's/CHARSET=utf8([^m])/CHARSET=utf8mb4\1/g' \
  -e 's/CHARSET=utf8$/CHARSET=utf8mb4/g' \
  -e 's/COLLATE=utf8_/COLLATE=utf8mb4_/g' \
  -e 's/COLLATE utf8_/COLLATE utf8mb4_/g' \
  -e 's/DEFAULT CHARACTER SET utf8([^m])/DEFAULT CHARACTER SET utf8mb4\1/g' \
  "$SQL_PROC"

# 5c. Strip MariaDB JSON CHECK constraints (MySQL 8.0 has native JSON)
#     Pattern: ,? `?CONSTRAINT`? `name` CHECK (json_valid(`col`))
sed -i -E \
  -e 's/,[[:space:]]*CONSTRAINT[[:space:]]+`[^`]+`[[:space:]]+CHECK[[:space:]]*\(json_valid\(`[^`]+`\)\)//g' \
  -e '/^[[:space:]]*CONSTRAINT[[:space:]]+`[^`]+`[[:space:]]+CHECK[[:space:]]*\(json_valid\(`[^`]+`\)\)[[:space:]]*,?[[:space:]]*$/d' \
  "$SQL_PROC"

# 5d. Prepend a relaxed SQL_MODE so older dumps don't trip strict checks
TMP_HEAD=$(mktemp)
cat >"$TMP_HEAD" <<'EOSQL'
SET sql_mode='NO_ENGINE_SUBSTITUTION';
SET FOREIGN_KEY_CHECKS=0;
SET UNIQUE_CHECKS=0;
SET @OLD_TIME_ZONE=@@TIME_ZONE;
SET TIME_ZONE='+00:00';
EOSQL
cat "$TMP_HEAD" "$SQL_PROC" > "${SQL_PROC}.new" && mv "${SQL_PROC}.new" "$SQL_PROC"
rm -f "$TMP_HEAD"

# Quick sanity check: count INSERT statements (Duplicator uses INSERT IGNORE)
INSERT_COUNT=$(grep -cE '^INSERT (IGNORE )?INTO' "$SQL_PROC" || true)
TABLE_COUNT=$(grep -cE '^CREATE TABLE' "$SQL_PROC" || true)
log "Pre-processed SQL ready: $SQL_PROC ($TABLE_COUNT tables, $INSERT_COUNT INSERT statements)"

# -------- 6. clean Apache-era junk --------
log "Step 6/12: Cleaning Apache/host-specific junk from extracted wp-content"

WPCONTENT_SRC="$EXTRACT_DIR/wp-content"
[[ -d "$WPCONTENT_SRC" ]] || die "Expected $WPCONTENT_SRC after extraction"

JUNK=(
  "$WPCONTENT_SRC/advanced-cache.php"
  "$WPCONTENT_SRC/object-cache.php"
  "$WPCONTENT_SRC/db.php"
  "$WPCONTENT_SRC/wp-cache-config.php"
  "$WPCONTENT_SRC/cache"
  "$WPCONTENT_SRC/wflogs"
  "$WPCONTENT_SRC/w3tc-config"
  "$WPCONTENT_SRC/uploads/cache"
  "$WPCONTENT_SRC/mu-plugins/endurance-page-cache.php"
  "$WPCONTENT_SRC/mu-plugins/wp-stack-cache.php"
  "$WPCONTENT_SRC/mu-plugins/kinsta-mu-plugins.php"
  "$WPCONTENT_SRC/mu-plugins/kinsta-mu-plugins"
  "$WPCONTENT_SRC/mu-plugins/sg-cachepress.php"
  "$WPCONTENT_SRC/mu-plugins/wpe-wp-sign-on-plugin.php"
  "$EXTRACT_DIR/.htaccess"
  "$EXTRACT_DIR/.user.ini"
  "$EXTRACT_DIR/wp-config.php"            # Source wp-config — never reuse
  "$EXTRACT_DIR/wp-config-sample.php"
)
for p in "${JUNK[@]}"; do
  if [[ -e "$p" ]]; then
    rm -rf "$p" && echo "  removed $p"
  fi
done

# -------- 7. file landing --------
log "Step 7/12: Syncing wp-content into html/"

# We trust container's own wp-* files (index.php, wp-admin/, etc.). Only
# replace wp-content (themes, plugins, uploads) and tolerate extras the source
# might have at the document root.
# Note: do NOT --exclude '.htaccess' here -- some plugins legitimately ship one
# (e.g. akismet/.htaccess "Deny from all") and excluding it confuses rsync's
# --delete (it leaves the dir non-empty, which then fails to remove).
# We only filter the source's ROOT .htaccess in step 6 above.
mkdir -p html/wp-content
rsync -a --delete \
  --exclude 'wp-config.php' \
  "$WPCONTENT_SRC/" "html/wp-content/"

# Ensure permissions before touching the DB (so wp-cli inside container can read)
docker compose run --rm --entrypoint "" --user root wordpress \
  chown -R www-data:www-data /var/www/html

# -------- 8. import DB --------
log "Step 8/12: Resetting DB and importing dump"

# Stage the processed SQL inside html/ so wpcli can see it (html/ is the only
# bind mount available in wpcli besides /tmp). /tmp IS bind-mounted in our
# docker-compose, so just use that.
docker compose run --rm --entrypoint "" wpcli \
  bash -lc "wp db reset --yes && wp db import '$SQL_PROC'"

# -------- 9. URL search-replace --------
log "Step 9/12: wp search-replace (single clean pass)"

# Both protocol+host and bare host-only forms (some plugins store host-only)
OLD_HOST=$(echo "$OLD_URL" | sed -E 's|^https?://||; s|/.*$||')
NEW_HOST=$(echo "$NEW_URL" | sed -E 's|^https?://||; s|/.*$||')

docker compose run --rm --entrypoint "" wpcli bash -lc "
  set -e
  wp search-replace '$OLD_URL' '$NEW_URL' --all-tables --report-changed-only --skip-columns=guid
  if [ '$OLD_HOST' != '$NEW_HOST' ]; then
    wp search-replace '//$OLD_HOST' '//$NEW_HOST' --all-tables --report-changed-only --skip-columns=guid
    wp search-replace '$OLD_HOST' '$NEW_HOST' --all-tables --report-changed-only --skip-columns=guid
  fi
  # Force the canonical options just in case
  wp option update siteurl '$NEW_URL'
  wp option update home '$NEW_URL'
"

# -------- 10. WP finalisation --------
log "Step 10/12: WordPress finalisation (update-db, deactivate conflicting plugins, flush)"

docker compose run --rm --entrypoint "" wpcli bash -lc "
  set -e

  # 10a. Run pending DB migrations (WooCommerce / others) -- avoids 503 maintenance loop
  wp core update-db --network 2>/dev/null || wp core update-db

  # 10b. Deactivate plugins that misbehave in nginx + Cloudflare environment OR
  # carry host-bound state from the source server. wp-rocket is included here
  # because its advanced-cache.php drop-in points to the source host's paths;
  # we reactivate it cleanly in step 10d below so it regenerates fresh state.
  for plug in wp-rocket w3-total-cache wp-super-cache wp-fastest-cache litespeed-cache \
              wordfence wordfence-login-security simple-cloudflare-turnstile cloudflare \
              breeze hummingbird-performance autoptimize wp-optimize sg-cachepress \
              wp-stateless duplicator duplicator-pro social-auto-poster; do
    if wp plugin is-installed \$plug --skip-plugins --skip-themes 2>/dev/null; then
      wp plugin deactivate \$plug --skip-plugins --skip-themes 2>/dev/null || true
    fi
  done

  # 10c. UPGRADE A: auto-install + activate Redis Object Cache + drop-in
  # WordPress without an object-cache.php drop-in only uses Redis if a plugin
  # provides one; we wipe it in step 6 (because old drop-ins point to host paths)
  # and re-install the canonical one here. Idempotent.
  if ! wp plugin is-installed redis-cache --skip-plugins --skip-themes 2>/dev/null; then
    wp plugin install redis-cache --activate --skip-plugins --skip-themes 2>&1 || true
  else
    wp plugin activate redis-cache --skip-plugins --skip-themes 2>/dev/null || true
  fi
  wp redis enable 2>&1 || true   # registered by redis-cache plugin, can't --skip-plugins

  # 10d. UPGRADE B: re-activate WP Rocket cleanly if source had it. WP Rocket
  # 3.19+ supports nginx natively. Activating now creates a fresh
  # advanced-cache.php drop-in pointing to OUR cache dir (not the source host's).
  if wp plugin is-installed wp-rocket --skip-plugins --skip-themes 2>/dev/null; then
    wp plugin activate wp-rocket --skip-plugins --skip-themes 2>/dev/null || true
  fi

  wp cache flush --skip-plugins --skip-themes || true
  wp rewrite flush --hard --skip-plugins --skip-themes || true
"

# 10e. UPGRADE B continued: WP Rocket may write a stale .htaccess. nginx
# ignores it but it's noise + future-confusion. Always remove it post-activation.
rm -f html/.htaccess

# -------- 11. perms + cleanup --------
log "Step 11/12: Final perms + cleanup"

docker compose run --rm --entrypoint "" --user root wordpress \
  chown -R www-data:www-data /var/www/html

# Always remove the extraction workspace (5+ GB temp data, no longer needed)
log "Removing temp extraction dir $EXTRACT_DIR ..."
rm -rf "$EXTRACT_DIR"

# UPGRADE C: archive disposal -- decided AFTER the health check in step 12.
# We defer the move/delete until we know the site actually serves HTTP 200.

# -------- 12. health report --------
log "Step 12/12: Health check"
docker compose ps

SITE_URL_GET=$(docker compose run --rm --entrypoint "" wpcli wp option get siteurl --skip-plugins --skip-themes 2>/dev/null | tr -d '\r' || true)
HOME_GET=$(docker compose run --rm --entrypoint "" wpcli wp option get home --skip-plugins --skip-themes 2>/dev/null | tr -d '\r' || true)
TABLES=$(docker compose run --rm --entrypoint "" wpcli wp db query "SHOW TABLES" --skip-plugins --skip-themes 2>/dev/null | wc -l || echo 0)
ACTIVE_PLUGINS=$(docker compose run --rm --entrypoint "" wpcli wp plugin list --status=active --field=name --skip-plugins --skip-themes 2>/dev/null | tr '\n' ' ' || true)

NEW_HOST_PURE=$(echo "$NEW_URL" | sed -E 's|^https?://||; s|/.*$||')
NGINX_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -A "Mozilla/5.0" \
  -H "Host: $NEW_HOST_PURE" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: $NEW_HOST_PURE" \
  "http://127.0.0.1:${NGINX_PORT_DEFAULT}/" || echo "ERR")

# UPGRADE C: dispose of archive -- delete only on green health check.
ARCHIVE_DISPOSITION="kept in place"
if [[ "$NGINX_HTTP" == "200" || "$NGINX_HTTP" == "301" || "$NGINX_HTTP" == "302" ]]; then
  if [[ "${CLEANUP_ARCHIVE:-0}" == "1" ]]; then
    log "Health check passed (HTTP $NGINX_HTTP) and CLEANUP_ARCHIVE=1 -- deleting archive + installer"
    [[ -f "$ARCHIVE_ABS" && "$ARCHIVE_ABS" == "$PROJECT_ROOT"/* ]] && rm -f "$ARCHIVE_ABS" && ARCHIVE_DISPOSITION="DELETED ($(basename "$ARCHIVE_ABS"))"
    [[ -f "$INSTALLER_ABS" && "$INSTALLER_ABS" == "$PROJECT_ROOT"/* ]] && rm -f "$INSTALLER_ABS"
  else
    mkdir -p _backup
    [[ -f "$ARCHIVE_ABS" && "$ARCHIVE_ABS" == "$PROJECT_ROOT"/* ]] && mv -n "$ARCHIVE_ABS" _backup/ 2>/dev/null && ARCHIVE_DISPOSITION="moved to _backup/"
    [[ -f "$INSTALLER_ABS" && "$INSTALLER_ABS" == "$PROJECT_ROOT"/* ]] && mv -n "$INSTALLER_ABS" _backup/ 2>/dev/null || true
  fi
else
  warn "Health check FAILED (HTTP $NGINX_HTTP) -- archive + installer kept in place for re-run"
fi

cat <<EOF

==========================  RESTORE COMPLETE  ==========================
  siteurl       : $SITE_URL_GET
  home          : $HOME_GET
  DB tables     : $TABLES
  Active plugins: $ACTIVE_PLUGINS
  Local nginx   : http://127.0.0.1:${NGINX_PORT_DEFAULT}/  -> HTTP $NGINX_HTTP
  Archive       : $ARCHIVE_DISPOSITION

  Next step: in Cloudflare Zero Trust dashboard add Public Hostnames
    ${NEW_HOST_PURE}      -> http://localhost:${NGINX_PORT_DEFAULT}
    www.${NEW_HOST_PURE}  -> http://localhost:${NGINX_PORT_DEFAULT}
========================================================================
EOF
