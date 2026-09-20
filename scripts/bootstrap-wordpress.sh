#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
source "$PROJECT_ROOT/scripts/lib/runtime.sh"
umask 077
acquire_project_lock

# Existing credentials are never generated or rotated by a bootstrap rerun.
[[ -f .env && ! -L .env ]] || die 'create .env from .env.example with unique credentials before bootstrapping'
PORT=$(resolve_compose_port)

# Ensure expected bind-mount directories exist before Docker touches them.
# NOTE: no nginx_cache dir — /var/cache/nginx is intentionally NOT bind-mounted
# (mounting over it shadows nginx's pre-created temp dirs and breaks uploads).
# nginx and FPM use different UIDs; the document-root directory must remain traversable.
# mkdir -m only applies to new directories, preserving deliberate existing permissions.
mkdir -p -m 755 html
mkdir -p -m 700 db_data
require_child "$PROJECT_ROOT" "$PROJECT_ROOT/html"
require_child "$PROJECT_ROOT" "$PROJECT_ROOT/db_data"

# Fix ownership so the wordpress container (www-data / UID 33) can write
# Using --entrypoint '' bypasses the default WordPress entrypoint script.
docker compose run --rm --no-deps --entrypoint "" --user root wordpress \
  chown -R www-data:www-data /var/www/html

# Wait for the configured services to become ready.
docker compose up -d --wait --wait-timeout 180 db redis wordpress nginx

# Use the validated effective Compose port so the hint also matches fixed ports.
echo "WordPress stack is healthy. Visit http://localhost:${PORT} to finish installation."
echo "Reminder: install the external wp-cron entry -> see scripts/wp-cron.cron.example"
