#!/bin/bash
# Val Ark - Download Gitea (self-hosted git forge, #346)
#
# Gitea is one static Go binary: git hosting, issues, pull requests, wikis, and
# built-in package registries (npm, PyPI, Cargo, Go, Debian, OCI, generic, ...).
# Upstream publishes a plain executable per platform on dl.gitea.com (the same
# files as the GitHub release), each with a `<file>.sha256` beside it.
#
# Layout (one runnable file per platform, no archive to unpack):
#   tools/linux-x86_64/gitea/gitea      <- gitea-<v>-linux-amd64
#   tools/linux-arm64/gitea/gitea       <- gitea-<v>-linux-arm64
#   tools/macos-arm64/gitea/gitea       <- gitea-<v>-darwin-arm64
#   tools/windows-x64/gitea/gitea.exe   <- gitea-<v>-windows-amd64.exe
#
# Every file is sha256-checked against upstream's .sha256; a mismatch deletes the
# file and logs an error. Version-gated, so the weekly loop refresh replaces an old
# release in place. Mirrors only: nothing is installed on the Val Ark box.
#
# Knobs (tests and air-gapped re-mirrors): GITEA_DL_BASE (default
# https://dl.gitea.com/gitea) and GITEA_VERSION (skip the version.json lookup).
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOOL_NAME="gitea"
PINNED_VERSION="28.4.0"
GITEA_DL_BASE="${GITEA_DL_BASE:-https://dl.gitea.com/gitea}"

# Latest stable version from dl.gitea.com/gitea/version.json ({"latest":{"version":"X"}}),
# falling back to the pin offline. Prints a bare version (no leading v).
gitea_latest_version() {
    if [ -n "${GITEA_VERSION:-}" ]; then echo "${GITEA_VERSION#v}"; return 0; fi
    local v
    v=$(curl -fsS --connect-timeout 5 --max-time 15 "${GITEA_DL_BASE}/version.json" 2>/dev/null \
        | tr -d '\n ' | sed -n 's/.*"latest":{"version":"\([0-9][0-9A-Za-z.+-]*\)".*/\1/p')
    if [ -z "$v" ]; then
        log_warn "Could not resolve the latest Gitea version, using: ${PINNED_VERSION}" >&2
        v="$PINNED_VERSION"
    fi
    echo "$v"
}

# gitea_asset PLATFORM VERSION -> upstream file name for that Val Ark platform dir.
gitea_asset() {
    case "$1" in
        linux-x86_64) echo "gitea-$2-linux-amd64" ;;
        linux-arm64)  echo "gitea-$2-linux-arm64" ;;
        macos-arm64)  echo "gitea-$2-darwin-arm64" ;;
        windows-x64)  echo "gitea-$2-windows-amd64.exe" ;;
        *) return 1 ;;
    esac
}

# gitea_sha256_ok FILE SUMFILE -> true when FILE's sha256 matches the first field of SUMFILE.
gitea_sha256_ok() {
    local want got
    want=$(awk 'NR==1{print tolower($1)}' "$2" 2>/dev/null)
    printf '%s' "$want" | grep -qE '^[0-9a-f]{64}$' || return 1
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$1" | awk '{print $1}')
    else got=$(shasum -a 256 "$1" | awk '{print $1}'); fi
    [ "$got" = "$want" ]
}

# gitea_mirror_platform PLATFORM VERSION -> 0 when the platform's binary is present and verified.
gitea_mirror_platform() {
    local plat="$1" ver="$2" asset bin dest url sums
    asset=$(gitea_asset "$plat" "$ver") || { log_error "gitea: unknown platform ${plat}"; return 1; }
    dest="${TOOLS_DIR}/${plat}/gitea"
    bin="gitea"; [ "$plat" = windows-x64 ] && bin="gitea.exe"
    url="${GITEA_DL_BASE}/${ver}/${asset}"
    sums="${dest}/${bin}.sha256"

    version_gate "$dest" "$ver"
    ensure_dir "$dest"
    # download_file logs its own error (with the URL and the reason) when a fetch fails.
    download_file "${url}.sha256" "$sums" "gitea ${plat} checksum" || return 1
    download_file "$url" "${dest}/${bin}" "gitea ${plat}" || return 1
    if ! gitea_sha256_ok "${dest}/${bin}" "$sums"; then
        log_error "gitea ${plat}: sha256 mismatch against ${url}.sha256 - removed the file"
        rm -f "${dest:?}/${bin}" "$sums"
        return 1
    fi
    chmod +x "${dest}/${bin}" 2>/dev/null || true
    write_install_hint "$dest" "gitea" "Gitea ${ver} (${plat})
============================

One self-contained binary: git hosting, issues, pull requests, wikis and
package registries (npm, PyPI, Cargo, Go, Debian, OCI, generic, ...).
Checksum: ${bin}.sha256 (from upstream, verified when mirrored).

Run it on your own machine (no internet needed):
  ./${bin} --version
  ./${bin} web            # first run opens the install page on http://localhost:3000/
On Linux/macOS: chmod +x ${bin} first. On macOS, clear the quarantine flag if
Gatekeeper refuses it: xattr -d com.apple.quarantine ${bin}

On the Val Ark host, run it as a LAN service instead (SQLite, registration off,
proxied at /app/gitea/):  scripts/services/gitea.sh start | status | stop

Docs: https://docs.gitea.com  -  Source: https://github.com/go-gitea/gitea (MIT)"
    version_stamp "$dest" "$ver"
    return 0
}

download_gitea() {
    log "Downloading ${TOOL_NAME}..."
    local ver plat bad=0
    ver=$(gitea_latest_version)
    for plat in linux-x86_64 linux-arm64 macos-arm64 windows-x64; do
        gitea_mirror_platform "$plat" "$ver" || bad=$((bad + 1))
    done
    if [ "$bad" -eq 0 ]; then
        log_success "${TOOL_NAME} ${ver} download complete."
    else
        log_warn "${TOOL_NAME} ${ver}: ${bad} of 4 platforms missing (see errors above)."
    fi
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_gitea
