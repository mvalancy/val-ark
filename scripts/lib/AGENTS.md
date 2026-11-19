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
| `planner.py` | CLI (python, stdlib) | Curation **stage 2**: reads candidates on stdin, emits an ordered plan (essentials → diversity → small-valuable → fill), plus eviction victims (`--evict-need`), superseded small ZIM variants (`--superseded`; `librarian.sh fill` deletes them with an exact-id manifest rewrite, skipped after a STOP halt) and the "absent" browse feed (`--list-absent`). |
| `catalog-parse.js` | required (JS module) | Pure parser turning `librarian.sh catalog` TSV into the web browse feed; optional ZIM language filter that narrows **output only** (#57). |
| `moderation.sh` | sourced + CLI (bash) | On-device moderation **decision core** (`check`/`decide`/`sniff`/`ready`): screens a file with the box's own AI, prints one JSON verdict, mirrors it in the exit code. **Fail-closed.** |
| `mod-sweep.sh` | CLI (bash) | Loop **enforcement** point: screens files already *stored* on the box and **quarantines** anything not cleanly allowed into a review queue. |
| `auth.js` | required + CLI (JS) | Admin identity: one salted-scrypt passcode in `<state>/auth.json` + stateless HMAC sessions + use-mode. Shared by `server.js` and the `valark` CLI. |
| `commission.js` | required + CLI (JS) | First-boot claim/commissioning + config store (name/profile/use-mode/recovery/moderation) in `<state>/settings.json`. Shared by `server.js` and `valark`. Depends on `auth.js`. |
| `jobs.js` | required (JS module) | **Download/mirror job manager** behind `/api/status/downloads` + SSE: real-byte progress (from `@@valark-dl` markers), honest terminal states (`complete`/`failed`/`cancelled`/`deferred`/`queued`), post-job verify hook, no-progress watchdog, persistence to `state/jobs.json`, restart recovery. Pure + unit-testable. Contract in its header; tests in `tests/test-mirror-honesty.sh`. |
| `apt_offline.py` | CLI (python, stdlib) | Offline APT package sets from `data/apt-sets.tsv` for ANY Ubuntu suite+arch, no root: a throwaway APT root (own sources/lists + EMPTY dpkg status) makes `apt-get --print-uris install` emit every dependency; `fetch` sha256-verifies against the signed lists; `index` writes `Packages(.gz)` so the dir is a flat repo (`deb [trusted=yes] file:<dir> ./`). Installs nothing. Exit codes: 0 ok · 1 update/resolve failed or environment broken (no apt-get, unwritable `--dest`; clean message, no traceback; `VALARK_DEBUG=1` prints it) · 2 download failed · 3 incomplete · 64 usage incl. an unreadable `--tsv` (argparse's default 2 is overridden); the most severe wins (64 > 1 > 2 > 3 > 0). Real-archive checklist: [LIBRARIAN.md](../../docs/LIBRARIAN.md#offline-deb-sets-exit-codes-and-a-real-box-check). Tests: `tests/test-server-stack.sh`. |
| `oci_pull.py` | CLI (python, stdlib) | Pulls ONE platform of a container image from a registry (Docker Hub bearer auth, resumable, sha256-verified blobs) into a `docker load`-able tar (Docker `manifest.json` + OCI layout). No Docker/skopeo needed on the mirror host. Used by `tools/cad-agent.sh` for the OpenFOAM image. |
| `git_bundle_mirror.py` | CLI (python, stdlib + git) | `plan` / `mirror` / `verify`: mirrors `data/source-repos.tsv` (+ optional `--top N` most-starred) as single-file, full-history **git bundles** at `<dest>/<owner>/<repo>.bundle` + `.source.json` provenance + `INDEX.txt`. Big repos fetch `--depth=1` then `--deepen` in chunks and keep shallow staging across failures, so a dropped link only repeats one chunk. Branches + tags only. Bundles build in local staging, are `git bundle verify`d, and copy in via a size-checked `.part` rename (network shares can't chmod). A `--refresh-days` refresh is incremental: staging is seeded from the existing bundle, so upstream sends only new objects; a missing/corrupt old bundle, or an incremental fetch that fails its 2 tries, falls back to the full chunked fetch. Upstream refs equal to the bundle's (`ls-remote` vs `bundle list-heads`) skip the rebuild + re-copy (`unchanged`), but only if the archived bundle's size + sha256 still match `.source.json` (also checked by `verify`). Every `git bundle verify` passes `-C <repo>` (it needs one). `--dest`/`--stage` are resolved to absolute paths. `verify` reports bundles without a valid `.source.json` (one strict reader, `read_provenance`: object, int `bytes`, 64-hex `sha256`) as UNVERIFIED (exit 3) and keeps walking; `verify --adopt` writes one after verify + full clone + fsck (it trusts the header's ref names) and sweeps day-old `.adopt-*` scratch. Bundle and sidecar are fsync'd around their renames (`fsync_file`: read-only fd first, read-write fallback); `mirror` sweeps day-old `.bundle.part` leftovers. Tests: `tests/test-git-bundle-mirror.sh` (file:// fixture). |
| `references_mirror.py` | CLI (python, stdlib) | Private archive of cad-agent's reference knowledge base (`plan` dry run + size estimate, `mirror`, `verify`, `latest`): reads cad-agent's published index, keeps git bundles / monolith HTML / PDFs as content-addressed blobs with an append-only `manifest.jsonl` (schema in [decisions.md](../../docs/knowledge/decisions.md)). Orders work with `planner.py`. Post-fetch repo size (`--max-repo-mb`, budget) is the apparent byte sum under `objects/`, never allocated blocks (ZFS/compressed disks read ~0, #176). Used by `tools/cad-agent-references.sh`. |
| `lastbook_mirror.py` | CLI (python, stdlib) | `plan` / `mirror`: the current [Lastbook](https://lastbook.org) release from its live manifests (`manifest-v1.json`, `app-v1.json`, `SHA256SUMS.txt`): budget-sized pack choice (`--pack auto` = largest that fits with the base maps + installers; `every` for servers), maps / address indexes / model / installers, `.part` resume (a 206 must start at the `.part` size; 404/410 fail fast), sha256 before the final rename, verified-file stamps, URL allow-list (fail closed). Default budget (`--share PCT [--cap N]`): headroom above the reserve on the **dest's own filesystem**, and Lastbook may hold PCT% of (headroom + what it holds), so runs don't compound; fetches also stop at the reserve. Prune touches only recorded files (+ stray `.part`s whose section/[version/]name path a current/kept manifest names), drops smaller nested packs after a verified single-pack run (ranked by recorded on-disk bytes; a missing/implausible manifest size never supersedes), never drops a held pack unless this run verified one at least as large (or re-verified the same pack id under a new name with at least half its bytes: a re-release replaces), ranks held packs for `auto` by recorded bytes (a larger unheld pack must be HEAD-confirmed; auto's pick is HEAD-checked even on fresh boxes: a HEAD contradicting the manifest skips that pack as broken and the next confirmed one goes through; a HEAD with no size is unconfirmed: no pack, not even an intermediate one, is downloaded that run and the held pack is kept; either way exit 3; never downloads a pack smaller than the largest held, verified one except a same-id re-release of at least half its size; an exit 3 caused only by such a skip, with everything selected verified, still prunes with the exit-0 guards), HEADs every pack before downloading it (size mismatch = a clear error, no GET), skips nested prune across swapped pack ids, and refuses truncated-looking releases (whole mirror, or maps/addresses/models per section). Exit `0`/`1`/`3`/`64` = ok / failure / incomplete (budget) / usage. Used by `tools/lastbook.sh`. Tests: `tests/test-lastbook.sh` (local HTTP fixture). |
| `release_mirror.py` | CLI (python, stdlib) | `plan` / `fetch`: the developer + security stack from `data/dev-stack.tsv`, the **current release** of each project for every platform. Plan rows are TAB `url, dest, size, digest, volatile`. Kinds: `gh` (latest stable release assets by regex + tag source; a regex that selects no asset is an error; tag-only repos fall back to the newest plain version tag, from `git/matching-refs/tags`), `index` (dir listing; a `(?P<v>)` group keeps only the highest version; SHA256SUMS supplies digests; no match = an error, and so is a Brotli body, which stdlib cannot decode), `gnu` (one compression, xz > gz > bz2 > lz > zst, + `gnu-keyring.gpg`; `VALARK_GNU_BASE` mirrors tried in order, one attempt each but the last; an unreachable mirror is skipped for the rest of the run), `go`, `python` (newest final patch per minor; installers from the newest patch that still ships them), `pypi`, `pypi-top N` (failed projects = exit 1, the rest still planned), `template` (`{v}` from a URL, `gh:owner/repo` whose latest release must be a plain version, `ghtag:owner/repo` for the newest plain version tag, or `=literal`), `snap` (one channel, every arch, sha3-384). The `match` column may contain `\|`. `fetch`: `.part` resume (a 206 must start at the `.part` size; a server ignoring Range restarts), the length is checked against the planned size or the server's Content-Length / Content-Range total, then the digest, before the rename (a digest-verified file gets a `<file>.verified` stamp of digest + size + whole-second mtime, trusted on later runs; `VALARK_REHASH=1` ignores stamps); malformed rows are 64 before any request; a cut-short body keeps its `.part` and resumes; a complete `.part` (or a 416) is verified and kept; **volatile** rows (names that do not change between versions: `=latest` templates, checksum lists, `current/` dirs) with a digest are checked against this run's digest through the stamp; without one they are re-checked with HEAD against a `<file>.source.json` sidecar (HEAD refused = re-download); never writes outside `--dest`. Every request (metadata and download) gets 4 attempts on DNS/connection errors, 5xx and 429. Exit `0`/`1`/`2`/`64` = ok / an entry unresolved or nothing resolved / a download failed / usage (most severe wins). Tests: `tests/test-release-mirror.sh` (local HTTP fixture). |
| `tool-scan.js` | required (JS module) | Mirrored-tool directory scan that sees through wrapper dirs (`scanToolDir` — the piper-tts "Not Mirrored" fix), `shallowDirInfo` (models), and `verifyToolMirror` (per-platform state + `.dist` archive integrity). Zero-dep. |
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
