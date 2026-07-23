# scripts/ — the Val Ark engine

Orchestration, curation, self-heal, and the zero-dependency web server that make Val Ark fill any
disk and keep itself healthy 24/7. Start here to understand how a box boots, fills, serves, and repairs.

↑ [Repo root](../AGENTS.md) · [Doc map](../docs/README.md) · [Architecture](../docs/ARCHITECTURE.md) · [Librarian](../docs/LIBRARIAN.md) · [Community](../docs/COMMUNITY.md)

## What's here

### Entry points

| File | Purpose |
|------|---------|
| `../start.sh` → `setup.sh` | Repo-root interactive menu; `setup.sh` does first-run dependency checks + directory/layout creation. |
| `librarian.sh` | Disk-fill + curation engine. `status\|plan\|fill\|verify\|evict\|maintain\|refresh\|catalog\|request\|pin\|unpin\|pins`. Fills any-size disk from **live** catalogs: diversity → small-valuable → fill → evict. |
| `loop.sh` | 24/7 self-heal cycle. `once` (one cycle) / `run [SECS]` / `install [MIN]` (flock-guarded cron + `@reboot`) / `uninstall`. |
| `verify.sh` | Functional checks: tools run, kiwix serves a real ZIM, a tiny LLM infers, the web API answers, fleet nodes reachable over SSH. `[local\|fleet\|all]`. |
| `server.js` | **Zero-dependency** Node server: web UI + JSON API + SSE + `/api/archive/` (Range/resumable) + reverse proxies. Auto-launches `kiwix-serve`. (Navigation map below.) |
| `valark` | Admin & recovery CLI (Phase-2 safety net): `setpassword`, `verify`, `auth {status\|list}`, `usemode`, `claim`, `setup-status`, `reset --tier1\|--tier2`. **Content-safety invariant:** every reset touches only `<state>` — never the content/model libraries. |

### Bulk mirrors / maintenance

| File | Purpose |
|------|---------|
| `download-tools.sh` → `tools/*.sh` | Discovers + runs the ~50 per-tool mirror scripts (`list\|<tool>\|all\|validate`). See [tools/AGENTS.md](tools/AGENTS.md). |
| `download-models.sh` | Curated AI-model downloads to `<root>/models/` (7 categories; tiers 1–3; resumable; never aborts). |
| `download-zims.sh` | Direct ZIM content downloads for Kiwix. |
| `update.sh` | Refresh installers/tools/apps/assets + report model paths (`ollama\|tools\|apps\|sources\|assets\|links\|check\|paths\|disk\|cron\|all`). |
| `mirror-self.sh` | Self-replication: package the codebase (git bundle + tarball + VERSION) under `<data>/sources/val-ark/`, served at `/sources/` + `/bootstrap.sh`. |
| `release.sh` | Tag a release from the repo-root `VERSION` file (unprefixed `0.x`; `--push`). |
| `audit-tools.sh`, `monitor.sh`, `status.sh`, `retry-failed.sh`, `screenshots.sh`, `optimize-images.py`, `uninstall.sh` | Operational helpers (report/watch/retry/capture/cleanup). |

### Subsystems (own AGENTS.md)

- [`lib/`](lib/AGENTS.md) — shared sourced/required building blocks (data-root, curation pipeline, moderation, auth, TLS).
- [`services/`](services/AGENTS.md) — Community hub LAN service runners (chat/mail/forum/paste/seaweedfs).
- [`tools/`](tools/AGENTS.md) — the ~50-script tool-mirroring subsystem + `_common.sh`.

## server.js navigation map

Zero-dep Node HTTP(S) server, ~3.4k lines. Sections are marked by `// ====` banners; line ranges below
(re-grep `// ====` if they drift). ~48 `/api/…` routes are dispatched inside **Request Handling**.

