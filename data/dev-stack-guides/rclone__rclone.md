# rclone

Copies and syncs files between folders, machines and storage services. Offline it moves
data between boxes over SSH, to a NAS, or to an S3 store on the LAN (SeaweedFS, MinIO).

## Install

One zip per platform with the program inside:
`rclone-<version>-linux-amd64.zip`, `-linux-arm64.zip`, `-osx-arm64.zip`, `-windows-amd64.zip`.

```
unzip rclone-*-linux-amd64.zip
sudo cp rclone-*-linux-amd64/rclone /usr/local/bin/
rclone version
```

On Windows, unpack and run `rclone.exe` from a terminal in that folder.

## First steps offline

Local folders need no setup:

```
rclone sync /data/photos /mnt/backup/photos --progress
rclone check /data/photos /mnt/backup/photos
```

`sync` makes the destination match the source, deleting extra files there. Try it with
`--dry-run` first. `copy` never deletes.

For another machine or an S3 store, describe it once with `rclone config` (choose `sftp`
for a box you can SSH into, or `s3` with an "other S3 compatible" provider and the
endpoint `http://<ark>:8333`). Then use the name you gave it:

```
rclone copy /data/photos nas:backup/photos --progress
rclone ls nas:backup
```

Share a folder with other machines for a moment: `rclone serve http /data --addr :8080`
