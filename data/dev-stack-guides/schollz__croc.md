# croc

Sends files from one computer to another. The sender gets a short code phrase, the
receiver enters it, and the transfer is encrypted end to end. No accounts, no shared folders.

Normally the two sides meet through a public relay on the internet. Offline, run your own
relay on the LAN and point both sides at it.

## Install

- Linux: `croc_v<version>_Linux-64bit.tar.gz` (or `Linux-ARM64`).
- macOS: `croc_v<version>_macOS-ARM64.tar.gz`.
- Windows: `croc_v<version>_Windows-64bit.zip`.

```
tar xzf croc_v*_Linux-64bit.tar.gz croc
sudo mv croc /usr/local/bin/
croc --version
```

## Run a relay on the LAN

On one machine that stays on:

```
croc relay
```

It listens on TCP ports 9009 to 9013. Leave it running. (The Ark does not run a relay for
you yet; start one on any box and use that box's address below.)

## First steps offline

Send, pointing at your relay:

```
croc --relay <relay address>:9009 send bigfile.iso
```

croc prints a code phrase and the exact command for the other machine. Run that command
there, with the same `--relay <relay address>:9009` right after `croc`.

Folders work the same way: `croc --relay <relay address>:9009 send myfolder/`

Both sides must name the same relay, and the receiver must be able to reach it on the
ports above.
