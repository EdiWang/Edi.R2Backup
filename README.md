# Edi.R2Backup

Scheduled, one-way Cloudflare R2 bucket mirrors in Docker. Uses rclone for transfers and Supercronic for scheduling. No application integration, database, cloud SDK, or exposed port is required.

## Configure

1. Create an R2 **Object Read only** API token scoped to the buckets you want to back up. An existing read/write token works, but this tool only needs listing and reading permissions.
2. Copy `rclone.conf.example` to a private file outside this repository and your backup directory, fill in the credentials and endpoint, then restrict it to the container's UID. Never commit the real file.
3. Copy `.env.example` to `.env`, configure the buckets, paths, UID/GID and timezone, and create the destination directory before starting Compose.

Example for a Linux user with UID/GID 1000:

```sh
sudo install -d -m 750 -o 1000 -g 1000 /etc/edi-r2backup
sudo install -m 600 -o 1000 -g 1000 /path/to/private/rclone.conf /etc/edi-r2backup/rclone.conf
sudo install -d -m 755 -o 1000 -g 1000 /srv/r2-backup
cp .env.example .env
docker compose build
docker compose run --rm r2backup validate
docker compose run --rm r2backup run --dry-run
docker compose run --rm r2backup run
docker compose up -d
```

| Setting | Purpose |
| --- | --- |
| `BACKUP_CRON` | Five-field CRON expression. Default `0 2 * * 4`: Thursday at 02:00. |
| `TZ` | IANA timezone, such as `Asia/Taipei`. Default `Etc/UTC`. |
| `R2_REMOTE` | Remote section name in the rclone configuration. Default `r2`. |
| `R2_BUCKETS` | Space-separated bucket names, each mirrored independently. |
| `LOCAL_BACKUP_PATH` | Absolute host directory mounted at `/backup`. |
| `RCLONE_CONFIG_PATH` | Host path of the private rclone configuration, mounted read-only. |
| `PUID`, `PGID` | Container UID/GID. Default `1000:1000`. Match the local/Samba owner. |

Files retain their object paths beneath `<LOCAL_BACKUP_PATH>/<bucket-name>/`. Credentials stay outside that tree. Removing a bucket from configuration leaves its existing local directory untouched.

Changes to `.env` take effect after `docker compose up -d --force-recreate`. The scheduler does not automatically backfill missed runs or run a backup at startup; use the manual command for the first backup. AMD64 and ARM64 images are supported.

## Sync behavior

- The remote is authoritative. New and changed objects are downloaded; local files absent remotely are deleted. Local edits are overwritten and locally deleted remote files are restored. Store personal files outside the bucket directories.
- Before modifying a bucket directory, the tool lists the source and checks MD5 availability. When every object provides a whole-file MD5, rclone compares sizes and checksums. Identical content is skipped even if local timestamps differ; local same-size edits are detected.
- Multipart ETags are not whole-file MD5 hashes. If any object lacks a usable MD5, that bucket uses rclone's size and server modification time comparison instead. Unchanged objects are skipped, but edits preserving both size and timestamp cannot be detected in this mode. Strict byte-for-byte verification of hashless objects requires reading their remote contents, for example with `rclone check --download`; the scheduled job does not download every object to verify it.
- Source listing errors prevent that bucket from being synced. rclone deletes destination files after transfers and suppresses deletion when errors occur. Downloads use rclone's temporary-file-and-rename behavior. A valid, empty remote bucket intentionally empties its local mirror.
- A lock in the backup root prevents scheduled and manual jobs sharing that root from overlapping. Symbolic links in bucket destinations are rejected. Failures are logged, return a nonzero status, and do not prevent other configured buckets from being attempted.
- This is a current-state mirror, with no historical versions or object metadata archive. Source deletions are reflected in the mirror.

One recursive listing is kept in memory by jq and rclone. Very large buckets may require a larger container `/tmp` limit and more memory.

## Operations

```sh
docker compose logs --tail 100 r2backup
docker compose exec r2backup /app/backup.sh --dry-run
docker compose exec r2backup /app/backup.sh
docker compose stop
```

Use `exec` for manual runs while the scheduler is running so their output and exit status are visible immediately. The shared filesystem lock also protects `compose run`. Docker logs rotate at three 10 MiB files; no credentials are logged. Check logs after a scheduled run; external alerting is not included.

For Samba, give the container the same UID/GID as the authorized share user and ensure the share is writable. Avoid running as root or granting world-write permissions. Verify Windows create, edit, rename and delete operations on downloaded files before relying on the deployment.

If the Samba share uses `admin users`, Windows-created entries can become root-owned even when the backup folder belongs to the backup user. On a share where new entries should inherit the parent owner and ACLs, use:

```ini
inherit acls = yes
inherit owner = yes
```

These settings apply to the entire share and do not change existing owners. Back up `smb.conf`, validate with `testparm`, reload Samba, and verify that the backup user can write inside a directory newly created from Windows. ACL inheritance alone may still leave the backup user unable to write into root-owned directories.

## Test

The integration test uses real rclone against isolated local alias and crypt remotes. It exercises mirror changes, unchanged-file skipping, same-size updates, local edits, multi-bucket isolation, source failure protection, missing-MD5 fallback, input validation, locking and scheduler startup. It never touches R2.

```sh
docker build -t edi-r2backup:1.0.0 .
docker run --rm --mount type=bind,source="$(pwd)/tests",target=/tests,readonly \
  --entrypoint /bin/sh edi-r2backup:1.0.0 /tests/integration.sh
```

Dependencies are pinned to rclone 1.75.1 and Supercronic 0.2.49. Supercronic downloads are verified with SHA-256 during the image build.
