#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Ensure expected bind-mount directories exist before Docker touches them
mkdir -p html db_data nginx_cache

# Fix ownership so the wordpress container (www-data / UID 33) can write
# Using --entrypoint '' bypasses the default WordPress entrypoint script.
docker compose run --rm --entrypoint "" --user root wordpress \
  chown -R www-data:www-data /var/www/html

# Bring the stack up (feel free to remove services you don't need)
docker compose up -d

echo "WordPress is booting. Visit http://localhost:9797 to finish installation."
