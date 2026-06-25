#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Ensure expected bind-mount directories exist before Docker touches them.
# NOTE: no nginx_cache dir — /var/cache/nginx is intentionally NOT bind-mounted
# (mounting over it shadows nginx's pre-created temp dirs and breaks uploads).
mkdir -p html db_data

# Fix ownership so the wordpress container (www-data / UID 33) can write
# Using --entrypoint '' bypasses the default WordPress entrypoint script.
docker compose run --rm --entrypoint "" --user root wordpress \
  chown -R www-data:www-data /var/www/html

# Bring the stack up (feel free to remove services you don't need)
docker compose up -d

# Read the published port from .env so the hint matches this site.
PORT="$(grep -E '^NGINX_PORT=' .env 2>/dev/null | cut -d= -f2)"
echo "WordPress is booting. Visit http://localhost:${PORT:-<NGINX_PORT>} to finish installation."
echo "Reminder: install the external wp-cron entry -> see scripts/wp-cron.cron.example"
