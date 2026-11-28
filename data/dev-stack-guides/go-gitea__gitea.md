# Gitea

A git forge: repositories, issues, pull requests and a web UI, in one program. With the
internet gone it is where a team keeps and reviews its code.

## On the Ark itself

You do not need these files for that. The Ark already runs Gitea as a Community service:
open **Community** in the web UI and press **Start** on Git (it then lives at `/app/gitea/`).
See `docs/COMMUNITY.md` in the Val Ark source.

## On another machine

The files here are the same program for other boxes.

- Linux / macOS: take `gitea-<version>-linux-amd64` (or `-linux-arm64`, `-darwin-arm64`).
  It is a single program, nothing to unpack.
- Windows: `gitea-<version>-windows-amd64.exe`.

```
chmod +x gitea-*-linux-amd64
./gitea-*-linux-amd64 web
```

Then open `http://localhost:3000` and finish the short setup page. Choose SQLite as the
database: it needs no other software.

## First steps offline

- Create an account (the first one is the administrator), then a repository.
- Push to it: `git remote add ark http://<that machine>:3000/<user>/<repo>.git`, then `git push ark main`.
- To bring in code the Ark already holds, clone one of its git bundles
  (`git clone <file>.bundle`) and push that.