| Lines | Section | What lives here |
|------:|---------|-----------------|
| 1–149 | Config & bootstrap | requires (incl. `./lib/catalog-parse`), `ROOT`, `APP_VERSION` (repo-root `VERSION`), `.env` parse, listen ports, `resolveDataRoot`, `safeModeState`, `boxCommissioned`. |
| 150–186 | Input Validation | `isAlphanumDash`, `isCatalogId` — allowlist guards for request ids (no client data reaches a shell). |
| 187–204 | Status Cache | `invalidateCache` + the SSE/status memo. |
| 205–329 | Download Manager | `broadcastSSE`, `startDownload`, `cancelDownload` — spawn librarian/download scripts, stream progress over SSE. |
| 330–508 | Status Helpers (cached) | `getDiskStatus` / `getToolsStatus` / `getContentStatus` / `getModelsStatus` — data behind `/api/status/*`. |
| 509–958 | Packages manifest | `computePackages`/`getPackages` (`/api/packages` — what THIS box can hand out) + storage/catalog helpers. |
| 959–1555 | Request Handling | body/CORS/auth helpers (`isLocalhost`, `isAdmin`, `isReadGated`, `readAllowed`, `rateLimitOk`) + **`handleAPI`** — the ~48 `/api/…` routes: `status/*`, `catalog/*`, `request`, `download/*`, `service/*`, `auth/*`, `setup/*`, `moderation/*`, `maintenance/repair`, `ask`, `health`, `packages`. |
| 1556–2845 | Static File Serving | `serveStatic`, `serveArchive` (`/api/archive/`, HTTP Range, resumable), `pipeProxy` — same-origin reverse proxy to `/kiwix/` and the `/app/<id>/` community services. Path-traversal protection throughout. |
| 2846–2927 | TLS / local-CA | reads the `tls.sh`-generated cert/key; serves `/ca.crt`; `serveBootstrap` for `/bootstrap.sh`. |
| 2928–3045 | Server (`handleRequest` + listen) | top-level router (blocks `..`/`%2e` early; routes `/ca.crt`, `/bootstrap.sh`, `/kiwix`, `/sources`, API, static); creates HTTP/HTTPS servers, binds `PORT` + `EXTRA_PORTS`. |
| 3046–3377 | Kiwix Auto-Launch | scans `content/zim` for complete `.zim`, launches `kiwix-serve` on the internal `KIWIX_PORT`, proxied at `/kiwix/`. |

**Served surfaces:** ~48 `/api/…` routes · `/app/<id>/` (chat/mail/forum/paste) · `/kiwix/` (offline library) · `/sources/` (self bundle/tarball) · `/bootstrap.sh` (host-aware installer) · `/ca.crt`.

## How to work here

- **Run from anywhere.** Every script sources `lib/valark-env.sh`, so paths resolve identically from the
  repo root or from `scripts/`. Never hardcode a host name, IP, or absolute path — resolve via
  `valark-env.sh` + `.env` (the repo is PUBLIC).
- **`loop.sh once` must be safe to run repeatedly and concurrently** with a standalone `librarian.sh fill`.
- **Verify docs/comment edits** with `bash -n <file>.sh` and `node -c scripts/server.js`; exercise
  user-facing flows on the **real box**, not just CI (green ≠ works).

## Gotchas

- **fd 8 (`loop.lock`) serialises the WHOLE loop cycle — detached children MUST close it.** `loop.sh`'s
  `run_locked` holds `loop.lock` on **fd 8** for the entire cycle. Any daemon it spawns (the web server, a
  community service) inherits that fd and shares the open-file-description holding the `flock`, so **the lock
  would never release** and every later cycle would deadlock. Spawn detached children with **`8>&-`**
  (server launch and `ensure_services()` both do). The librarian `fill` uses a **separate** flock on
  **fd 9** (`fill.lock`) — the two locks are intentionally distinct.
- **`server.js` MUST stay dependency-free (Prime Directive).** No `npm install`, ever — only Node built-ins
  (+ the repo's own `./lib/*`). Offline-first on a bare box is the whole point.
- **`realpath` containment on everything served.** A lexical path check does not stop an in-tree symlink from
  escaping `ROOT`; `serveArchive`/`serveStatic` `realpathSync` and confine (see `realpathWithin`, #101, and
  the per-`.zim` guard #112). See [gotchas.md](../docs/knowledge/gotchas.md#realpath-containment-101).
- **Moderation is fail-closed.** The screening core (`lib/moderation.sh`) and the loop's quarantine sweep
  (`lib/mod-sweep.sh`) HOLD/quarantine on absent model, timeout, or garbage output — never allow. A
  permissive wrapper must not re-open a fail-closed core.
- **Never hardcode host/paths.** Data location comes from `lib/valark-env.sh` (+ `.env`); machines are
  referred to by role, values by placeholder.

## Related

- [lib/AGENTS.md](lib/AGENTS.md) · [services/AGENTS.md](services/AGENTS.md) · [tools/AGENTS.md](tools/AGENTS.md)
- [docs/LIBRARIAN.md](../docs/LIBRARIAN.md) · [docs/COMMUNITY.md](../docs/COMMUNITY.md) · [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
- [docs/knowledge/gotchas.md](../docs/knowledge/gotchas.md) — loop lock, server path safety, moderation, cross-arch
- [scripts/README.md](README.md) — human-oriented script reference (diagram + command examples)
