#!/bin/bash
# Val Ark - Mirror Mail (maddy SMTP/IMAP server + alps webmail)
#
# Local community email that NEVER relays to the internet. Two Go single-binaries:
#   - maddy  (foxcpp/maddy)        : SMTP + IMAP + submission in one static binary
#   - alps   (~migadu/alps, srht)  : webmail over IMAP/SMTP, single Go binary
#
# This script ONLY mirrors into the tools tree. It installs nothing system-wide.
# maddy ships prebuilt linux-arm64 + linux-x86_64 (musl static); mac/Windows get
# build-from-source hints. alps is source-only (Go) and is mirrored as a tarball
# for an offline `go build`.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="mail"
# maddy: prebuilt static binaries on GitHub releases
MADDY_REPO="foxcpp/maddy"
MADDY_PINNED="v0.9.5"
# alps: SourceHut, source-only Go module (no GitHub mirror, no releases)
ALPS_GIT="https://git.sr.ht/~migadu/alps"
ALPS_REF="master"
ALPS_TARBALL="https://git.sr.ht/~migadu/alps/archive/master.tar.gz"

download_mail() {
    log "Downloading ${TOOL_NAME} (maddy + alps)..."

    local repo="$MADDY_REPO"
    local tag
    tag=$(github_latest_tag "$repo" "$MADDY_PINNED")
    # strip leading v for the asset filename (assets are maddy-0.9.5-...)
    local ver="${tag#v}"

    # ---- maddy: linux-arm64 (aarch64 static musl) -------------------------
    local url
    url=$(github_asset_url "$repo" "$tag" "aarch64-linux-musl.tar.zst$")
    [ -z "$url" ] && url="https://github.com/${repo}/releases/download/${tag}/maddy-${ver}-aarch64-linux-musl.tar.zst"
    # Archive entries are prefixed "./maddy-<ver>-<arch>/..." so strip 2 leading
    # path components to land the maddy binary directly in <platform>/mail/.
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/mail" "maddy linux-arm64" 2
    else
        log_error "Could not resolve maddy linux-arm64 asset"
    fi

    # ---- maddy: linux-x86_64 (static musl) --------------------------------
    url=$(github_asset_url "$repo" "$tag" "x86_64-linux-musl.tar.zst$")
    [ -z "$url" ] && url="https://github.com/${repo}/releases/download/${tag}/maddy-${ver}-x86_64-linux-musl.tar.zst"
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/mail" "maddy linux-x86_64" 2
    else
        log_error "Could not resolve maddy linux-x86_64 asset"
    fi

    # ---- maddy: source tarball (offline build for mac / windows / other) --
    url=$(github_asset_url "$repo" "$tag" "src.tar.zst$")
    [ -z "$url" ] && url="https://github.com/${repo}/releases/download/${tag}/maddy-${ver}-src.tar.zst"
    if [ -n "$url" ]; then
        download_file "$url" "${TOOLS_DIR}/sources/maddy-${ver}-src.tar.zst" "maddy source tarball"
    fi

    # ---- macOS: no upstream binary -> build hint --------------------------
    write_install_hint "${TOOLS_DIR}/macos-arm64/mail" "mail" \
"Mail (maddy) for macOS
========================

maddy ships no prebuilt macOS binary. It is a single Go binary; build it offline:

  1. Install Go (1.21+):  brew install go    (or mirror the Go toolchain)
  2. Build from the mirrored source tarball:
       tar --use-compress-program=unzstd -xf maddy-${ver}-src.tar.zst
       cd maddy-${ver}
       ./build.sh            # produces ./maddy
  3. Copy ./maddy here, then run it via scripts/services/mail.sh.

Source mirror: ${TOOLS_DIR}/sources/maddy-${ver}-src.tar.zst
Upstream:      https://github.com/${repo}/releases/tag/${tag}

The webmail front-end (alps) is mirrored under tools/sources/alps/."

    # ---- Windows: no upstream binary -> build hint ------------------------
    write_install_hint "${TOOLS_DIR}/windows-x64/mail" "mail" \
"Mail (maddy) for Windows
==========================

maddy targets Unix; there is no official Windows binary. Recommended paths:

  1. WSL2 (recommended): run the linux-x86_64 maddy binary inside WSL.
  2. Build from source with Go for Windows:
       tar --use-compress-program=unzstd -xf maddy-${ver}-src.tar.zst
       cd maddy-${ver}
       go build ./cmd/maddy

Source mirror: ${TOOLS_DIR}/sources/maddy-${ver}-src.tar.zst
Upstream:      https://github.com/${repo}/releases/tag/${tag}"

    # ---- alps webmail: source-only (Go) -> mirror as tarball + clone ------
    # alps has no GitHub repo and no release binaries; it lives on SourceHut.
    # Try a shallow git clone (creates an offline tarball too); fall back to the
    # SourceHut archive snapshot if git/clone is unavailable.
    local alps_dest="${TOOLS_DIR}/sources/alps"
    if command -v git >/dev/null 2>&1; then
        clone_repo "$ALPS_GIT" "$ALPS_REF" "$alps_dest" "alps webmail source"
    fi
    if [ ! -d "${alps_dest}/.git" ] && [ ! -f "${alps_dest}.tar.gz" ]; then
        log_info "git clone unavailable/failed; mirroring alps via SourceHut archive snapshot"
        download_file "$ALPS_TARBALL" "${alps_dest}.tar.gz" "alps webmail source (srht snapshot)"
    fi

    write_install_hint "${TOOLS_DIR}/sources" "alps" \
"alps webmail (single Go binary)
=================================

alps is the framed web UI for Val Ark Mail. It is source-only (SourceHut), so it
is mirrored here for an offline build:

  Source dir:     ${alps_dest}/          (git clone, if available)
  Source tarball: ${alps_dest}.tar.gz

Build offline (needs Go 1.21+; the Go toolchain can be mirrored separately):
  tar -xzf alps.tar.gz && cd alps   # or use the cloned dir
  go build -o alps ./cmd/alps
  cp alps ${TOOLS_DIR}/<platform>/mail/alps

scripts/services/mail.sh auto-detects a built ./alps next to the maddy binary and
serves it on a fixed localhost port for the /app/mail/ reverse proxy.

Upstream: https://git.sr.ht/~migadu/alps"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_mail
