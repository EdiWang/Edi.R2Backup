#!/bin/sh
set -eu
umask 022

fail() { echo "Edi.R2Backup: $*" >&2; exit 2; }
mode=${1:-run}
case "$mode" in
    run|--dry-run|--validate) ;;
    *) fail "Usage: backup.sh [--dry-run | --validate]" ;;
esac
[ "$#" -le 1 ] || fail "Unexpected arguments"
: "${RCLONE_CONFIG:=/run/secrets/rclone.conf}"
: "${R2_REMOTE:=r2}"
export RCLONE_CONFIG
[ -f "$RCLONE_CONFIG" ] && [ -r "$RCLONE_CONFIG" ] || fail "Credentials file is missing or unreadable"
[ -n "${R2_BUCKETS:-}" ] || fail "R2_BUCKETS is required"
case "$R2_REMOTE" in
    ''|*[!A-Za-z0-9_-]*) fail "Invalid remote name" ;;
esac
rclone listremotes | grep -Fxq "$R2_REMOTE:" || fail "Configured remote does not exist"

set -f
seen=' '
for bucket in $R2_BUCKETS; do
    printf '%s\n' "$bucket" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' || fail "Invalid bucket name"
    case "$bucket" in *..*) fail "Invalid bucket name" ;; esac
    case "$seen" in *" $bucket "*) fail "Duplicate bucket name" ;; esac
    seen="$seen$bucket "
    [ ! -L "/backup/$bucket" ] || fail "Bucket destination must not be a symbolic link"
    [ ! -e "/backup/$bucket" ] || [ -d "/backup/$bucket" ] || fail "Bucket destination must be a directory"
done
[ "$seen" != ' ' ] || fail "At least one bucket is required"
[ -d /backup ] && [ -w /backup ] || fail "Backup directory is missing or not writable"
[ "$mode" != --validate ] || { echo "Edi.R2Backup: configuration valid"; exit 0; }

[ ! -L /backup/.edi-r2backup.lock ] || fail "Lock file must not be a symbolic link"
exec 9>/backup/.edi-r2backup.lock
flock -n 9 || { echo "Edi.R2Backup: another backup is running" >&2; exit 1; }
listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
status=0

for bucket in $R2_BUCKETS; do
    destination="/backup/$bucket"
    if [ -d "$destination" ] && [ -n "$(find "$destination" -type l -print -quit)" ]; then
        echo "Edi.R2Backup: refusing symbolic links in $bucket" >&2
        status=1
        continue
    fi
    echo "Edi.R2Backup: inspecting $bucket"
    if ! rclone lsjson "$R2_REMOTE:$bucket" --recursive --files-only --hash-type MD5 --no-modtime --no-mimetype > "$listing"; then
        echo "Edi.R2Backup: source listing failed for $bucket; destination untouched" >&2
        status=1
        continue
    fi
    set -- --delete-after --fast-list --use-server-modtime --stats 1m --stats-one-line --stats-log-level NOTICE
    # ponytail: one comparison mode per bucket; split by object only if mixed buckets make local edits harder to detect.
    if ! comparison=$(jq -r 'if all(.[]; (.Hashes.md5 // "") != "") then "checksum" else "modtime" end' "$listing"); then
        echo "Edi.R2Backup: invalid source listing for $bucket; destination untouched" >&2
        status=1
        continue
    fi
    if [ "$comparison" = checksum ]; then
        set -- "$@" --checksum
        echo "Edi.R2Backup: $bucket comparison=checksum"
    else
        echo "Edi.R2Backup: $bucket comparison=size+server-modtime (some objects have no whole-file MD5)"
    fi
    [ "$mode" != --dry-run ] || set -- "$@" --dry-run
    if rclone sync "$R2_REMOTE:$bucket" "$destination" "$@"; then
        echo "Edi.R2Backup: $bucket completed"
    else
        echo "Edi.R2Backup: $bucket failed" >&2
        status=1
    fi
done
exit "$status"
