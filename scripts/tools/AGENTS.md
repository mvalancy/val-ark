# scripts/tools/ — the tool-mirroring subsystem

One self-contained `download_<tool>()` script per mirrored app (~50 of them) plus the shared
`_common.sh` helper contract — this is where you add a tool or fix a broken mirror URL/refresh.

↑ [Repo root](../../AGENTS.md) · [Doc map](../../docs/README.md) · [scripts/](../AGENTS.md) · [Adding a New Tool → /CLAUDE.md](../../CLAUDE.md)

## What's here

| File | Purpose |
|------|---------|
| `_common.sh` | Sourced helper contract for every tool script: logging, GitHub release lookup, retrying/size-verified downloads, extract, version gating, source clone, install hints. **Read the function index at its top before touching a tool script.** |
| `README.md` | Short per-tool template + platform matrix (this is only *step 1* of adding a tool). |
| `<tool>.sh` (~50) | One script per tool; each sources `_common.sh`, sets `TOOL_NAME`/`PINNED_VERSION`, defines `download_<tool>()`, and self-runs via `[ "${BASH_SOURCE[0]}" = "$0" ] && download_<tool>`. Outputs land in `${TOOLS_DIR}/<platform>/<tool>/`. |

`scripts/download-tools.sh` discovers these automatically (`list` / `<tool>` / `all` / `validate`);
the weekly `loop.sh` refresh re-mirrors only the **version-gated** ones (see Gotchas).

## Adding a new tool — the checklist lives in /CLAUDE.md

A tool integration is **multi-file** and touches far more than this directory. The **authoritative**
step-by-step is the "Adding a New Tool" checklist in [/CLAUDE.md](../../CLAUDE.md): download script here
+ `web-ui/index.html` `TOOLS` array entry + `TOOL_META` entry + `web-ui/logos/<name>.svg` +
`web-ui/screenshots/<name>-1.png` + `tests/screenshots/specs/web-ui.spec.ts` `TOOL_IDS` + run Playwright
+ curl-verify each platform URL. The `README.md` template here is only the *first* of those steps.

## The five script shapes (pick the closest exemplar)

| Shape | Exemplar | What it does | Uses |
|-------|----------|--------------|------|
| Simple pinned GitHub release | `btop.sh` | Per-platform release binary, pinned version, **no** refresh gating | `github_asset_url` → `download_file` + manual `tar`; `write_install_hint` for macOS |
| Live-tag, refreshable | `audacity.sh` | Tracks latest upstream tag; the weekly loop replaces stale copies in place | `github_latest_tag` + `version_gate`/`version_stamp` (per-platform AppImage/DMG/EXE via `download_file`) |
| Multi-binary bundle | `dev-cli.sh` | Several independent CLIs (fd/ripgrep/bat/fzf/jq/lazygit) co-located under one `<platform>/dev-cli/` | `download_and_extract` per binary, own pinned version each |
| Source clone (GPU / no prebuilt) | `whisper-cpp.sh` | Shallow-clones the tagged source to build on the target (CUDA/GPU); Windows gets a prebuilt zip | `clone_repo` (→ auto `create_source_tarball`); `download_and_extract` for Windows |
| Community-service source mirror | `chat.sh` | Mirrors **source** (not a binary) for a bundled service (ngIRCd + The Lounge) with a build hint | `download_and_extract` + `clone_repo` + `write_install_hint` |

> Note: `download_and_extract` is the archive path (dev-cli, whisper Windows, chat); `btop.sh` and
> `audacity.sh` hand-roll `download_file` + manual extract / direct AppImage download instead.

## `_common.sh` — the helper contract

Grep for the function you need in the header index at the top of `_common.sh`. Load-bearing behaviours:

- `download_file URL DEST` — **idempotent + size-verified**: HEADs `Content-Length`, skips when the dest
  already matches, resumes via `${dest}.part` (`curl -C -`, stall detection), re-verifies size, then does an
  **atomic** `mv`. Up to `MAX_RETRIES=5`; never aborts the script. **Re-running any tool script is safe —
  the loop relies on this.**
- `download_and_extract URL DEST LABEL STRIP` — skip-if-already-extracted; extracts tar.gz/xz/zst/zip/AppImage,
  honours `--strip-components`, preserves archive history under `<dest>/.dist/`.
- `version_gate DIR VERSION` / `version_stamp DIR VERSION` — **refreshability is opt-in**: only scripts that
  wrap a download in these two self-update via the weekly loop. `version_gate` keeps a current-or-newer mirror
  (downgrade-safe, preserves `.dist/`), else clears stale artifacts; `version_stamp` records the version.
- `github_latest_tag REPO FALLBACK` / `github_asset_url REPO TAG PATTERN` — release lookup (falls back to the
  pinned version offline).
- `clone_repo URL REF DEST` — shallow clone (then auto `create_source_tarball`); `create_source_tarball
  SRC LABEL VERSION` packs a checkout (excludes `.git`).
- `write_install_hint DIR TOOL INSTRUCTIONS` — for **no-binary / package-managed** platforms, writes an
  `INSTALL.txt` with instructions for the USER (scripts never install anything on the Val Ark box).
- `ensure_dir`, `log`/`log_success`/`log_error`/`log_info`/`log_warn`, `elapsed_since` — utilities.

## Gotchas

- **Refreshability is opt-in.** Of the ~50 tool scripts only the ~17 that call `version_gate`/`version_stamp`
  self-update via the weekly `loop.sh` refresh; the rest are pinned and only re-mirror if their target dir is
  empty. If a tool should track upstream, wrap its download in the version gate.
- **`download_file` is idempotent and the loop depends on it** — do not add hard `--max-time` caps or
  non-resumable rewrites; a re-run must be a no-op when the file is already complete.
- **No-binary platforms use `write_install_hint`**, not a fake download. GPU-accelerated
  llama/whisper/sd on aarch64 have no upstream binary → source build (`clone_repo`), marked `'build'` in the
  web-ui platform matrix.
- **Never hardcode host names / IPs / paths.** Paths resolve through `_common.sh` → `lib/valark-env.sh`
  (`TOOLS_DIR`, `PROJECT_ROOT`); the repo is PUBLIC — placeholders only.

## Related

- [/CLAUDE.md](../../CLAUDE.md) — the authoritative "Adding a New Tool" checklist + platform values
- [`_common.sh`](_common.sh) — the helper contract (function index at its top)
- [scripts/download-tools.sh](../download-tools.sh) — the discovery/orchestration driver
- [web-ui/index.html](../../web-ui/index.html) — `TOOLS` array + `TOOL_META` (the UI side of a tool)
- [docs/LIBRARIAN.md](../../docs/LIBRARIAN.md), [docs/PLATFORMS.md](../../docs/PLATFORMS.md)
