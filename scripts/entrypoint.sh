#!/bin/sh
set -eu

case "${1:-schedule}" in
    run) shift; exec /app/backup.sh "$@" ;;
    validate) shift; exec /app/backup.sh --validate "$@" ;;
    schedule) [ "$#" -eq 0 ] || shift ;;
    *) echo "Usage: schedule | run [--dry-run] | validate" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "Unexpected arguments" >&2; exit 2; }

/app/backup.sh --validate
: "${BACKUP_CRON:=0 2 * * 4}"
: "${TZ:=Etc/UTC}"
export TZ
printf '%s\n' "$BACKUP_CRON" | awk 'END { exit !(NR == 1 && NF == 5) }' \
    || { echo "BACKUP_CRON must have exactly five fields on one line" >&2; exit 2; }
printf '%s\n' "$BACKUP_CRON" | grep -Eq '^([0-9A-Za-z*/,-]+[[:blank:]]+){4}[0-9A-Za-z*/,-]+$' \
    || { echo "Invalid characters in BACKUP_CRON" >&2; exit 2; }
case "$TZ" in
    /*|*..*) echo "Invalid TZ" >&2; exit 2 ;;
esac
[ -f "/usr/share/zoneinfo/$TZ" ] || { echo "Unknown TZ" >&2; exit 2; }
printf '%s /app/backup.sh\n' "$BACKUP_CRON" > /tmp/edi-r2backup.crontab
supercronic -test /tmp/edi-r2backup.crontab
echo "Edi.R2Backup: schedule=$BACKUP_CRON timezone=$TZ"
exec supercronic /tmp/edi-r2backup.crontab
