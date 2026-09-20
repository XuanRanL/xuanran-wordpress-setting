# Build and restore contract

## Bootstrap

Create `.env` from `.env.example` with unique passwords before running
`bash scripts/bootstrap-wordpress.sh`. The script does not generate or rotate
existing credentials. Resolved Compose configuration is validated before any
container or directory mutation; empty/placeholder credentials, mismatched DB
settings and a non-loopback/invalid published port fail closed. It waits for
database, Redis, PHP-FPM and nginx health before reporting success.

The new Compose PHP healthcheck uses `cgi-fcgi` from the new FPM Dockerfile.
Do not copy that healthcheck into an old image without this binary. Deploy the
Compose/image pair together only after reviewing site-specific configuration.
Resource limits, cache policy and background-job concurrency are unchanged.

## Existing-site restore compatibility

Synchronize `scripts/restore-from-duplicator.sh`, `scripts/validate-compose.py`,
`scripts/lib/runtime.sh`, `scripts/restore-sql-compat.sh`,
`scripts/restore-content-cleanup.sh`, `scripts/restore-finalize.sh`, and the
existing `scripts/extract-duparchive.php` together. Supporting scripts are sourced
by the main script and are not separate operator entrypoints.

Host prerequisites: Bash, Python 3, GNU coreutils, `flock` (util-linux), rsync,
tar, curl and Compose v2 with JSON configuration and `up --wait` support. The
standard services `wordpress`, `nginx`, `db`, `redis`, `wpcli` must be available;
the CLI image must already be built. Old fixed-port Compose files, `.env` without
`SITE_DOMAIN`, and MySQL 8.0 are supported. The actual WordPress document root
must bind this project’s `html/` directory in wordpress, wpcli and nginx, with
no additional mounts beneath `/var/www/html/`. The two PHP services must use
the db service on a shared network and matching database credentials. Before
any backup or reset, an actual WP-CLI connection (including existing wp-config
overrides) must return the same MySQL server UUID and database name as the
database service. Credentials are checked with authenticated queries.

This workflow does not require the new Compose healthcheck or rebuild an
existing image. The final HTTP check additionally requires status 200 and
checks WordPress `siteurl`, `home`, installed state and database integrity;
a 301/302 alone cannot pass. Existing configurations with unusual redirects or
nonstandard table-prefix/mount layouts require explicit review.

1. Obtain a trusted matching `.daf` and installer. Installer PHP supplies archive
   classes and must be trusted code. Extraction uses a separate `docker run`
   with network disabled, read-only root, read-only inputs, an isolated output
   mount and temporary memory-backed `/tmp`; it inherits no production mounts
   or Compose credentials.
2. Pause external cron and queue writers. The script stops web services itself,
   but cannot safely discover every external database writer.
3. Confirm source `siteurl`/`home` and destination URL. Use explicit values:

   ```bash
   NEW_URL=https://site.example OLD_URL=https://old.example \
   MAINTENANCE_CONFIRMED=1 FORCE=1 \
     bash scripts/restore-from-duplicator.sh archive.daf installer.php
   ```

   `FORCE=1` is required for a nonempty database, including a broken installation.
   `SKIP_CONFIRM=1` can suppress the final console confirmation in an already
   authorized workflow. The archive must contain exactly one recognized SQL
   dump and its prefix must match the destination’s WordPress configuration.
   Unsupported multi-part dumps fail before any live-file replacement.
4. A project lock prevents simultaneous bootstrap/restore. Extraction cache is
   bound to archive, installer, extractor and preprocessing hashes, plus a
   completion marker. Interrupted trees are preserved. Symlinks are rejected.
5. Before live replacement, web services stop; `html/` and configuration are
   archived and the database is dumped with routines/triggers/events. Free-space
   checks, archive listing and SHA-256 checksums precede `.snapshot-complete`.
   The estimate is a guard, not a guarantee for every compression/data workload;
   a write failure still stops the workflow.
