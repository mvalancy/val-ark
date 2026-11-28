# Git for Windows

Git itself, for Windows. Without it a fresh Windows machine cannot clone, commit or push,
so Gitea and every "build from source" guide is out of reach.

## Which file

- `PortableGit-<version>-64-bit.7z.exe`: no install, no admin rights. Run it, pick a folder,
  and Git lives there (it works from a USB stick). Start `git-bash.exe` or `git-cmd.exe` in that folder.
- `Git-<version>-64-bit.exe`: the normal installer. It adds Git Bash to the Start menu and
  `git` to the PATH. Every default answer is fine.
- `MinGit-<version>-64-bit.zip`: a bare minimum for scripts and other programs. No Git Bash.
- The `-arm64` files are for Windows on ARM.

Linux gets git from the Ark's offline APT sets (`sudo apt install git`). On macOS, `git`
comes with Apple's command line tools, which the Ark does not carry: install those while
you still have internet.

## First steps offline

Tell Git who you are, once:

```
git config --global user.name "Your Name"
git config --global user.email "<your email address>"
```

Get code from the Ark. A `.bundle` file from its Source Code section is a whole repository:

```
git clone C:\path\to\project.bundle project
```

Or clone from the Ark's Gitea (Community, Git):

```
git clone http://<ark>/app/gitea/<user>/<repo>.git
```

If the Ark uses its own HTTPS certificate, install the Ark's CA first (the `/ca.crt` link
on the Ark), or Git will refuse the connection.
