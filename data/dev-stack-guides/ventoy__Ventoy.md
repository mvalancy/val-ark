# Ventoy

Turns a USB stick into a boot menu. Install Ventoy on the stick once, then just copy ISO
files onto it; at boot you pick which one to start. One stick can carry every installer
and rescue system the Ark holds.

## Make the stick

This erases the USB stick. Check twice that you picked the right drive.

Windows: unpack `ventoy-<version>-windows.zip`, run `Ventoy2Disk.exe`, choose the stick, press **Install**.

Linux: unpack `ventoy-<version>-linux.tar.gz`, find the stick's device name with `lsblk`
(for example `/dev/sdb`: the whole disk, not a partition), then:

```
tar xzf ventoy-*-linux.tar.gz
cd ventoy-*/
sudo sh Ventoy2Disk.sh -i /dev/sdX
```

`VentoyWeb.sh` in the same folder gives a point-and-click page in your browser instead.

There is no macOS installer. `ventoy-<version>-livecd.iso` is a small boot disc that can
install Ventoy from any PC.

## First steps offline

- The stick now shows up as a normal drive named `Ventoy`. Copy `.iso` files onto it
  (from the Ark's OS Installers), in any folders you like.
- Boot a PC from the stick (the boot menu key is often F12, F10 or Esc) and choose an ISO.
- To add or remove systems later, just copy or delete files. No need to reinstall.
- Update Ventoy on a stick without losing its files: `sudo sh Ventoy2Disk.sh -u /dev/sdX`.

If a PC refuses to boot the stick, Secure Boot is the usual reason: Ventoy shows a one-time
"enroll key" screen on first boot. Follow it, or switch Secure Boot off in the PC's setup.
