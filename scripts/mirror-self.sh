#!/bin/bash
###############################################################################
# Val Ark - self-mirror: package the CODEBASE for offline self-replication.
#
# Val Ark is an offline service. A power cut or a dead internet link must not stop
# a neighbour from standing up their own node — so a trusted Ark host keeps a
# clonable copy of Val Ark's own source ON ITS DATA DISK and serves it over the
# LAN. This script produces those artifacts under <data>/sources/val-ark/:
#
#   val-ark.bundle          full-history git bundle  -> `git clone` it offline
#   val-ark-latest.tar.gz   working-tree tarball     -> extract + setup, no git
#   VERSION                 ref/commit/timestamp metadata (served + shown in UI)
#
# When ONLINE and a git remote exists it fetches first, so the mirror tracks the
# latest release; when offline it just repackages the local tree. Idempotent:
# a no-op when the mirror already matches HEAD (pass --force to rebuild anyway).
#
# The web server serves these at /sources/val-ark/* and hands out a host-aware
# bootstrap script at /bootstrap.sh — see scripts/server.js + bootstrap.sh.
###############################################################################
set -o pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "${_LIB}/valark-env.sh"

REPO_ROOT="${PROJECT_ROOT}"
DEST="${SOURCES_DIR}/val-ark"
BUNDLE="${DEST}/val-ark.bundle"
TARBALL="${DEST}/val-ark-latest.tar.gz"
META="${DEST}/VERSION"

log() { echo "[self-mirror] $*"; }

force=""; [ "${1:-}" = "--force" ] && force=1
mkdir -p "$DEST" 2>/dev/null || { log "cannot create $DEST"; exit 1; }

cd "$REPO_ROOT" || { log "repo root missing: $REPO_ROOT"; exit 1; }
is_git=0; git rev-parse --git-dir >/dev/null 2>&1 && is_git=1

# When online + a remote is configured, refresh so the mirror tracks upstream.
# Never fatal — offline is the normal, supported case.
if [ "$is_git" = 1 ] && [ "${VALARK_SELF_MIRROR_FETCH:-1}" = 1 ] && git remote get-url origin >/dev/null 2>&1; then
    if timeout 60 git fetch --tags --quiet origin >/dev/null 2>&1; then log "fetched origin (online)"; else log "offline / fetch skipped — mirroring the local tree"; fi
fi

commit="nogit"; ref="local"
if [ "$is_git" = 1 ]; then
    commit="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
    ref="$(git describe --tags --always 2>/dev/null || echo "$commit")"
fi

# Cheap idempotency: skip if the mirror already matches HEAD.
if [ -z "$force" ] && [ -f "$META" ] && [ -f "$BUNDLE" ] && [ -f "$TARBALL" ] \
   && grep -qx "commit=$commit" "$META" 2>/dev/null; then
    log "mirror already current ($ref); nothing to do"
    exit 0
fi

log "packaging Val Ark ${ref} (${commit}) -> ${DEST}"
if [ "$is_git" = 1 ]; then
    tmpb="${BUNDLE}.tmp.$$"
    if git bundle create "$tmpb" --all >/dev/null 2>&1; then
        mv -f "$tmpb" "$BUNDLE"; log "wrote git bundle ($(du -h "$BUNDLE" 2>/dev/null | cut -f1))"
    else rm -f "$tmpb"; log "WARN: git bundle failed"; fi
    tmpt="${TARBALL}.tmp.$$"
    if git archive --format=tar.gz --prefix="val-ark/" -o "$tmpt" HEAD >/dev/null 2>&1; then
        mv -f "$tmpt" "$TARBALL"; log "wrote source tarball ($(du -h "$TARBALL" 2>/dev/null | cut -f1))"
    else rm -f "$tmpt"; log "WARN: git archive failed"; fi
else
    # Not a git checkout — tar the tree, excluding data/state and node_modules.
    tmpt="${TARBALL}.tmp.$$"
    if tar --exclude='./.git' --exclude='./tools' --exclude='./content' --exclude='./models' \
           --exclude='./sources' --exclude='./assets' --exclude='./installers' \
           --exclude='node_modules' --exclude='*.log' \
           -czf "$tmpt" -C "$REPO_ROOT" . 2>/dev/null; then
        mv -f "$tmpt" "$TARBALL"; log "wrote source tarball (non-git)"
    else rm -f "$tmpt"; log "WARN: tar failed"; fi
fi

# Copy the bootstrap script alongside so it can be fetched directly too.
[ -f "${REPO_ROOT}/bootstrap.sh" ] && cp -f "${REPO_ROOT}/bootstrap.sh" "${DEST}/bootstrap.sh" 2>/dev/null

# Mirror a Node runtime per platform we have one for, so a bootstrapped node can
# run the web server with NO internet: setup.sh fetches node-<platform>.tar.gz
# from the Ark before ever reaching nodejs.org. This is what makes the offline
# self-replication actually offline (the code alone is useless without a runtime).
for nd in "${TOOLS_DIR}"/*/node; do
    [ -e "$nd/bin/node" ] || continue
    plat="$(basename "$(dirname "$nd")")"          # linux-arm64 / linux-x86_64 / ...
    out="${DEST}/node-${plat}.tar.gz"
    # Skip if the tarball is already newer than the runtime (avoids re-taring 100MB+
    # every loop cycle; can't run a cross-arch node to version-check it).
    [ -f "$out" ] && [ "$out" -nt "$nd/bin/node" ] && continue
    tmp="${out}.tmp.$$"
    if tar -czhf "$tmp" -C "$nd" . 2>/dev/null; then      # -h: follow the tools symlink
        mv -f "$tmp" "$out"
        log "mirrored node runtime: ${plat} ($(du -h "$out" 2>/dev/null | cut -f1))"
    else rm -f "$tmp"; fi
done

{
    echo "ref=$ref"
    echo "commit=$commit"
    echo "generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bundle=$(basename "$BUNDLE")"
    echo "tarball=$(basename "$TARBALL")"
} > "$META"

# Checksums for the served artifacts. Computed ONCE here (mirror time), not on
# every /api/packages request — the web server reads these back cheaply so the
# manifest can expose a sha256 without ever hashing multi-GB files on a hot path.
# Basenames only (relative), so the file is public-repo safe. Best-effort.
# nullglob + an existence filter so a non-matching node-*.tar.gz glob can't make
# sha256sum fail and discard the (good) bundle/tarball hashes.
if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$DEST" || exit 0
        shopt -s nullglob
        real=()
        for f in val-ark.bundle val-ark-latest.tar.gz node-*.tar.gz; do
            [ -f "$f" ] && real+=("$f")
        done
        if [ "${#real[@]}" -gt 0 ] && sha256sum "${real[@]}" > SHA256SUMS.tmp 2>/dev/null; then
            mv -f SHA256SUMS.tmp SHA256SUMS
        else
            rm -f SHA256SUMS.tmp
        fi
    ) 2>/dev/null || true
fi

log "self-mirror ready: ${ref} (clone: git clone <ark>/sources/val-ark/val-ark.bundle)"
