#!/bin/sh
set -eu

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export RCLONE_CONFIG="$fixture/rclone.conf"
export R2_REMOTE=test
export R2_BUCKETS='test-one test-two'
mkdir -p "$fixture/source/test-one/nested" "$fixture/source/test-two"
cat > "$RCLONE_CONFIG" <<EOF
[test]
type = alias
remote = $fixture/source
[nohash]
type = crypt
remote = $fixture/encrypted
password = $(rclone obscure integration-test-password)
EOF
printf same > "$fixture/source/test-one/nested/unchanged.txt"
printf AAAA > "$fixture/source/test-one/changed.txt"
printf delete > "$fixture/source/test-one/deleted.txt"
printf second > "$fixture/source/test-two/second.txt"
/app/entrypoint.sh validate
/app/entrypoint.sh run --dry-run
[ ! -e /backup/test-one ]
/app/entrypoint.sh run
cmp "$fixture/source/test-one/nested/unchanged.txt" /backup/test-one/nested/unchanged.txt
cmp "$fixture/source/test-two/second.txt" /backup/test-two/second.txt
before=$(stat -c '%i:%Y:%s' /backup/test-one/nested/unchanged.txt)
snapshot=$(find /backup/test-one /backup/test-two -type f -exec stat -c '%n:%i:%Y:%s' {} \; | sort)
/app/entrypoint.sh run > "$fixture/repeat.log" 2>&1
[ "$snapshot" = "$(find /backup/test-one /backup/test-two -type f -exec stat -c '%n:%i:%Y:%s' {} \; | sort)" ]
[ "$before" = "$(stat -c '%i:%Y:%s' /backup/test-one/nested/unchanged.txt)" ]

# Same size and timestamp, different bytes: checksum must catch this.
printf BBBB > "$fixture/source/test-one/changed.txt"
touch -r /backup/test-one/changed.txt "$fixture/source/test-one/changed.txt"
rm "$fixture/source/test-one/deleted.txt"
printf new > "$fixture/source/test-one/new.txt"
printf extra > /backup/test-one/local-only.txt
/app/entrypoint.sh run
cmp "$fixture/source/test-one/changed.txt" /backup/test-one/changed.txt
[ ! -e /backup/test-one/deleted.txt ]
[ ! -e /backup/test-one/local-only.txt ]
[ -f /backup/test-one/new.txt ]
[ "$before" = "$(stat -c '%i:%Y:%s' /backup/test-one/nested/unchanged.txt)" ]

# Local edits must lose to the remote even when the local timestamp is newer.
printf CCCC > /backup/test-one/changed.txt
touch -d '2035-01-01' /backup/test-one/changed.txt
/app/entrypoint.sh run
cmp "$fixture/source/test-one/changed.txt" /backup/test-one/changed.txt

# A failed source listing must preserve destination files and return failure.
mv "$fixture/source/test-one" "$fixture/source/temporarily-unavailable"
if /app/entrypoint.sh run; then exit 1; fi
[ -f /backup/test-one/new.txt ]
mv "$fixture/source/temporarily-unavailable" "$fixture/source/test-one"

# A successfully listed empty source is authoritative, too.
rm "$fixture/source/test-two/second.txt"
/app/entrypoint.sh run
[ ! -e /backup/test-two/second.txt ]

# Crypt has no remote MD5: exercise the actual rclone modtime fallback.
mkdir -p "$fixture/plain"
printf AAAA > "$fixture/plain/data.txt"
rclone copy "$fixture/plain" nohash:test-nohash
export R2_REMOTE=nohash R2_BUCKETS=test-nohash
/app/entrypoint.sh run > "$fixture/nohash.log" 2>&1
grep -q 'comparison=size+server-modtime' "$fixture/nohash.log"
cmp "$fixture/plain/data.txt" /backup/test-nohash/data.txt
nohash_before=$(stat -c '%i:%Y:%s' /backup/test-nohash/data.txt)
/app/entrypoint.sh run
[ "$nohash_before" = "$(stat -c '%i:%Y:%s' /backup/test-nohash/data.txt)" ]
printf BBBB > "$fixture/plain/data.txt"
touch -d '2030-01-01' "$fixture/plain/data.txt"
rclone copy "$fixture/plain" nohash:test-nohash --ignore-times
/app/entrypoint.sh run
cmp "$fixture/plain/data.txt" /backup/test-nohash/data.txt

export R2_REMOTE=test
export R2_BUCKETS='../escape'
if /app/entrypoint.sh validate; then exit 1; fi
export R2_BUCKETS='test-one test-one'
if /app/entrypoint.sh validate; then exit 1; fi
export R2_BUCKETS='   '
if /app/entrypoint.sh validate; then exit 1; fi
export R2_BUCKETS=test-one
ln -s "$fixture/source" /backup/test-one/unsafe-link
if /app/entrypoint.sh run; then exit 1; fi
rm /backup/test-one/unsafe-link

flock /backup/.edi-r2backup.lock sh -c 'if /app/entrypoint.sh run; then exit 1; fi'
export BACKUP_CRON='not a cron expression'
if /app/entrypoint.sh schedule; then exit 1; fi
export BACKUP_CRON='0 2 * * 4' TZ=Asia/Taipei
timeout -s TERM 2 /app/entrypoint.sh schedule > "$fixture/schedule.log" 2>&1 || case "$?" in 124|143) ;; *) exit 1 ;; esac
grep -q 'schedule=0 2 \* \* 4 timezone=Asia/Taipei' "$fixture/schedule.log"
grep -q 'read crontab' "$fixture/schedule.log"
echo 'PASS: mirror, zero retransfers, same-size updates, remote authority, multiple buckets, failure safety, no-hash fallback, validation, locking and scheduling'
