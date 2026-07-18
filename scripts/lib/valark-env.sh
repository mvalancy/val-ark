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
    # Generic discovery: every mounted volume under /mnt plus common data roots.
    # (No host-specific paths are baked in — set VAL_ARK_DATA in .env to pin one.)
    local m
    for m in /mnt/*; do [ -d "$m" ] && candidates+=("$m"); done
    candidates+=(/data /srv/val-ark /var/lib/val-ark)

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

# SeaweedFS blob store. Defaults under VALARK_HOME, but is intentionally its own
# knob so it can be pinned to a SEPARATE disk (e.g. a second NVMe) to spread I/O
# and use all available capacity. Override VALARK_SEAWEED_DIR in .env to relocate.
SEAWEED_DIR="${VALARK_SEAWEED_DIR:-$VALARK_HOME/seaweedfs}"
SEAWEED_MASTER_PORT="${VALARK_SEAWEED_MASTER_PORT:-9333}"
SEAWEED_VOLUME_PORT="${VALARK_SEAWEED_VOLUME_PORT:-8085}"
SEAWEED_FILER_PORT="${VALARK_SEAWEED_FILER_PORT:-8889}"
SEAWEED_S3_PORT="${VALARK_SEAWEED_S3_PORT:-8333}"

# Reserve: never fill the disk past this. max(RESERVE_PCT% , RESERVE_MIN_GB).
VALARK_RESERVE_PCT="${VALARK_RESERVE_PCT:-2}"
VALARK_RESERVE_MIN_GB="${VALARK_RESERVE_MIN_GB:-50}"

# Footprint cap: the MAX total size Val Ark's own data may occupy (tools + models
# + content + ...). Unlike the reserve (which is about the disk), this bounds Val
# Ark itself, so on a disk it shares with other data (e.g. NAS user shares) it
# can't "take over". Unset = unbounded. VALARK_MODEL_MAX_GB additionally skips any
# single model bigger than N GB, keeping the fill to apps + small models.
VALARK_MAX_GB="${VALARK_MAX_GB:-}"
VALARK_MODEL_MAX_GB="${VALARK_MODEL_MAX_GB:-}"

export PROJECT_ROOT DATA_ROOT VALARK_HOME MODELS_DIR TOOLS_DIR CONTENT_DIR ZIM_DIR \
       SOURCES_DIR ASSETS_DIR INSTALLERS_DIR STATE_DIR LOG_DIR \
       SEAWEED_DIR SEAWEED_MASTER_PORT SEAWEED_VOLUME_PORT SEAWEED_FILER_PORT SEAWEED_S3_PORT \
       VALARK_RESERVE_PCT VALARK_RESERVE_MIN_GB VALARK_MAX_GB VALARK_MODEL_MAX_GB

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

# --- Footprint cap (bound Val Ark's OWN data, so it can't take over a shared disk)
# Bytes currently occupied by Val Ark's own data trees (models + tools + content
# + sources + assets + installers). Follows symlinks to the real dirs.
valark_data_used_bytes() {
    local total=0 d sz
    for d in "$MODELS_DIR" "$TOOLS_DIR" "$CONTENT_DIR" "$SOURCES_DIR" "$ASSETS_DIR" "$INSTALLERS_DIR"; do
        [ -d "$d" ] || continue
        sz=$(du -sbL "$d" 2>/dev/null | cut -f1); total=$(( total + ${sz:-0} ))
    done
    echo "$total"
}
# Per-model size ceiling in bytes (0 = no cap).
valark_model_max_bytes() {
    if [ -n "$VALARK_MODEL_MAX_GB" ]; then echo $(( VALARK_MODEL_MAX_GB * 1073741824 )); else echo 0; fi
}
# How many more bytes Val Ark may still fill: the smaller of (disk headroom) and
# (footprint cap minus current usage). With no cap set, this is just fillable.
valark_budget_bytes() {
    local fill cap used maxb
    fill=$(valark_fillable_bytes)
    if [ -n "$VALARK_MAX_GB" ]; then
        maxb=$(( VALARK_MAX_GB * 1073741824 ))
        used=$(valark_data_used_bytes)
        cap=$(( maxb - used )); [ "$cap" -lt 0 ] && cap=0
        if [ "$cap" -lt "$fill" ]; then echo "$cap"; else echo "$fill"; fi
    else
        echo "$fill"
    fi
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
        valark_data_stamp     # record the data-disk identity (idempotent, one-shot)
    fi
}

# --- Data-disk identity guard (issue #58) -------------------------------------
# When data lives on a SEPARATE disk (DATA_ROOT != PROJECT_ROOT), a late or failed
# mount at boot (fstab `nofail`; a USB/NTFS disk still enumerating past the @reboot
# sleep) would let the loop's unconditional mkdir rebuild the state/content tree on
# the ROOT filesystem under the empty mountpoint — the librarian would then fill the
# root disk, and once the real disk mounts it shadows that tree (stale pins/manifest)
# while a second cron tick opens a DIFFERENT loop.lock inode and runs concurrently.
#
# Guard: stamp a random id INTO the data tree (a sentinel ON the disk) and record the
# SAME id in a repo-local, git-ignored marker on the ROOT fs (so it survives the disk
# being unmounted). The mount is "present" only when the on-disk sentinel exists AND
# its id matches the recorded marker — i.e. the intended disk is really mounted here.
# A box never commissioned onto a separate disk has no marker, so single-disk / dev
# layouts (DATA_ROOT == PROJECT_ROOT, or /data on the root fs) are never affected.
VALARK_DATA_SENTINEL="${VALARK_DATA_SENTINEL:-${VALARK_HOME}/.valark-data}"   # ON the data disk
VALARK_DATA_MARKER="${VALARK_DATA_MARKER:-${PROJECT_ROOT}/.valark-data-id}"   # on the root fs (gitignored)
export VALARK_DATA_SENTINEL VALARK_DATA_MARKER

# Stamp the sentinel + marker. One-shot: only at first commissioning (when no marker
# exists yet and the tree was just created on a writable, mounted disk). Deliberately
# never re-writes the sentinel afterwards — doing so from an unmounted cycle would put
# a matching sentinel on the ROOT fs and defeat the guard.
valark_data_stamp() {
    [ "$DATA_ROOT" = "$PROJECT_ROOT" ] && return 0
    [ -s "$VALARK_DATA_MARKER" ] && return 0
    local id
    id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || id="$(date +%s)-$$"
    printf '%s\n' "$id" > "$VALARK_DATA_SENTINEL" 2>/dev/null || true
    printf '%s\n' "$id" > "$VALARK_DATA_MARKER"   2>/dev/null || true
}

# 0 = the intended data disk is mounted here (safe to build/fill);
# 1 = commissioned onto a separate disk that is NOT currently mounted (skip the cycle).
valark_data_mounted() {
    # No marker → never commissioned onto a separate disk (single-disk / dev / genuine
    # first run): allow, so commissioning can create + stamp the tree.
    [ -s "$VALARK_DATA_MARKER" ] || return 0
    # Commissioned. If autodetect fell back to the repo, the disk is simply gone.
    [ "$DATA_ROOT" = "$PROJECT_ROOT" ] && return 1
    # The on-disk sentinel must be present and carry the recorded id (right disk here).
    [ -s "$VALARK_DATA_SENTINEL" ] || return 1
    [ "$(cat "$VALARK_DATA_MARKER" 2>/dev/null)" = "$(cat "$VALARK_DATA_SENTINEL" 2>/dev/null)" ]
}

# --- Robust reachability check (used by link-repair / tests) ------------------
# Returns 0 if reachable. Retries with backoff; treats curl 000 / HTTP 429 / 403
# / 408 / 5xx as TRANSIENT (rate-limit), only a stable 4xx (404/410) means dead.
# Echoes the final HTTP code on stdout.
valark_url_ok() {
    local url="$1" status="" attempt
    for attempt in 1 2 3 4; do
        status=$(curl -sS -o /dev/null -w "%{http_code}" -IL --connect-timeout 10 --max-time 25 \
                 -A "val-ark-linkcheck/1.0" "$url" 2>/dev/null)
        case "$status" in
            200|206|301|302|307|308) echo "$status"; return 0 ;;
            000|403|408|425|429|500|502|503|504) sleep $((attempt * 3)) ;;
            *) # try a 1-byte ranged GET before declaring dead (some hosts dislike HEAD)
               status=$(curl -sS -o /dev/null -w "%{http_code}" -L -r 0-0 --connect-timeout 10 --max-time 25 \
                        -A "val-ark-linkcheck/1.0" "$url" 2>/dev/null)
               case "$status" in 200|206|301|302|307|308) echo "$status"; return 0 ;; esac
               break ;;
        esac
    done
    echo "${status:-000}"; return 1
}

# --- Ensure the data disk is writable (self-healing) --------------------------
# The data disk may be NTFS that Windows left "unclean" (mounts read-only), or a
# mount that reverted after a reboot. Best-effort remount to rw (needs paswordless
# sudo). Preserves any NFS export. Safe no-op when already writable.
valark_ensure_writable() {
    # Probe the Val Ark tree when it exists — the data root itself may be a
    # root-owned mount (NAS appliances pre-create user-owned subvolumes beneath
    # it), which is fine: Val Ark only ever writes inside its own tree.
    local dir="$DATA_ROOT"
    [ -d "$VALARK_HOME" ] && dir="$VALARK_HOME"
    local probe="${dir}/.valark_w_$$"
    if ( : > "$probe" ) 2>/dev/null; then rm -f "$probe" 2>/dev/null; return 0; fi
    command -v findmnt >/dev/null 2>&1 || return 1
    local src fstype
    src=$(findmnt -no SOURCE --target "$DATA_ROOT" 2>/dev/null)
    fstype=$(findmnt -no FSTYPE --target "$DATA_ROOT" 2>/dev/null)
    [ -n "$src" ] || return 1
    case "$fstype" in
        fuseblk|ntfs|ntfs3)
            # Briefly drop any NFS exports (re-synced from /etc/exports afterwards)
            # so the mount can be released, then remount rw and re-export.
            sudo -n exportfs -ua 2>/dev/null || true
            sudo -n umount "$DATA_ROOT" 2>/dev/null || sudo -n umount -l "$DATA_ROOT" 2>/dev/null || true
            sudo -n ntfsfix -d "$src" 2>/dev/null || true
            sudo -n ntfs-3g -o rw,remove_hiberfile,force,uid="$(id -u)",gid="$(id -g)",big_writes,nosuid,nodev,allow_other "$src" "$DATA_ROOT" 2>/dev/null || true
            sudo -n exportfs -ra 2>/dev/null || true
            ;;
        *)
            sudo -n mount -o remount,rw "$DATA_ROOT" 2>/dev/null || true
            ;;
    esac
    ( : > "$probe" ) 2>/dev/null && { rm -f "$probe" 2>/dev/null; return 0; }
    return 1
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
