# Val Ark - Development Guide

Val Ark is an online-optional, local-first mirror of dev/AI tools, AI models, and
offline content (ZIM via Kiwix), with a zero-dependency web UI. It fills a disk of
**any** size and keeps itself healthy 24/7.

## Project Context

| Concern | Where | Notes |
|---------|-------|-------|
| Data root | `scripts/lib/valark-env.sh` | Resolves `VAL_ARK_DATA` from a git-ignored `.env` (see [`.env.example`](.env.example)) or autodetects the largest mount; falls back to the repo. Models at `<root>/models`; Val Ark trees at `<root>/val-ark/{tools,content,sources,assets,installers,state}`, symlinked back into the repo so per-tool scripts stay path-agnostic. Optional footprint caps: `VALARK_MAX_GB` / `VALARK_MODEL_MAX_GB`. |
| Librarian engine | `scripts/librarian.sh` + `scripts/lib/{catalog.sh,kiwix_catalog.py,planner.py}` + `data/{installers.tsv,models-extra.tsv}` | Fills any-size disk from **live** catalogs (Kiwix OPDS fetched live — never stale) by priority: diversity -> small-valuable -> fill-remaining -> evict-for-better. Downloads use aria2 multi-connection (curl fallback); resumable, retried, size-verified, atomic, single flock. Commands: `status\|plan\|fill\|verify\|evict\|maintain\|refresh\|catalog\|request\|pin\|unpin\|pins`. `request <content\|model\|tool> <id>` pins + fetches ONE item now, auto-evicting the lowest-priority UNPINNED content to fit `VALARK_MAX_GB` (pins are never evicted, re-filled by the loop). `catalog` lists not-yet-downloaded items (the web browse feed). See [`docs/LIBRARIAN.md`](docs/LIBRARIAN.md). |
| Self-healing loop | `scripts/loop.sh` + `scripts/verify.sh` | `loop.sh once` repairs symlinks, ensures the web server is up (plus the `VALARK_WEB_PUBLIC_PORT` NAT redirect and enabled community services), refreshes the live catalog, link-checks + repairs, integrity-verifies, top-up fills, weekly-refreshes mirrored tools to latest upstream (`VALARK_TOOL_REFRESH_DAYS`, default 7), and runs functional verification. `loop.sh install [minutes]` registers a flock-guarded cron (default 30) plus an `@reboot` resume. `verify.sh` confirms apps actually run (tools, kiwix serving a real ZIM, a tiny LLM, the web API) and checks remote fleet nodes over SSH. |
| Web server | `scripts/server.js` | Zero-dep Node: serves the web UI + JSON API + SSE + `/api/archive/` downloads (HTTP Range, resumable), auto-launches `kiwix-serve` for any complete `.zim` in `content/zim`. Port via `VALARK_WEB_PORT` (`.env`, default 3000); extra listen ports via `VALARK_WEB_EXTRA_PORTS`. **LAN+tailnet one-click triggers** (validated allowlist + footprint-cap eviction + per-IP rate limit): `GET /api/catalog/{content,models}` (browse feed), `POST /api/request` (per-item ZIM/model/tool), `POST /api/service/start` (community service). **Self-replication**: `/bootstrap.sh` hands out a host-aware offline installer; the source bundle/tarball are served from `/sources/val-ark/` (mirrored by `scripts/mirror-self.sh`). |
| Community services | `scripts/services/{chat,mail,forum,paste}.sh` | Offline LAN comms (ngIRCd+The Lounge, maddy+alps, NodeBB+Redis, MicroBin), reverse-proxied at `/app/<id>/`, surfaced in the web UI's **Community** hub with live status + one-click Start. Enable via `VALARK_SERVICES` in `.env` (loop keeps them up). Runtime discovery (node/redis) prefers the mirrored `tools/<platform>/…` and rebuilds native modules for the host arch (cross-arch: x86_64 + arm64). See [`docs/COMMUNITY.md`](docs/COMMUNITY.md). |
| Tests | `tests/run-all.sh` + `tests/{lib,services,vm,report}/` | One runner -> a self-contained offline HTML report (`tests/results/report.html`): bash validators + Playwright + community-services e2e + fresh-Ubuntu (22/24/26) setup VMs (multipass). See [`tests/README.md`](tests/README.md). |
| Mesh | (NFS) | The data disk is NFS-exportable so fleet nodes mount **one** shared mirror and run GPU inference on served models over the network; the verify loop checks this. |

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/PLATFORMS.md`](docs/PLATFORMS.md)
for the full picture.

## Adding a New Tool

Every tool integration touches these files. Complete ALL steps before considering the tool "done".

### Checklist

- [ ] `scripts/tools/<name>.sh` -- Download/mirror script
- [ ] `web-ui/index.html` -- TOOLS array entry
- [ ] `web-ui/index.html` -- TOOL_META entry
- [ ] `web-ui/logos/<name>.svg` -- Logo (SVG preferred)
- [ ] `web-ui/screenshots/<name>-1.png` -- At least one screenshot
- [ ] `tests/screenshots/specs/web-ui.spec.ts` -- Add to TOOL_IDS array
- [ ] Run tests: `npx playwright test` (all must pass)
- [ ] Verify URLs: `curl -sI -o /dev/null -w "%{http_code}" <url>` for each platform

---

### 1. Download Script (`scripts/tools/<name>.sh`)

```bash
#!/bin/bash
source "$(dirname "$0")/_common.sh"

