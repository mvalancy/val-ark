#!/bin/bash
###############################################################################
# Val Ark — content moderation SWEEP (roadmap Phase 7).
#
# The self-heal loop's ENFORCEMENT point. Endpoints + settings screen content on
# request; this screens content already STORED on the box (community uploads) with
# the fail-closed core (moderation.sh) and QUARANTINES anything flagged into a review
# queue. Without it, the Safety card's "screening" claim would be hollow.
#
# FAIL-CLOSED: a file the classifier can't clear (block / hold / error / unparseable)
# is quarantined, never left served. File-based stores only (paste files, mail, upload
# dirs); NodeBB's Redis post store is a documented follow-up. Idempotent: a screened
# file (path+size+mtime) is recorded and skipped next sweep. Bounded per run so a huge
# store can't wedge the loop. Tests inject a stub classifier via VALARK_MODERATION_CMD.
###############################################################################
set -o pipefail
_MS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./valark-env.sh
. "${_MS_DIR}/valark-env.sh" 2>/dev/null || true
MOD="${_MS_DIR}/moderation.sh"
COMMISSION="${_MS_DIR}/commission.js"
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"

MOD_STATE="${STATE_DIR}/moderation"
SCREENED="${MOD_STATE}/screened.tsv"       # path \t size \t mtime \t decision  (dedupe marker)
QUARANTINE="${MOD_STATE}/quarantine"       # flagged originals, preserved for admin review
QUEUE="${MOD_STATE}/queue.jsonl"           # review feed (one JSON line per held item)
MAX_FILES="${VALARK_MODERATION_SWEEP_MAX:-200}"     # bound files screened per sweep

log(){ printf '%s\n' "$*"; }
_json(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
_now(){ date +%s 2>/dev/null || echo 0; }

# Read the FAIL-CLOSED moderation settings (enabled + action) via commission.js. If node
# is unavailable, DEFAULT to enabled + quarantine (screen anyway — fail toward safety).
mod_settings() {
    local json=""
    [ -n "$NODE" ] && [ -f "$COMMISSION" ] && json=$("$NODE" "$COMMISSION" moderation 2>/dev/null)
    MOD_ENABLED=1; MOD_ACTION=quarantine
    case "$json" in *'"enabled":false'*) MOD_ENABLED=0 ;; esac
    case "$json" in
        *'"action":"block"'*) MOD_ACTION=block ;;
        *'"action":"flag"'*)  MOD_ACTION=flag ;;
        *)                     MOD_ACTION=quarantine ;;
    esac
}

# Which dirs to screen. Explicit VALARK_MODERATION_DIRS (colon-separated) wins; else
# discover file-based community stores that exist (missing services are simply skipped).
sweep_dirs() {
    if [ -n "${VALARK_MODERATION_DIRS:-}" ]; then
        printf '%s\n' "${VALARK_MODERATION_DIRS//:/$'\n'}"
        return
    fi
    local d
    for d in \
        "${DATA_ROOT}/val-ark/state/services/paste/data" \
        "${DATA_ROOT}/val-ark/state/services/mail/messages" \
        "${VAL_ARK_UPLOADS:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
    done
}

already_screened() {  # path size mtime -> 0 if already recorded (the tab after path avoids prefix collisions)
    [ -f "$SCREENED" ] || return 1
    grep -qF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$SCREENED"
}

sweep() {
    mod_settings
    mkdir -p "$MOD_STATE" "$QUARANTINE"
    if [ "$MOD_ENABLED" != 1 ]; then log "moderation disabled — sweep skipped"; return 0; fi

    local scanned=0 flagged=0 f sz mt out rc dec reason rel qdst
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        # -print0/-d '' so filenames with spaces or newlines can't split the loop. find
        # does not descend symlinked dirs (no -L) and reports symlinked files as type l,
        # so a planted symlink can't redirect the sweep outside the store.
        while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            case "$f" in "$MOD_STATE"/*) continue ;; esac       # never screen our own state tree
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            mt=$(stat -c%Y "$f" 2>/dev/null || echo 0)
            already_screened "$f" "$sz" "$mt" && continue
            [ "$scanned" -ge "$MAX_FILES" ] && break 2
            scanned=$((scanned + 1))
            # Screen it (type decided by magic bytes INSIDE moderation.sh, never here).
            out=$(bash "$MOD" check "$f" 2>/dev/null); rc=$?
            dec=$(printf '%s' "$out" | sed -n 's/.*"decision":"\([a-z]*\)".*/\1/p' | head -1)
            [ -n "$dec" ] || dec=hold                           # unparseable → fail-closed hold
            if [ "$dec" = allow ]; then
                printf '%s\t%s\t%s\t%s\n' "$f" "$sz" "$mt" allow >> "$SCREENED"
                continue
            fi
            # non-allow (block|hold|skip-treated-as-hold) → apply the admin's action
            flagged=$((flagged + 1))
            reason=$(printf '%s' "$out" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)
            rel=$(printf '%s' "$f" | sed 's#[/ ]#_#g' | tail -c 100)
            qdst="${QUARANTINE}/$(_now)_${scanned}_${rel}"
            if [ "$MOD_ACTION" = flag ]; then
                cp -f "$f" "$qdst" 2>/dev/null                  # leave original served, keep a copy to review
            else
                mv -f "$f" "$qdst" 2>/dev/null                  # block|quarantine: neutralise (remove from store)
            fi
            printf '{"ts":%s,"path":"%s","decision":"%s","reason":"%s","action":"%s","quarantine":"%s"}\n' \
                "$(_now)" "$(_json "$f")" "$dec" "$(_json "$reason")" "$MOD_ACTION" "$(_json "$qdst")" >> "$QUEUE"
            printf '%s\t%s\t%s\t%s\n' "$f" "$sz" "$mt" "$dec" >> "$SCREENED"
        done < <(find "$d" -type f -print0 2>/dev/null)
    done < <(sweep_dirs)

    log "sweep: scanned ${scanned}, quarantined ${flagged}"
    [ "$flagged" -gt 0 ] && return 10 || return 0    # rc 10 = the loop should log a heal event
}

case "${1:-sweep}" in
    sweep)    sweep ;;
    settings) mod_settings; echo "enabled=${MOD_ENABLED} action=${MOD_ACTION}" ;;
    *) echo "usage: mod-sweep.sh [sweep|settings]" >&2; exit 2 ;;
esac
