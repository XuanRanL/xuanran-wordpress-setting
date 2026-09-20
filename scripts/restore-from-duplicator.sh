#!/usr/bin/env bash
# Trusted Duplicator restore. Pause external cron/queue writers before MAINTENANCE_CONFIRMED=1.
# NEW_URL/OLD_URL are explicit identities; FORCE=1 is required for a nonempty database.
# On failure web services remain stopped; snapshot, archive and extraction are retained.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT_ROOT"
source "$PROJECT_ROOT/scripts/lib/runtime.sh"
umask 077
acquire_project_lock
BACKUP_DIR=''; EXTRACT_DIR=''; WEB_STOPPED=0
finish() {
  local rc=$?
  if (( rc != 0 )); then
    printf 'RESTORE FAILED (exit %s). Snapshot: %s; extraction: %s\n' "$rc" "${BACKUP_DIR:-not started}" "${EXTRACT_DIR:-not started}" >&2
    if (( WEB_STOPPED != 0 )); then
      if docker compose stop nginx wordpress; then
        warn 'Web services stopped for recovery. External writers must stay paused.'
      else
        warn 'Could not confirm web services stopped. Block traffic and recover manually; external writers must stay paused.'
      fi
    fi
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for utility in docker python3 sha256sum realpath rsync tar curl; do
  command -v "$utility" >/dev/null || die "$utility is required"
done
[[ -f .env && ! -L .env ]] || die 'a regular .env is required; credentials are never regenerated'
NGINX_PORT_DEFAULT=$(resolve_compose_port)
CLI_IMAGE=$(docker compose config --format json | python3 "$PROJECT_ROOT/scripts/validate-compose.py" --wpcli-image)
docker image inspect "$CLI_IMAGE" >/dev/null || die 'wpcli image is missing; build it explicitly before restoring'
[[ "${CLEANUP_ARCHIVE:-0}" == 0 ]] || die 'automatic archive disposal is disabled; retain recovery files under your backup policy'
ARCHIVE=${1:-}; INSTALLER=${2:-}
shopt -s nullglob
if [[ -z "$ARCHIVE" ]]; then
  archives=(*_archive.daf)
  (( ${#archives[@]} == 1 )) || die 'pass one archive explicitly (automatic selection requires exactly one)'
  ARCHIVE=${archives[0]}
fi
if [[ -z "$INSTALLER" ]]; then
  installers=("$(dirname "$ARCHIVE")"/*_installer.php)
  (( ${#installers[@]} == 1 )) || die 'pass one installer explicitly (automatic selection requires exactly one)'
  INSTALLER=${installers[0]}
fi
[[ -s "$ARCHIVE" && -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || die 'archive must be a nonempty regular file'
[[ -s "$INSTALLER" && -f "$INSTALLER" && ! -L "$INSTALLER" ]] || die 'installer must be a nonempty regular file'
ARCHIVE_ABS=$(realpath -e -- "$ARCHIVE"); INSTALLER_ABS=$(realpath -e -- "$INSTALLER")
NEW_URL=${NEW_URL:-${SITE_HOST:+https://$SITE_HOST}}
[[ -n "$NEW_URL" ]] || die 'NEW_URL is required (or set SITE_HOST); a directory name is not a site identity'
NEW_URL=${NEW_URL%/}; validate_url "$NEW_URL"
OLD_URL=${OLD_URL:-${OLD_URL_OVERRIDE:-}}
[[ -n "$OLD_URL" ]] || die 'OLD_URL is required; inspect source siteurl/home instead of guessing a URL from the dump'
OLD_URL=${OLD_URL%/}; validate_url "$OLD_URL"
[[ "${MAINTENANCE_CONFIRMED:-0}" == 1 ]] || die 'pause external cron/queue writers and set MAINTENANCE_CONFIRMED=1'
[[ "${SKIP_CONFIRM:-0}" == 1 ]] || {
  read -r -p "Restore $NEW_URL after a complete snapshot? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die 'aborted'
}

# Validate the actual mount before any live-file operation. Old Compose/.env layouts remain supported.
WP_CONTAINER=$(docker compose ps -q wordpress)
[[ -n "$WP_CONTAINER" && "$WP_CONTAINER" != *$'\n'* ]] || die 'exactly one running wordpress container is required'
HTML_MOUNT=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/www/html"}}{{.Source}}{{end}}{{end}}' "$WP_CONTAINER")
[[ "$(realpath -e -- "$HTML_MOUNT")" == "$PROJECT_ROOT/html" ]] || die 'wordpress must mount this project html/; do not restore into a different bind mount'
require_child "$PROJECT_ROOT" "$PROJECT_ROOT/html"
WORK_ROOT="$PROJECT_ROOT/.restore-work"
require_child "$PROJECT_ROOT" "$WORK_ROOT"
mkdir -p -- "$WORK_ROOT"
[[ ! -L "$WORK_ROOT" ]] || die 'restore workspace cannot be a symlink'
wpcli() { docker compose run --rm --no-deps -T --entrypoint '' -v "$WORK_ROOT:/restore" wpcli "$@"; }
dbsql() { docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root -N --batch "$MYSQL_DATABASE"' <<<"$1"; }
[[ "$(dbsql 'SELECT 1;')" == 1 ]] || die 'database authentication/readiness failed'
# WP-CLI loads the actual wp-config.php; matching Compose env alone cannot detect hardcoded DB constants.
IDENTITY_SQL='SELECT @@server_uuid, DATABASE();'
BACKUP_DB_ID=$(dbsql "$IDENTITY_SQL")
CLI_DB_ID=$(wpcli wp db query "$IDENTITY_SQL" --skip-column-names --batch --skip-plugins --skip-themes)
[[ "$BACKUP_DB_ID" == *$'\t'* && "$BACKUP_DB_ID" != *$'\n'* && "$CLI_DB_ID" == "$BACKUP_DB_ID" ]] ||
  die 'WP-CLI database identity differs from the db service selected for backup; no restore performed'
EXISTING_TABLES=$(dbsql 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();')
[[ "$EXISTING_TABLES" =~ ^[0-9]+$ ]] || die 'could not determine existing database state'
if (( EXISTING_TABLES > 0 )) && [[ "${FORCE:-0}" != 1 ]]; then
  die 'database is nonempty; FORCE=1 is required after reviewing the restore plan'
fi

INPUT_HASH=$(sha256sum -- "$ARCHIVE_ABS" "$INSTALLER_ABS" "$PROJECT_ROOT/scripts/extract-duparchive.php" \
  "$PROJECT_ROOT/scripts/restore-content-cleanup.sh" "$PROJECT_ROOT/scripts/restore-sql-compat.sh" | sha256sum | cut -d' ' -f1)
EXTRACT_DIR="$WORK_ROOT/$INPUT_HASH"
require_child "$WORK_ROOT" "$EXTRACT_DIR"
if [[ "${REEXTRACT:-0}" == 0 ]] && extraction_complete "$EXTRACT_DIR" "$INPUT_HASH"; then
  log 'Reusing extraction with matching archive/installer/extractor hash and completion marker'
else
  # Preserve interrupted trees instead of deleting material needed to diagnose/recover a failed run.
  if [[ -e "$EXTRACT_DIR" ]]; then
    mv -- "$EXTRACT_DIR" "$(mktemp -d "$WORK_ROOT/incomplete.XXXXXXXX")/payload"
  fi
  mkdir -- "$EXTRACT_DIR"
  log 'Extracting trusted archive with isolated mounts'
  # Do not inherit Compose volumes or credentials while executing archive-supplied PHP classes.
  docker run --rm --network none --read-only --user root --workdir /output --entrypoint php \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    -v "$PROJECT_ROOT/scripts/extract-duparchive.php:/extract.php:ro" \
    -v "$INSTALLER_ABS:/installer.php:ro" -v "$ARCHIVE_ABS:/archive.daf:ro" \
    -v "$EXTRACT_DIR:/output" "$CLI_IMAGE" /extract.php /installer.php /archive.daf /output
  [[ -d "$EXTRACT_DIR/dup-installer" && -d "$EXTRACT_DIR/wp-content" ]] || die 'extraction did not produce the required tree'
  [[ -z "$(find "$EXTRACT_DIR" -type l -print -quit)" ]] || die 'archive contains symlinks; inspect manually'
  printf '%s\n' "$INPUT_HASH" > "$EXTRACT_DIR/.complete.tmp"
  mv -- "$EXTRACT_DIR/.complete.tmp" "$EXTRACT_DIR/.complete"
fi
[[ -z "$(find "$EXTRACT_DIR" -type l -print -quit)" ]] || die 'extraction contains symlinks'
mapfile -d '' sql_files < <(find "$EXTRACT_DIR/dup-installer" -type f \
  \( -name 'dup-database__*.sql' -o -name '*-dump.sql' \) ! -name '*.processed.sql' -print0)
(( ${#sql_files[@]} == 1 )) || die 'expected exactly one SQL dump; inspect multi-file/ambiguous archives manually'
SQL_FILE=${sql_files[0]}; require_child "$EXTRACT_DIR" "$SQL_FILE"
[[ -s "$SQL_FILE" ]] || die 'SQL dump is empty'
TABLE_PREFIX=$(wpcli wp config get table_prefix --type=variable)
[[ "$TABLE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die 'invalid destination table prefix'
grep -qE "CREATE TABLE( IF NOT EXISTS)? .?${TABLE_PREFIX}options" "$SQL_FILE" || die 'archive prefix differs from destination; configure the intended prefix before restoring'
source "$PROJECT_ROOT/scripts/restore-sql-compat.sh"
(( TABLE_COUNT > 0 && INSERT_COUNT > 0 )) || die 'SQL dump has no recognized tables or data'
source "$PROJECT_ROOT/scripts/restore-content-cleanup.sh"

# Snapshot before the first live-file/database mutation, with web requests and external writers quiesced.
BACKUP_ROOT="$PROJECT_ROOT/.restore-backups"
require_child "$PROJECT_ROOT" "$BACKUP_ROOT"
mkdir -p -- "$BACKUP_ROOT"
[[ ! -L "$BACKUP_ROOT" ]] || die 'backup directory cannot be a symlink'
BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/restore-$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
HTML_KB=$(du -sk -- html | cut -f1)
DB_KB=$(dbsql 'SELECT CEIL(COALESCE(SUM(data_length+index_length),0)/1024) FROM information_schema.tables WHERE table_schema=DATABASE();')
FREE_KB=$(df -Pk -- "$BACKUP_DIR" | awk 'END {print $4}')
[[ "$HTML_KB" =~ ^[0-9]+$ && "$DB_KB" =~ ^[0-9]+$ && "$FREE_KB" =~ ^[0-9]+$ ]] || die 'cannot determine backup space'
(( FREE_KB > HTML_KB + DB_KB * 2 + 1048576 )) || die 'insufficient space for recovery snapshot plus safety margin'
log "Stopping web services; snapshot: $BACKUP_DIR"
WEB_STOPPED=1
docker compose stop nginx wordpress
tar -cf "$BACKUP_DIR/site.tar" -- html .env docker-compose.yml nginx php scripts
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --single-transaction --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF "$MYSQL_DATABASE"' > "$BACKUP_DIR/database.sql"
[[ -s "$BACKUP_DIR/database.sql" ]] || die 'database backup is empty'
tar -tf "$BACKUP_DIR/site.tar" >/dev/null
sha256sum -- "$BACKUP_DIR/site.tar" "$BACKUP_DIR/database.sql" > "$BACKUP_DIR/SHA256SUMS"
printf 'archive=%s\ninstaller=%s\ninput_hash=%s\nnew_url=%s\nold_url=%s\n' "$ARCHIVE_ABS" "$INSTALLER_ABS" "$INPUT_HASH" "$NEW_URL" "$OLD_URL" > "$BACKUP_DIR/manifest.txt"
touch "$BACKUP_DIR/.snapshot-complete"

log 'Replacing wp-content and importing database'
require_child "$PROJECT_ROOT" "$PROJECT_ROOT/html/wp-content"
mkdir -p html/wp-content
rsync -a --delete -- "$EXTRACT_DIR/wp-content/" html/wp-content/
docker compose run --rm --no-deps -T --entrypoint '' --user root wordpress chown -R www-data:www-data /var/www/html
chown -R 33:33 -- "$WORK_ROOT"
chmod 755 "$WORK_ROOT" "$EXTRACT_DIR"
SQL_CONTAINER="/restore/$INPUT_HASH/${SQL_PROC#"$EXTRACT_DIR/"}"
wpcli wp db reset --yes
wpcli wp db import "$SQL_CONTAINER"
wpcli wp search-replace "$OLD_URL" "$NEW_URL" --all-tables --report-changed-only --skip-columns=guid
OLD_HOST=${OLD_URL#*://}; OLD_HOST=${OLD_HOST%%/*}
NEW_HOST=${NEW_URL#*://}; NEW_HOST=${NEW_HOST%%/*}
if [[ "$OLD_HOST" != "$NEW_HOST" ]]; then
  wpcli wp search-replace "//$OLD_HOST" "//$NEW_HOST" --all-tables --report-changed-only --skip-columns=guid
  wpcli wp search-replace "$OLD_HOST" "$NEW_HOST" --all-tables --report-changed-only --skip-columns=guid
fi
wpcli wp option update siteurl "$NEW_URL"
wpcli wp option update home "$NEW_URL"
source "$PROJECT_ROOT/scripts/restore-finalize.sh"
rm -f -- html/.htaccess
wpcli wp core is-installed --skip-plugins --skip-themes
[[ "$(wpcli wp option get siteurl --skip-plugins --skip-themes)" == "$NEW_URL" ]] || die 'siteurl mismatch after import'
[[ "$(wpcli wp option get home --skip-plugins --skip-themes)" == "$NEW_URL" ]] || die 'home mismatch after import'
wpcli wp db check --skip-plugins --skip-themes
docker compose up -d --no-deps --wait --wait-timeout 180 wordpress nginx
if ! verify_origin "$NGINX_PORT_DEFAULT" "$NEW_URL"; then
  docker compose stop nginx wordpress
  die 'origin verification failed; web services stopped for recovery'
fi
WEB_STOPPED=0
printf '%s\n' "$INPUT_HASH" > "$BACKUP_DIR/.restore-complete"
log "RESTORE COMPLETE: $NEW_URL; origin port $NGINX_PORT_DEFAULT"
printf 'Snapshot: %s\nExtraction: %s\nArchive and installer retained in place.\n' "$BACKUP_DIR" "$EXTRACT_DIR"
printf 'Validate business flows, then resume external cron/queue writers. Recovery files are never automatically deleted.\n'