TOOL_NAME="<display-name>"
PINNED_VERSION="v1.0.0"

download_<name>() {
    log "Downloading ${TOOL_NAME}..."

    local repo="owner/repo"
    local tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-arm64
    local url
    url=$(github_asset_url "$repo" "$tag" "linux.*arm64.*tar.gz")
    [ -n "$url" ] && download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/<name>" "<name> linux-arm64" 1

    # linux-x86_64
    url=$(github_asset_url "$repo" "$tag" "linux.*amd64.*tar.gz")
    [ -n "$url" ] && download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/<name>" "<name> linux-x86_64" 1

    # macos-arm64
    url=$(github_asset_url "$repo" "$tag" "darwin.*arm64.*tar.gz")
    [ -n "$url" ] && download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/<name>" "<name> macos-arm64" 1

    # windows-x64
    url=$(github_asset_url "$repo" "$tag" "windows.*amd64.*zip")
    [ -n "$url" ] && download_and_extract "$url" "${TOOLS_DIR}/windows-x64/<name>" "<name> windows-x64" 1

    log_success "${TOOL_NAME} download complete."
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_<name>
```

For versioned mirrors that should track upstream, wrap each platform download with
`version_gate "$dest" "$tag"` before and `version_stamp "$dest" "$tag"` after a
successful download (see `scripts/tools/audacity.sh`) so the weekly loop refresh
replaces stale versions without re-downloading current ones.

For tools without portable binaries, use `write_install_hint`:
```bash
write_install_hint "${TOOLS_DIR}/${platform}/<name>" "<name>" "$instructions"
```

### 2. TOOLS Array Entry (`web-ui/index.html`)

Add to the TOOLS array in the appropriate category position:

```javascript
{
    id: '<name>', name: '<Display Name>', category: '<category>', icon: '<X>', iconBg: '#hex', logo: 'logos/<name>.svg', downloadTarget: '<name>',
    desc: '<One-line description>',
    size: '~XX MB',
    platforms: { jetson: 'prebuilt', ubuntu: 'prebuilt', mac: 'prebuilt', windows: 'prebuilt' }, // thor/gb10 inherit jetson; openwrt derived

    downloads: {
        releases: 'https://github.com/owner/repo/releases',
    },
    details: {
        overview: '<2-3 sentence description of what it does and why it matters>',
        features: [
            'Feature 1',
            'Feature 2',
            'Feature 3'
        ],
        screenshots: ['screenshots/<name>-1.png'],
        cli: [
            {cmd: '<command>', desc: '<what it does>'},
        ]
    }
},
```

### Platform Values

The per-tool `platforms` object uses four keys — `jetson` (Linux ARM64), `ubuntu`
(x86_64), `mac` (Apple Silicon), `windows` (x64) — each `'prebuilt'`, `'build'`, or
`'none'`. The web UI **derives** the rest: Jetson Thor and GB10 inherit the `jetson`
(ARM64) status, and OpenWRT routers get the content/sync/infra subset. GPU-accelerated
llama.cpp / whisper.cpp / sd.cpp on ARM64 have no upstream binary and need a CUDA source
build, so those are marked `'build'` for `jetson`.

### Categories

| ID | Label | Examples |
|----|-------|---------|
| `ai-inference` | AI Inference | llama.cpp, whisper.cpp, piper |
| `ai-platform` | AI Platform | Ollama, n8n, ComfyUI |
| `creative` | Creative & Engineering | Blender, GIMP, Godot |
| `media` | Media | FFmpeg, VLC, yt-dlp |
| `community` | Community & Comms | IRC Chat, Mail, Message Boards |
| `infrastructure` | Infrastructure | Syncthing, Kiwix, Redis |
| `dev-tools` | Dev Tools | Helix, VSCodium, btop |

### 3. TOOL_META Entry (`web-ui/index.html`)

Add to the TOOL_META object:

```javascript
'<name>': { maker: '<Company/Author>', website: '<url>', license: '<SPDX>', licenseUrl: '<url>' },
```

### 4. Logo (`web-ui/logos/<name>.svg`)

Create a simple SVG icon (48x48 viewBox). Use geometric shapes representing the tool.

### 5. Screenshot (`web-ui/screenshots/<name>-1.png`)

Download or capture at least one screenshot showing the tool in use. Reference it in the `details.screenshots` array. Standard naming: `<name>-1.png`, `<name>-2.png`.

### 6. Test Integration (`tests/screenshots/specs/web-ui.spec.ts`)

Add the tool ID to the `TOOL_IDS` array (the spec iterates it per tool and asserts the catalog card count matches its length).

---

## Shared Helpers (`_common.sh`)

| Function | Purpose |
|----------|---------|
| `github_latest_tag REPO FALLBACK` | Get latest release tag (falls back to pinned) |
| `github_asset_url REPO TAG PATTERN` | Find asset URL matching grep pattern |
| `download_file URL DEST` | Download single file (retry, `.part` resume, size-verify, atomic rename) |
| `download_and_extract URL DEST LABEL STRIP` | Download + extract archive |
| `version_gate DIR VERSION` | Before a re-mirror: keep DIR if its `.version` marker is current or newer (downgrade-safe), else clear stale artifacts (preserves `.dist/` history) |
| `version_stamp DIR VERSION` | After success: record VERSION in DIR's `.version` marker (never downgrades) |
| `clone_repo URL REF DEST` | Shallow git clone |
| `create_source_tarball SRC_DIR LABEL VERSION` | Pack a checked-out dir into a `.tar.gz` (excludes `.git`) |
| `write_install_hint DIR TOOL INSTRUCTIONS` | Write INSTALL.txt for non-binary tools |
| `ensure_dir PATH` | mkdir -p with safety |

## Terminology

- **Mirror**: We host/cache a copy of the binary for users to download
- **Not Mirrored**: We haven't cached this tool yet
- **Install Hint**: Instructions for the USER to install the tool on THEIR machine
- Scripts do NOT install anything on the Val Ark server

## Platform Directories

One ARM64 tools tree serves every aarch64 target (Jetson Orin / Thor, GB10
Grace-Blackwell, OpenWRT routers).

| Directory | Architecture | Examples |
|-----------|-------------|----------|
| `linux-arm64` | aarch64 | Jetson Orin / Thor, GB10 Grace-Blackwell, OpenWRT routers |
| `linux-x86_64` | x86_64 | Ubuntu, Debian, Fedora |
| `macos-arm64` | Apple Silicon | M1/M2/M3/M4 |
| `windows-x64` | x86_64 | Windows 10/11 |

## Running Tests

The Playwright suite under `tests/screenshots/` (server-api, web-ui, install-icons,
ui-exercise specs) parametrizes over every tool, so the count scales with the catalog (250+).

```bash
export PATH="$HOME/.local/node/bin:$PATH"
cd tests/screenshots && npx playwright test
```

Bash validators live alongside as `tests/test-*.sh` (run via `tests/run-all.sh`).
All tests must pass before committing.
