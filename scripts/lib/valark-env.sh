#!/bin/bash
###############################################################################
# Val Ark - Environment / Data-Root Resolution
#
# Single source of truth for WHERE Val Ark keeps its data. Source this from any
# script:  source "$(dirname "$0")/lib/valark-env.sh"   (path-depth aware)
#
# Design goals:
#   - Scale to any disk: free space is measured live from the data disk.
#   - Reuse existing data: models already live at <DATA_ROOT>/models.
#   - Don't collide with the user's other files: Val Ark's own data lives under
#     <DATA_ROOT>/val-ark/ (tools, content, sources, assets, installers, state)
#     EXCEPT models, which stay at <DATA_ROOT>/models (where ~/models points).
#   - Keep legacy scripts working: repo-relative dirs are symlinked to the disk.
#
# Resolution order for DATA_ROOT:
#   1. $VAL_ARK_DATA environment variable
#   2. VAL_ARK_DATA= line in the config file (.valark.conf)
#   3. Autodetect: a large, writable mount that already has a models/ dir,
#      else the largest writable candidate mount.
#   4. Fallback: the repo root (single-disk / dev mode).
###############################################################################

# Idempotent source guard
[ -n "$_VALARK_ENV_LOADED" ] && return 0
_VALARK_ENV_LOADED=1

# --- Locate ourselves and the repo --------------------------------------------
_VALARK_ENV_SELF="${BASH_SOURCE[0]}"
VALARK_LIB_DIR="$(cd "$(dirname "$_VALARK_ENV_SELF")" && pwd)"
VALARK_SCRIPTS_DIR="$(dirname "$VALARK_LIB_DIR")"
PROJECT_ROOT="$(dirname "$VALARK_SCRIPTS_DIR")"

# --- Local config (gitignored) -------------------------------------------------
# Machine-specific settings live in a local, git-ignored file so nothing
# host-specific (like an absolute data path) is ever committed. Simple shell
# KEY=VALUE lines, e.g.:   VAL_ARK_DATA=/mnt/storage-10tb
# Precedence: $VAL_ARK_CONFIG  >  repo .env  >  repo .valark.conf  >  XDG config.
# See .env.example for the documented options.
VALARK_CONFIG="${VAL_ARK_CONFIG:-}"
if [ -z "$VALARK_CONFIG" ]; then
    for _cand in "${PROJECT_ROOT}/.env" "${PROJECT_ROOT}/.valark.conf" \
                 "${XDG_CONFIG_HOME:-$HOME/.config}/val-ark/config"; do
        if [ -f "$_cand" ]; then VALARK_CONFIG="$_cand"; break; fi
    done
fi
# shellcheck disable=SC1090
[ -n "$VALARK_CONFIG" ] && [ -f "$VALARK_CONFIG" ] && set -a && . "$VALARK_CONFIG" && set +a

# --- Resolve DATA_ROOT ---------------------------------------------------------
_valark_writable() { [ -d "$1" ] && [ -w "$1" ]; }

_valark_autodetect_data_root() {
    # Candidate large mounts, ordered by preference. Honour VAL_ARK_DATA_CANDIDATES
    # (colon-separated) for extra/override locations on other machines.
    local extra="${VAL_ARK_DATA_CANDIDATES:-}"
    local candidates=()
    local IFS=':'
    for c in $extra; do [ -n "$c" ] && candidates+=("$c"); done
    IFS=' '
    candidates+=(/mnt/storage-10tb /mnt/storage /mnt/data /data /srv/val-ark /var/lib/val-ark)

    # First pass: a writable candidate that already holds a models/ dir (reuse data).
    local c
    for c in "${candidates[@]}"; do
        if _valark_writable "$c" && [ -d "$c/models" ]; then echo "$c"; return 0; fi
    done
    # Second pass: pick the writable candidate with the most available space.
    local best="" best_avail=0 avail
    for c in "${candidates[@]}"; do
        if _valark_writable "$c"; then
            avail=$(df -P -B1 "$c" 2>/dev/null | awk 'NR==2{print $4}')
            [ -z "$avail" ] && avail=0
            if [ "$avail" -gt "$best_avail" ]; then best_avail="$avail"; best="$c"; fi
        fi
    done
    [ -n "$best" ] && { echo "$best"; return 0; }
    return 1
}

if [ -z "$VAL_ARK_DATA" ]; then
    VAL_ARK_DATA="$(_valark_autodetect_data_root)" || VAL_ARK_DATA="$PROJECT_ROOT"
fi
DATA_ROOT="$VAL_ARK_DATA"

# --- Derived directories -------------------------------------------------------
# Models reuse the established <DATA_ROOT>/models location (ties into ~/models).
# Everything else Val Ark owns lives under <DATA_ROOT>/val-ark to avoid clobbering
# unrelated user data that may share the disk.
if [ "$DATA_ROOT" = "$PROJECT_ROOT" ]; then
    # Single-disk / dev mode: keep the classic repo-relative layout.
    VALARK_HOME="$PROJECT_ROOT"
    MODELS_DIR="${VALARK_MODELS_DIR:-$PROJECT_ROOT/models}"
