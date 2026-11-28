# KeePassXC

A password manager that keeps everything in one encrypted file on your own disk. Cloud
password managers stop syncing when the internet goes; this one never needed it. Every new
LAN service means another password, and this is where they go.

## Install

- Linux: `KeePassXC-<version>-x86_64.AppImage` (or `-aarch64` for ARM64). Make it runnable
  and start it: `chmod +x KeePassXC-*.AppImage && ./KeePassXC-*.AppImage`
- macOS: the `.dmg`; open it and drag KeePassXC to Applications (`arm64` for Apple Silicon).
- Windows: `KeePassXC-<version>-Win64.msi` (installer) or the `-Win64.zip` portable version.

If an AppImage will not start on Ubuntu, install `libfuse2` from the Ark's offline APT sets,
or run it with `--appimage-extract-and-run`.

## First steps offline

- **Database, New Database.** Pick a name, keep the default encryption settings, and choose
  one strong master password. That password is the only one you must remember, and it
  cannot be recovered if you lose it.
- Save the `.kdbx` file somewhere you back up. The file is encrypted, so a copy on a USB
  stick or on the Ark is safe as long as the master password is good.
- Add an entry for each service; the dice button makes a random password.
- Share with a household by keeping the `.kdbx` file in a shared folder (Syncthing from the
  Ark's Software page keeps copies in step).

In the settings, turn off the check for updates: offline there is nothing to reach.
