#!/usr/bin/env bash
# Shared safety primitives. Callers use set -euo pipefail.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%(%H:%M:%S)T] %s\n' -1 "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

require_child() {
  local root target
  root=$(realpath -e -- "$1") || return 1
  target=$(realpath -m -- "$2") || return 1
  [[ "$root" != / && "$target" == "$root/"* && "$target" != "$root" ]] || {
    printf 'ERROR: path escapes the permitted directory: %s\n' "$2" >&2; return 1;
  }
}

validate_url() {
  # Root or subdirectory URLs only; reject credentials, query/fragment and shell/SQL metacharacters.
  [[ "$1" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$ ]] || {
    printf 'ERROR: URL must be a plain HTTP(S) site URL\n' >&2; return 1;
  }
}

resolve_compose_port() {
  command -v python3 >/dev/null || die 'python3 is required for resolved Compose validation'
  docker compose config --format json | python3 "$PROJECT_ROOT/scripts/validate-compose.py"
}

acquire_project_lock() {
  command -v flock >/dev/null || die 'flock (util-linux) is required'
  [[ ! -L "$PROJECT_ROOT/.stack-operation.lock" ]] || die 'lock must not be a symlink'
  exec 9>"$PROJECT_ROOT/.stack-operation.lock"
  flock -n 9 || die 'another bootstrap/restore operation holds this project lock'
}

extraction_complete() {
  [[ -f "$1/.complete" && -d "$1/wp-content" && -d "$1/dup-installer" ]] &&
    [[ "$(cat -- "$1/.complete")" == "$2" ]]
}

verify_origin() {
  local status host site_path
  validate_url "$2" || return 1
  host=${2#*://}; host=${host%%/*}
  site_path=${2#*://}; site_path=${site_path#"$host"}; site_path=${site_path:-/}
  status=$(curl --silent --show-error --max-time 30 --output /dev/null --write-out '%{http_code}' \
    -H "Host: $host" -H "X-Forwarded-Proto: ${2%%:*}" -H "X-Forwarded-Host: $host" \
    "http://127.0.0.1:$1$site_path") || return 1
  [[ "$status" == 200 ]] || {
    printf 'ERROR: origin returned HTTP %s (expected 200, redirects do not pass)\n' "$status" >&2; return 1;
  }
}
