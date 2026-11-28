# restic

Backups: encrypted, deduplicated and checkable. It stores snapshots of your folders in a
"repository" on another disk, another machine, or an S3 store on the LAN.

## Install

- Linux / macOS: `restic_<version>_linux_amd64.bz2` (or `_linux_arm64`, `_darwin_arm64`).
  The file is the program, compressed.
- Windows: `restic_<version>_windows_amd64.zip`.

```
bunzip2 restic_*_linux_amd64.bz2
chmod +x restic_*_linux_amd64
sudo mv restic_*_linux_amd64 /usr/local/bin/restic
restic version
```

## First steps offline

Make a repository on a backup disk. You choose a password; without it the backup cannot
be read by anyone, including you.

```
restic -r /mnt/backup/repo init
restic -r /mnt/backup/repo backup ~/Documents
restic -r /mnt/backup/repo snapshots
```

Get files back:

```
restic -r /mnt/backup/repo restore latest --target /tmp/restored
```

Check that the backup is healthy: `restic -r /mnt/backup/repo check`

Keep seven daily and four weekly snapshots and drop the rest:
`restic -r /mnt/backup/repo forget --keep-daily 7 --keep-weekly 4 --prune`

Other places to keep a repository: `-r sftp:user@host:/backups/repo` (any box with SSH) or
`-r s3:http://<ark>:8333/bucket` (an S3 store on the LAN, with `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` set).
