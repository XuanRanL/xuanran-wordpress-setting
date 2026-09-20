#!/bin/sh
set -eu
. /usr/local/lib/mysql-client-policy.sh
case "${0##*/}" in
    mysql|mariadb) client=/usr/bin/mariadb ;;
    mysqldump|mariadb-dump) client=/usr/bin/mariadb-dump ;;
    mysqlcheck|mariadb-check) client=/usr/bin/mariadb-check ;;
    *) exit 64 ;;
esac
if local_mysql_tls_policy "$@"; then
    exec "$client" "$@" --ssl --skip-ssl-verify-server-cert
fi
exec "$client" "$@"
