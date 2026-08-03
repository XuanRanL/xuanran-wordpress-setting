# WordPress + Cloudflare Tunnel Stack (xuanran base template)

Opinionated, production-tuned WordPress stack used as the **base template for new
sites**. Each site is one `docker compose` project (WordPress PHP-FPM, nginx,
MySQL, Redis, WP-CLI) sitting behind a Cloudflare Zero Trust tunnel.

Caching/perf plugins assumed per site: **FlyingPress** (full-page cache),
**Redis Object Cache**, **Imagify** (AVIF/WebP).

## What this template bakes in

| Layer | Choice | Why |
|------|--------|-----|
| MySQL | 8.4.8, `--skip-log-bin`, redo-log 512M | current LTS; no binlog (no replication/PITR) saves IO |
| PHP OPcache | JIT **off**, `validate_timestamps=1` (60s) | stable with Wordfence/heavy plugins; updates auto-apply |
| Redis | `maxmemory 256mb`, `allkeys-lru`, no persistence | pure object cache, bounded RAM |
| nginx | AVIF/WebP sidecars, admin-ajax/wp-cron 2h timeouts, big fastcgi buffers, real-IP incl. docker bridge | image perf + long admin jobs + correct visitor IPs |
| Page cache | **FlyingPress only** (no nginx fastcgi_cache) | one smart, self-purging layer — no stale duplicates |
| WP-Cron | `DISABLE_WP_CRON=true` + external system cron | reliable on low traffic, no TTFB hit |
| Logging | `json-file`, `max-size 20m` × `max-file 3` per service | Docker's default is **unbounded** (see below) |
| php-fpm access log | `/dev/null` | nginx already logs the same requests, auth user included |
| Ports | `NGINX_PORT` from `.env` | drop-in per-site, no editing compose |

### Two logging gotchas this template fixes (added 2026-07-29)

**1. Docker json-file logs never rotate by default.** A container log only resets when
the container is *recreated*, so a long-lived site grows without limit. The 12-site fleet
this template runs had accumulated **751MB** of container logs, with individual containers
at 78–134MB. Every service now carries an explicit `logging:` block. Note the cap applies
at container-creation time — an existing container must be recreated (`docker compose up -d`)
to pick it up; changing the daemon default alone does nothing to running containers.

**2. Never set `DISABLE_WP_CRON` with `wp config set`.** The `wordpress` service already
defines it through `WORDPRESS_CONFIG_EXTRA`, which wp-config.php applies via `eval()`.
`wp config set` appends a *second*, bare `define()` **after** that eval, so PHP logs

```
PHP Warning:  Constant DISABLE_WP_CRON already defined in /var/www/html/wp-config.php on line 133
```

on **every single request** — it was 32–47% of every container log on the fleet
(618k lines) before this was found. It is not a functional bug (`display_errors=Off`, so
nothing leaks into responses), but it buries real errors and inflates the log.
The `wpcli` service now defines the constant in its own env instead, because WP-CLI
otherwise runs `wp_cron()` on init and spawns a wp-cron.php loopback on every command.

Verify both contexts after a build:

```bash
docker compose exec -T wordpress php -r 'eval(getenv("WORDPRESS_CONFIG_EXTRA")); var_dump(DISABLE_WP_CRON);'  # bool(true)
docker compose run --rm wpcli "wp eval 'var_dump(DISABLE_WP_CRON);'"                                          # bool(true)
docker compose logs wordpress --since 5m | grep -c "already defined"                                          # 0
```

## Prerequisites

- Docker Compose v2
- A `.env` (copy from `.env.example`) with DB creds + a unique `NGINX_PORT`
- A Cloudflare Tunnel forwarding HTTPS to `http://localhost:<NGINX_PORT>`

## New-site setup

```bash
cp .env.example .env        # set DB creds + a UNIQUE NGINX_PORT + SITE_DOMAIN
./scripts/bootstrap-wordpress.sh
```

The script creates the `html`/`db_data` bind mounts, fixes
ownership to `www-data` (UID/GID 33), and starts the stack. Finish the installer
at `http://localhost:<NGINX_PORT>/wp-admin/install.php` (or your tunnel hostname).

### Install the external WP-Cron (required)

Because WP-Cron is disabled in WordPress, add a system cron per site:

```bash
# IMPORTANT: the filename must NOT contain a dot — cron/run-parts silently
# ignores files with dots. Use the domain with dots replaced by hyphens,
# e.g. pawkeepsake.com -> pawkeepsake-com-wp-cron
sudo cp scripts/wp-cron.cron.example /etc/cron.d/<domain-with-hyphens>-wp-cron
sudo sed -i 's/__DOMAIN__/<domain>/; s/__PORT__/<NGINX_PORT>/' /etc/cron.d/<domain-with-hyphens>-wp-cron
sudo systemctl restart cron
```

One file per site under `/etc/cron.d/`; stagger the minute field so sites don't all fire at once.

## Cloudflare Zero Trust / arbitrary hostnames

- `nginx/conf.d/wordpress.conf` uses `server_name _`, so nginx accepts whatever
  `Host` Cloudflare injects. Point the tunnel at `http://localhost:<NGINX_PORT>`
  and do **not** enable HTTP host rewrites.
- `nginx/conf.d/cloudflare-realip.conf` trusts Cloudflare ranges **and** the
  docker bridge (`172.16.0.0/12`) so `$remote_addr` reflects the real visitor.
- Lock down later by replacing `_` with your explicit domains.

## Optional: serve FlyingPress cache from nginx (max speed)

`wordpress.conf` ships a commented block that serves FlyingPress static HTML
directly from nginx (bypassing PHP for logged-out GETs). Enable it **only after**
confirming `wp-content/cache/flying-press/<host>/` is generating, then reload
nginx. Do **not** add nginx `fastcgi_cache` — it would duplicate FlyingPress and
serve stale pages it can't purge.

## Re-applying permissions later

If you wipe `html/`, re-run `./scripts/bootstrap-wordpress.sh` (or just
`docker compose run --rm --entrypoint "" --user root wordpress chown -R www-data:www-data /var/www/html`)
before starting. WordPress needs write access to `/var/www/html` for upgrades/plugins.

## Migrating an existing site in (Duplicator)

`scripts/restore-from-duplicator.sh` + `scripts/extract-duparchive.php` restore a
Duplicator `.daparchive` into this stack. See comments at the top of each script.

## Troubleshooting

- **nginx health check stuck `starting`** — probe uses `127.0.0.1` to avoid IPv6
  mismatch; check `docker compose logs nginx` and that `wordpress` is healthy.
- **Permission denied writing `html/`** — `sudo chown -R 33:33 html`.
- **Cloudflare 403** — check your Access policy and that the tunnel routes to `NGINX_PORT`.
- **Code/plugin update didn't take effect** — OPcache revalidates every 60s; wait
  or `docker compose restart wordpress`.
- **Edited an nginx/php conf but nothing changed** — the confs are single-file bind
  mounts. Editing them changes the file's inode, but the running container keeps the
  old one, so `nginx -s reload` does nothing. Apply config changes with
  `docker compose up -d --force-recreate nginx wordpress`.

## Security

- `.env` is gitignored — never commit real secrets. If one leaks, **rotate it**
  (DB passwords, tunnel token); scrubbing git history alone does not un-leak it.