6. On any failure after quiescing, the exit handler attempts to stop web services
   again (including partial startup) and explicitly reports if stopping cannot
   be confirmed. It does not automatically revert the database or discard
   evidence. On success, validate business flows before resuming writers.

Recovery files stay in `.restore-backups/` and `.restore-work/`; source archive
and installer remain in place. `CLEANUP_ARCHIVE=1` is rejected. Apply the normal
backup retention policy after independent recovery verification. An operator
can verify `SHA256SUMS`, inspect `site.tar` and `database.sql`, restore the full
file/configuration snapshot and import the matching database while all writers
remain stopped. Do not replace a live order database with a stale snapshot.

The inherited SQL collation preprocessing and plugin migration behavior still
require a representative restore rehearsal; these tests do not certify every
third-party Duplicator/WordPress/plugin version.

## Image provenance and verification

Registry manifests were checked on 2026-09-20 against
`registry-1.docker.io/v2/library/wordpress/manifests/<tag>` (HTTP 200 plus
Docker-Content-Digest), and Redis against the official PECL stable release:

- `wordpress:7.1.1-php8.3-fpm` — `sha256:f62a39d3e301cc081fd13a470fc8614c0a11e67722a54f1151f7fa075b6b6263`
- `wordpress:cli-2.12.0-php8.3` — `sha256:46b3add1dbd834018a9c22bb05a2fa9303f6139d8ac7337dc97cf9424072cd77`
- PECL Redis `6.3.0` in both images.

Compose runtime images are also pinned, without changing their selected versions:

- `nginx:1.27-alpine` — `sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10`
- `mysql:8.4.8` — `sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf`
- `redis:7-alpine` (Redis 7.4.11) — `sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf`

These manifests were verified directly from the official registry on 2026-09-20
and match the images used by the real bootstrap acceptance test. The current
Redis floating tag resolves to a newer OS rebuild of the same Redis 7.4.11;
the pin deliberately retains the tested manifest above. Digest updates remain
an explicit reviewed change. nginx's healthcheck timeout is 12 seconds to cover
both sequential five-second probes with startup/pipe margin.

Both bases use PHP 8.3. These pins govern new builds; they do not authorize an
existing site's WordPress core upgrade. Review and advance pinned digests with
security releases instead of freezing indefinitely. OS package repositories
are still time-varying, so this is dependency pinning, not bit-for-bit hermetic
reproducibility. Build once, record the resulting image digest and promote it.
Compiler packages and build caches are removed and Redis loading is checked
during build. `.dockerignore` excludes runtime data, secrets and restore files.

The CLI explicitly installs Alpine `mariadb-connector-c` for MySQL 8 caching_sha2_password authentication. The pinned CLI contains a MariaDB client that verifies TLS certificates by
default, while a fresh MySQL container creates a self-signed certificate. Its
mysql/mysqldump/mysqlcheck wrappers add `--ssl --skip-ssl-verify-server-cert` only for an
explicit `db` host on port 3306 and a leading `--no-defaults` argument (the
standard WP-CLI invocation on the isolated Compose network).
Encryption remains enabled, but this narrow default does not authenticate the
server certificate; the network and restore identity check remain necessary.
External hosts, nonstandard ports, sockets, defaults files, and any explicit
SSL/TLS options, unknown/abbreviated options, or implicit client configuration
pass through unchanged. For verified TLS, provide the CA and
verification options explicitly; the wrapper never overrides them. Existing
images are unchanged, and custom aliases require their own TLS configuration.

Offline regression command: `python3 -m unittest discover -s tests -v`.
Linux additionally runs full restore-flow tests with a fake Docker boundary and
real temporary filesystem/tar/checksum operations. Integration acceptance also
requires isolated nginx format/MIME tests, a real FPM FastCGI ping, and fresh
bootstrap/re-bootstrap with unchanged credentials, matching DB identities,
an encrypted CLI connection, and working SQL query/export operations.
