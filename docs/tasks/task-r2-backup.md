# R2 backup implementation and deployment

- Goal: Build a generic Docker tool named Edi.R2Backup and deploy weekly R2-to-local mirrors on the backup server, with Windows Samba write access.
- Research: The production application uses two rclone Docker volumes. The backup server has a writable Samba share and sufficient disk space. Sensitive configuration values are excluded from this record.
- Scope: Independent repository; no changes to the application or production storage. Shell orchestration, rclone transfers, Supercronic scheduling.
- Decisions: Back up both image buckets, Thursday 02:00 in Asia/Taipei. User approved reusing existing production credentials, which can later be replaced with a dedicated read-only token.

## Execution order and status

1. Research remote storage, backup host and Samba: complete.
2. Implement container, configuration, scripts, documentation: complete.
3. Build and run isolated integration tests: complete.
4. Transfer image/configuration and credentials securely: complete.
5. Dry-run, first mirror and zero-transfer repeat: complete.
6. Verify Windows write operations and enable weekly scheduler: complete.

## Verification log

- Production configuration and source object listing inspected read-only. Credentials were not printed.
- Backup host: Ubuntu 26.04.1, Docker and Compose available; existing share maps to the requested Windows drive.
- Local Docker engine is now available.
- Docker build succeeded. Integration tests passed with a read-only root filesystem, tmpfs, dropped capabilities and no-new-privileges.
- Confirmed no replacement of unchanged files, same-size/same-time content changes, remote authority over local edits, empty-source deletion, multi-bucket isolation, source-error safety, missing-MD5 fallback, path validation, locking and schedule validation/startup.
- Deployed under `/opt/docker/edi-r2backup`; private credentials are outside the repository at `/etc/edi-r2backup/rclone.conf`, mode 600, owned by the backup user.
- Host mirror root: `/srv/share/moonglade-r2-backup`, available through the existing Windows Samba mapping. Container UID/GID: 1000:1000.
- Real-source dry-run succeeded and wrote no image files. First sync completed in 732.9 seconds: 2,677 primary objects (205,616,089 bytes) and 1,136 original objects (96,400,055 bytes).
- Repeat sync completed in 13.5 seconds with zero bytes transferred and unchanged inode/size/mtime for every downloaded file.
- rclone checksum checks reported 2,677 and 1,136 matching files, respectively, with zero differences.
- Windows successfully created, modified, renamed and deleted disposable files/directories, and opened a downloaded file for writing and renamed it back. Original image content was preserved.
- Scheduler is running with `0 2 * * 4` and `Asia/Taipei`. Native scheduler output confirms the next run at 2026-10-08 02:00 +08:00.
- User approved the additional Samba owner-inheritance setting. Windows-created directories now belong to the backup user, and the backup user successfully created a file inside one. Windows successfully modified, renamed and deleted that container-user-created file. All disposable permission-test files and directories were removed.
- Final manual execution through the running scheduler container succeeded with zero bytes transferred. Both object counts and byte totals remain correct; every downloaded file is owned by UID 1000, and no unexpected entries remain in the backup root. Confirmed credential mode 600, container user 1000:1000, read-only container root and restart policy `unless-stopped`.

## Issues and follow-ups

- Objects without a whole-file MD5 use size/server-modtime comparison. Same-size edits preserving timestamps require separate full-content verification.
- Replace reused credentials with a bucket-scoped Object Read only token when available.
- Samba uses an administrative share user, causing Windows-created directories to be owned by root. User approved `inherit acls = yes` and, after actual tests showed ACL inheritance alone was insufficient, `inherit owner = yes` on the existing share. Both are applied and verified; no existing owners were changed. Original configurations are retained at `/etc/samba/smb.conf.edi-r2backup.before` and `/etc/samba/smb.conf.edi-r2backup.before-owner`.
- Rollback: stop/remove only this Compose service. Existing mirrors remain on disk. Production deployment is untouched.