else
    VALARK_HOME="${VALARK_HOME:-$DATA_ROOT/val-ark}"
    MODELS_DIR="${VALARK_MODELS_DIR:-$DATA_ROOT/models}"
fi

TOOLS_DIR="${VALARK_TOOLS_DIR:-$VALARK_HOME/tools}"
CONTENT_DIR="${VALARK_CONTENT_DIR:-$VALARK_HOME/content}"
ZIM_DIR="${VALARK_ZIM_DIR:-$CONTENT_DIR/zim}"
SOURCES_DIR="${VALARK_SOURCES_DIR:-$VALARK_HOME/sources}"
ASSETS_DIR="${VALARK_ASSETS_DIR:-$VALARK_HOME/assets}"
INSTALLERS_DIR="${VALARK_INSTALLERS_DIR:-$VALARK_HOME/installers}"
STATE_DIR="${VALARK_STATE_DIR:-$VALARK_HOME/state}"
LOG_DIR="${VALARK_LOG_DIR:-$STATE_DIR/logs}"

# Reserve: never fill the disk past this. max(RESERVE_PCT% , RESERVE_MIN_GB).
VALARK_RESERVE_PCT="${VALARK_RESERVE_PCT:-2}"
VALARK_RESERVE_MIN_GB="${VALARK_RESERVE_MIN_GB:-50}"

export PROJECT_ROOT DATA_ROOT VALARK_HOME MODELS_DIR TOOLS_DIR CONTENT_DIR ZIM_DIR \
       SOURCES_DIR ASSETS_DIR INSTALLERS_DIR STATE_DIR LOG_DIR \
       VALARK_RESERVE_PCT VALARK_RESERVE_MIN_GB

# --- Disk math (bytes) ---------------------------------------------------------
# NOTE: print the raw df field (already an integer string). Do NOT use awk
# arithmetic (`$4+0`) or printf %d here: mawk formats large numbers in
# scientific notation and overflows %d at 2^31, corrupting 64-bit byte counts.
valark_avail_bytes()  { df -P -B1 "${1:-$DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $4}'; }
valark_total_bytes()  { df -P -B1 "${1:-$DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $2}'; }
valark_used_bytes()   { df -P -B1 "${1:-$DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $3}'; }
valark_reserve_bytes() {
    local total pct_b min_b
    total=$(valark_total_bytes)
    pct_b=$(( total * VALARK_RESERVE_PCT / 100 ))
    min_b=$(( VALARK_RESERVE_MIN_GB * 1073741824 ))
    if [ "$pct_b" -gt "$min_b" ]; then echo "$pct_b"; else echo "$min_b"; fi
}
# Bytes we may still consume before hitting the reserve (never negative).
valark_fillable_bytes() {
    local avail reserve f
    avail=$(valark_avail_bytes); reserve=$(valark_reserve_bytes)
    f=$(( avail - reserve ))
    [ "$f" -lt 0 ] && f=0
    echo "$f"
}
valark_human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# --- Layout creation (idempotent) ---------------------------------------------
# Creates the data directories and links repo-relative dirs to the data disk so
# legacy scripts (server.js, start.sh, _common.sh) transparently use the disk.
valark_link() {
    # valark_link <repo-relative-name> <target-dir>
    local name="$1" target="$2" link="$PROJECT_ROOT/$1"
    mkdir -p "$target" 2>/dev/null || true
    # If the repo path is already the correct symlink, done.
    if [ -L "$link" ] && [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$target" 2>/dev/null)" ]; then
        return 0
    fi
    # If a real (non-symlink) dir exists with content, migrate it onto the disk.
    if [ -d "$link" ] && [ ! -L "$link" ]; then
        if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
            cp -an "$link"/. "$target"/ 2>/dev/null || true
        fi
        rm -rf "$link" 2>/dev/null || true
    fi
    [ -L "$link" ] && rm -f "$link" 2>/dev/null || true
    ln -s "$target" "$link" 2>/dev/null || true
}

valark_ensure_layout() {
    mkdir -p "$MODELS_DIR" "$TOOLS_DIR" "$CONTENT_DIR" "$ZIM_DIR" "$SOURCES_DIR" \
             "$ASSETS_DIR" "$INSTALLERS_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
    # Only create repo symlinks when data lives on a different root than the repo.
    if [ "$DATA_ROOT" != "$PROJECT_ROOT" ]; then
        valark_link models    "$MODELS_DIR"
        valark_link tools     "$TOOLS_DIR"
        valark_link content   "$CONTENT_DIR"
        valark_link sources   "$SOURCES_DIR"
        valark_link assets    "$ASSETS_DIR"
        valark_link installers "$INSTALLERS_DIR"
    fi
}

# --- Pretty path summary (for status / debugging) -----------------------------
valark_env_summary() {
    cat <<EOF
Val Ark data layout:
  DATA_ROOT     $DATA_ROOT  (avail $(valark_human "$(valark_avail_bytes)") / total $(valark_human "$(valark_total_bytes)"), reserve $(valark_human "$(valark_reserve_bytes)"))
  models        $MODELS_DIR
  tools         $TOOLS_DIR
  content/zim   $ZIM_DIR
  sources       $SOURCES_DIR
  assets        $ASSETS_DIR
  installers    $INSTALLERS_DIR
  state         $STATE_DIR
EOF
}
