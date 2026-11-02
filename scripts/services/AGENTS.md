# scripts/services/ — Community hub LAN service runners

Small, uniform launchers for the offline **Community** apps (chat, mail, forum, paste) that Val Ark
reverse-proxies at `/app/<id>/`, plus the SeaweedFS storage backend — this is where you work when a
community service won't start, misbehaves behind the proxy, or needs a new arch.

↑ [Repo root](../../AGENTS.md) · [Doc map](../../docs/README.md) · [scripts/](../AGENTS.md) · [Community guide](../../docs/COMMUNITY.md)

## What's here

| File | Runs | Fixed 127.0.0.1 port(s) | Proxied at | Purpose |
|------|------|-------------------------|------------|---------|
| `chat.sh` | ngIRCd + The Lounge | The Lounge web `9000` (proxied); ngIRCd `6667` | `/app/chat/` | Offline LAN real-time chat: a tiny IRC daemon behind a web client with persistent history |
| `mail.sh` | maddy + alps | alps webmail `1323` (proxied); maddy SMTP `587`, IMAP `143`, MX `25` | `/app/mail/` | Local-community email (no outbound relay/federation); auth mandatory |
| `forum.sh` | NodeBB + Redis | NodeBB `4567` (proxied); Redis `6379` | `/app/forum/` | Message-board forum (ActivityPub disabled); Redis-backed, self-registration at `/app/forum/register` |
| `paste.sh` | MicroBin (single Rust binary) | `8085` (proxied) | `/app/paste/` | Pastebin + file-upload + URL-shortener; HTTP Basic + admin password |
| `seaweedfs.sh` | SeaweedFS `weed` (all-in-one) | master `9333`, volume `8085`, filer `8889`, s3 `8333` | *(not proxied — backend infra)* | Object/blob storage node (master+volume+filer+S3) for the mesh |

## How to work here

**Shared shape** (chat/mail/forum/paste): each is a standalone `start | stop | status` runner (most
add `restart`), binds a **fixed** `127.0.0.1` port, keeps state under `STATE_DIR/services/<id>/`, and is
**same-origin reverse-proxied** by `server.js`'s sub-app map (see `serviceEnabled(id)` and the `/app/<id>/`
proxy). A service is **enabled** by listing its id in `VALARK_SERVICES` in `.env` (space-separated, e.g.
`VALARK_SERVICES="chat mail forum paste"`); the loop's `ensure_services()` runs `<id>.sh start` every cycle
(idempotent — it both launches and respawns dead daemons) and the Community UI only offers one-click Start
for enabled + mirrored services.

- **Account seams differ per service:** `chat.sh adduser`, `mail.sh adduser` (also `creds`/`acct`), forum
  self-registers (first-run admin auto-created), `paste.sh creds` (single shared Basic auth, no per-user).
- **Bind address** comes from `VALARK_BIND` (default `127.0.0.1`); the proxy is the only public path, so
  keep services bound to localhost.
- **SeaweedFS is the exception:** `start | status` only, runs in the **foreground** via `exec`, data lives at
  `VALARK_HOME/seaweedfs` (not under `STATE_DIR/services/`, so it can be pinned to a second disk), and it is
  **not** in the `/app/<id>/` proxy map (it's storage infra, not a framed web app).
- **Verify on the REAL box, not just CI.** Login/nick/channel flows and proxy behaviour only surface when a
  human actually clicks through the deployed appliance — green e2e is necessary, not sufficient.

## Gotchas

- **Close fd 8 (`8>&-`) on every backgrounded daemon** — chat/mail/forum/paste all do. These runners are
  spawned from inside the loop's `run_locked` cycle, which holds `loop.lock` on **fd 8**; a detached child
  inherits that fd and shares the open-file-description holding the `flock`, so the lock would **never
  release** and every later self-heal cycle would deadlock. `loop.sh:ensure_services()` also closes fd 8 for
  the whole subtree as a central guard. (SeaweedFS runs foreground/`exec`, so it has no detached child to
  guard.) See [gotchas.md](../../docs/knowledge/gotchas.md).
- **NodeBB `/app/forum/` 503s under rapid bursts are BENIGN** — a transient of `pipeProxy` that self-recovers.
  Render as "recovering," not an error; **do not** rework the proxy. See
  [gotchas.md](../../docs/knowledge/gotchas.md#benign-dont-fix).
- **arm64 native-module rebuilds.** `forum.sh`'s `ensure_native_deps()` detects a `require('sharp')` failure
  (mirrored `node_modules` built on x86_64) and reinstalls `sharp` for this host's `--os/--cpu`; NodeBB v4
  needs Node ≥22 (uses the mirrored runtime). Redis is a separate binary and is deliberately left running
  across a forum `stop`. See the cross-architecture section of
  [gotchas.md](../../docs/knowledge/gotchas.md).
- **Port `8085` is doubly-claimed by default** — it's MicroBin's default *and* the SeaweedFS volume port.
  Don't run both with defaults on one host; override via `.env`.

## Related

- [docs/COMMUNITY.md](../../docs/COMMUNITY.md) — the Community hub design, per-service setup, cross-arch notes
- [scripts/AGENTS.md](../AGENTS.md) — the engine; `server.js` proxy + `loop.sh` `ensure_services()`
- [scripts/tools/AGENTS.md](../tools/AGENTS.md) — how the service *source* is mirrored (e.g. `tools/chat.sh`)
- [docs/knowledge/gotchas.md](../../docs/knowledge/gotchas.md) — forum burst, cross-arch node/redis/sharp
