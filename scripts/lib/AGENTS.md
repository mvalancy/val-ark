# scripts/lib/ — shared building blocks (sourced/required, not entry points)

The contracts everything else stands on: data-root resolution, the curation pipeline,
fail-closed moderation, identity/commissioning, and the offline local CA. Nothing here is a
user-facing command — these are libraries the entry points in [`scripts/`](../AGENTS.md) source or `require`.

↑ [Repo root](../../AGENTS.md) · [Doc map](../../docs/README.md) · [scripts/](../AGENTS.md)

## What's here

| File | Kind | Purpose |
|------|------|---------|
| `valark-env.sh` | sourced (bash) | **THE foundation.** Resolves `DATA_ROOT` and exports the whole layout (`STATE_DIR`, `MODELS_DIR`, `TOOLS_DIR`, `CONTENT_DIR`, `ZIM_DIR`, …) + disk-math/writability helpers. Sourced by nearly every script. |
| `catalog.sh` | sourced (bash) | Curation **stage 1**: emits unified TAB-delimited download *candidates* from Kiwix OPDS + `data/models-extra.tsv` + `data/installers.tsv`, with an intrinsic `value` per item. |
| `kiwix_catalog.py` | CLI (python, stdlib) | Fetches the **live** Kiwix OPDS feed → one TSV row per ZIM. Exit code is a **completeness signal** (see Gotchas). |
| `planner.py` | CLI (python, stdlib) | Curation **stage 2**: reads candidates on stdin, emits an ordered plan (diversity → small-valuable → fill), plus eviction victims (`--evict-need`) and the "absent" browse feed (`--list-absent`). |
| `catalog-parse.js` | required (JS module) | Pure parser turning `librarian.sh catalog` TSV into the web browse feed; optional ZIM language filter that narrows **output only** (#57). |
| `moderation.sh` | sourced + CLI (bash) | On-device moderation **decision core** (`check`/`decide`/`sniff`/`ready`): screens a file with the box's own AI, prints one JSON verdict, mirrors it in the exit code. **Fail-closed.** |
| `mod-sweep.sh` | CLI (bash) | Loop **enforcement** point: screens files already *stored* on the box and **quarantines** anything not cleanly allowed into a review queue. |
| `auth.js` | required + CLI (JS) | Admin identity: one salted-scrypt passcode in `<state>/auth.json` + stateless HMAC sessions + use-mode. Shared by `server.js` and the `valark` CLI. |
| `commission.js` | required + CLI (JS) | First-boot claim/commissioning + config store (name/profile/use-mode/recovery/moderation) in `<state>/settings.json`. Shared by `server.js` and `valark`. Depends on `auth.js`. |
| `tls.sh` | sourced + CLI (bash) | Offline, zero-config **local CA** — a long-lived Val Ark CA + short-lived server leaf covering every name/IP the box answers to, for LAN HTTPS with no internet. |

## How to work here

**These files are contracts.** Their exported names, TSV column schemas, and exit codes are relied on
across bash + Node + Python. Before you change any of them:

- **`grep` the callers first.** An exported var (`STATE_DIR`, `TOOLS_DIR`, …), a TSV schema, or an exit
  code is a cross-language API — renaming one silently breaks `server.js`, `librarian.sh`, or `valark`.
- **`valark-env.sh` is idempotent** (`_VALARK_ENV_LOADED` guard) — safe to source repeatedly; keep it that
  way. It also predates `set -u` in its callers, so it must not assume `nounset`.
- **JS/py modules are pure and offline-unit-testable.** `catalog-parse.js` (`parseCatalogTSV`), `planner.py`,
  and `kiwix_catalog.py` take stdin/args → stdout with no side effects; `moderation.sh` accepts a
  `VALARK_MODERATION_CMD` **stub** so the decision path can be tested without a model. Keep all of this
  **dependency-free** (zero-dep server + offline-first are prime directives).
- **`auth.js`/`commission.js` are shared by two front-ends** (web wizard in `server.js`, console in
  `valark`) — a behaviour change must be correct from *both* entry points; passcodes travel via the
  `VALARK_PW` env var, never argv (stays out of `ps`).

## Gotchas

- **Fail-closed moderation (`moderation.sh`).** Exit `0`/`1`/`2` = **allow / block / hold**. Absent model or
  missing binary, timeout/error, and garbage/unparseable output all → **HOLD** (never a silent allow). HOLD
  *is* the fail-closed state. See [gotchas.md](../../docs/knowledge/gotchas.md#content-moderation-phase-7).
- **`mod-sweep.sh` quarantines fail-closed too.** It sweeps only **plain-file** upload trees (never DB-backed
  stores like MicroBin's SQLite or maddy's mail), and anything not cleanly `allow`ed — including screen
  errors — is *moved* to quarantine (`STATE_DIR/moderation/quarantine/`) and logged to `queue.jsonl`.
  Symlinks in a store are quarantined as the link, never followed (TOCTOU/exfiltration guard).
- **`kiwix_catalog.py` exit code is a COMPLETENESS gate.** It returns `0` only when **every** requested
  language fetched *and* yielded ≥1 entry; any failed/empty language → `2`. `catalog.sh:catalog_refresh_zim`
  replaces the on-disk cache **only** on `rc==0`, so a partial/HTTP-200-but-empty fetch never overwrites a
  fuller cache. See [gotchas.md](../../docs/knowledge/gotchas.md#catalog-empty-feed-95).
- **`catalog-parse.js` language filter narrows OUTPUT, not the cache (#57).** The server refreshes the *full*
  multi-language cache and filters languages on the way out here — it must never shell the catalog with a
  narrowed `VALARK_ZIM_LANGS`, which used to atomically overwrite the shared cache English-only.
- **Sensitive state placement.** `tls.sh` keeps CA/leaf **keys OFF the world-readable data disk**
  (`$XDG_CONFIG_HOME/val-ark/tls`, CA key `chmod 600`) because the data mount may be FUSE/NTFS with no mode
  bits. `auth.js`/`commission.js` write `auth.json`/`settings.json`/claim-token **`0600` under `STATE_DIR`**
  (on the data tree) — secured by file mode, not by living off-disk. Don't relocate either onto a
  world-readable path.

## Related

- [scripts/AGENTS.md](../AGENTS.md) — the engine that sources/requires all of this
- [docs/LIBRARIAN.md](../../docs/LIBRARIAN.md) — the curation model (`catalog.sh` + `planner.py` + kiwix feed)
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — data-root layout, self-heal, moderation phases
- [docs/knowledge/gotchas.md](../../docs/knowledge/gotchas.md) — moderation, catalog completeness (#95), #57, path safety
