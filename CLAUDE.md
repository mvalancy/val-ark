# Val Ark - Development Guide

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
    platforms: { jetson: 'prebuilt', ubuntu: 'prebuilt', mac: 'prebuilt', windows: 'prebuilt' },
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

### Categories

| ID | Label | Examples |
|----|-------|---------|
| `ai-inference` | AI Inference | llama.cpp, whisper.cpp, piper |
| `ai-platform` | AI Platform | Ollama, n8n, ComfyUI |
| `creative` | Creative | Blender, GIMP, Godot |
| `media` | Media | FFmpeg, VLC, yt-dlp |
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

Add the tool ID to the `TOOL_IDS` array (maintains alphabetical order within category groups).

---

## Shared Helpers (`_common.sh`)

| Function | Purpose |
|----------|---------|
| `github_latest_tag REPO FALLBACK` | Get latest release tag (falls back to pinned) |
| `github_asset_url REPO TAG PATTERN` | Find asset URL matching grep pattern |
| `download_file URL DEST` | Download single file with retry |
| `download_and_extract URL DEST LABEL STRIP` | Download + extract archive |
| `clone_repo URL REF DEST` | Shallow git clone |
| `write_install_hint DIR TOOL INSTRUCTIONS` | Write INSTALL.txt for non-binary tools |
| `ensure_dir PATH` | mkdir -p with safety |

## Terminology

- **Mirror**: We host/cache a copy of the binary for users to download
- **Not Mirrored**: We haven't cached this tool yet
- **Install Hint**: Instructions for the USER to install the tool on THEIR machine
- Scripts do NOT install anything on the Val Ark server

## Platform Directories

| Directory | Architecture | Examples |
|-----------|-------------|----------|
| `linux-arm64` | ARM64 | NVIDIA Jetson, Raspberry Pi |
| `linux-x86_64` | x86_64 | Ubuntu, Debian, Fedora |
| `macos-arm64` | Apple Silicon | M1/M2/M3/M4 |
| `windows-x64` | x86_64 | Windows 10/11 |

## Running Tests

```bash
export PATH="$HOME/.local/node/bin:$PATH"
cd tests/screenshots && npx playwright test
```

All 211+ tests must pass before committing.
