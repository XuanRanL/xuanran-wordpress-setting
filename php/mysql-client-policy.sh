#!/bin/sh
# A deliberately narrow compatibility default for the local Compose database.
# Return success only when no caller TLS/defaults/socket choice is overridden.
local_mysql_tls_policy() {
    # WP-CLI uses this first argument. Otherwise implicit client config may
    # contain a CA/verification/connection choice that must not be overridden.
    [ "${1:-}" = --no-defaults ] || return 1
    local_host= local_port=3306 host_count=0 port_count=0
    [ "${MYSQL_TCP_PORT:-3306}" = 3306 ] || return 1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ssl*|--skip[-_]ssl*|--disable[-_]ssl*|--enable[-_]ssl*|--tls*|--defaults*|--login[-_]path*|--socket*|-S*) return 1 ;;
            --host|-h)
                [ "$#" -ge 2 ] || return 1
                shift; local_host=$1; host_count=$((host_count + 1)) ;;
            --host=*) local_host=${1#*=}; host_count=$((host_count + 1)) ;;
            -h*) local_host=${1#-h}; host_count=$((host_count + 1)) ;;
            --port|-P)
                [ "$#" -ge 2 ] || return 1
                shift; local_port=$1; port_count=$((port_count + 1)) ;;
            --port=*) local_port=${1#*=}; port_count=$((port_count + 1)) ;;
            -P*) local_port=${1#-P}; port_count=$((port_count + 1)) ;;
            --protocol)
                [ "$#" -ge 2 ] || return 1
                shift; [ "$1" = tcp ] || return 1 ;;
            --protocol=*) [ "$1" = --protocol=tcp ] || return 1 ;;
            # Only exact options emitted by the supported WP-CLI operations.
            # Value-bearing options must consume their argument even if it looks
            # like a connection option. Unknown/abbreviated/loose options pass
            # through without any TLS default; do not replicate MariaDB getopt.
            --user|--database|--execute|--default-character-set|--init-command|--result-file|-u|-D|-e)
                [ "$#" -ge 2 ] || return 1
                shift ;;
            --user=*|--database=*|--execute=*|--default-character-set=*|--init-command=*|--result-file=*) ;;
            --no-defaults|--batch|--skip-column-names|--quick|--single-transaction|--skip-lock-tables|--add-drop-table|--hex-blob|--no-tablespaces|--routines|--triggers|--events|--add-drop-database|--databases|--tables|--no-create-info|--no-data|--skip-add-locks|--skip-comments|--skip-extended-insert|--compact|--complete-insert|--disable-keys|--extended-insert|--set-charset|--quote-names|--opt|--skip-opt|--force|--verbose) ;;
            --check|--check-only-changed|--auto-repair|--repair|--optimize|--analyze|--all-in-1) ;;
            --no-auto-rehash) ;; # WP-CLI's initial SQL-mode query.
            -*) return 1 ;;
            *) ;; # Database/table positional arguments cannot alter connection.
        esac
        shift
    done
    [ "$host_count" -eq 1 ] && [ "$port_count" -le 1 ] &&
        [ "$local_host" = db ] && [ "$local_port" = 3306 ]
}
