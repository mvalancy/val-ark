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
# is MOVED out of the store to quarantine, never left served. A file is recorded as
# "screened" (and skipped next sweep) ONLY when it is genuinely resolved — an `allow`,
# or a quarantine move that actually SUCCEEDED. If the move fails the file is left
# unrecorded so the next sweep retries it (it must never be both served AND marked done).
#
# File-based stores only (paste files, mail, upload dirs); NodeBB's Redis post store is
# a documented follow-up. Idempotent via a hash-keyed marker; bounded per run. Tests
# inject a stub classifier via VALARK_MODERATION_CMD.
###############################################################################
set -o pipefail
_MS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./valark-env.sh
. "${_MS_DIR}/valark-env.sh" 2>/dev/null || true
MOD="${_MS_DIR}/moderation.sh"
COMMISSION="${_MS_DIR}/commission.js"
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"

MOD_STATE="${STATE_DIR}/moderation"
SCREENED="${MOD_STATE}/screened.db"        # one line per resolved file: <sha1(path\0size\0mtime)> \t decision
QUARANTINE="${MOD_STATE}/quarantine"       # flagged originals, moved here, preserved for admin review
QUEUE="${MOD_STATE}/queue.jsonl"           # review feed (one JSON line per held item)
MAX_FILES="${VALARK_MODERATION_SWEEP_MAX:-200}"       # bound files screened per sweep
MARKER_CAP="${VALARK_MODERATION_MARKER_CAP:-20000}"   # cap marker lines (keep newest half when exceeded)

log(){ printf '%s\n' "$*"; }
_now(){ date +%s 2>/dev/null || echo 0; }
_rand(){ head -c6 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || echo "$$"; }

# JSON-escape for the queue line: backslash, quote, AND the control chars that would
# otherwise split a JSONL record or inject a forged line (newline/tab/CR in a filename).
_json(){
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# Stable, injection-proof dedupe key: a hash of path+size+mtime+sensitivity. Fixed-width
# hex → no substring/prefix false-matches (grep -qF on a raw tab-joined path could match
# mtime as a prefix, or a path containing a tab/newline could corrupt the marker file).
# Sensitivity is folded in so TIGHTENING policy (e.g. balanced→strict) re-screens files a
# weaker policy previously ALLOWED, instead of leaving them stuck on a stale-policy verdict.
_key(){ printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | sha1sum 2>/dev/null | cut -d' ' -f1; }
already_screened(){ [ -f "$SCREENED" ] && grep -q "^$1" "$SCREENED"; }   # $1 = key (hex, regex-safe)
mark_screened(){ printf '%s\t%s\n' "$1" "$2" >> "$SCREENED"; }           # $1 = key, $2 = decision

# Keep the marker from growing without bound over a 24/7 loop (stale entries for
# deleted/quarantined files accumulate). When it exceeds the cap, keep the newest half.
compact_marker(){
    [ -f "$SCREENED" ] || return 0
    local n; n=$(wc -l < "$SCREENED" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt "$MARKER_CAP" ]; then
        tail -n "$((MARKER_CAP / 2))" "$SCREENED" > "${SCREENED}.tmp" 2>/dev/null && mv -f "${SCREENED}.tmp" "$SCREENED"
    fi
}

# Read the FAIL-CLOSED moderation settings (enabled + sensitivity). If node is unavailable,
# DEFAULT to enabled AND strict — screen anyway, at the tightest policy (fail toward safety).
# 'block'/'quarantine' both MOVE the file; there is no "leave it served while enabled" mode.
# Sensitivity MUST reach the classifier (moderation.sh check --sensitivity): the web endpoint
# already honors cfg.sensitivity, so this enforcement sweep must too — otherwise it silently
# applies a weaker policy than the admin configured (allow-vs-hold divergence on numeric-score
# signals, e.g. a 0.3 risk score is allow at balanced but hold at strict).
mod_settings() {
    local json=""
    [ -n "$NODE" ] && [ -f "$COMMISSION" ] && json=$("$NODE" "$COMMISSION" moderation 2>/dev/null)
    MOD_ENABLED=1
    case "$json" in *'"enabled":false'*) MOD_ENABLED=0 ;; esac
    # Parallel fail-toward-safety default: unreadable node/commission output → strict.
    MOD_SENS=strict
    case "$json" in
        *'"sensitivity":"strict"'*)   MOD_SENS=strict ;;
        *'"sensitivity":"balanced"'*) MOD_SENS=balanced ;;
        *'"sensitivity":"lenient"'*)  MOD_SENS=lenient ;;
    esac
}

# Which dirs to screen. Explicit VALARK_MODERATION_DIRS (colon-separated) wins; otherwise
# ONLY a dedicated PLAIN-FILE uploads area (VAL_ARK_UPLOADS).
#
# We deliberately do NOT sweep the community services' internal stores. MicroBin keeps text
# pastes in SQLite (microbin.db) and maddy keeps mail in an imapsql/bbolt store — the files
# on disk are referenced FROM a database, so moving one to quarantine would CORRUPT the
# store, not screen it (and text pastes/mail bodies aren't standalone files at all). Real
# per-service enforcement needs a PRE-store intercept or a service-native hook (a documented
# follow-up), never a post-store file move. So the sweep screens only plain file trees an
# operator explicitly points it at. See docs/knowledge/decisions.md (Phase 7).
sweep_dirs() {
    if [ -n "${VALARK_MODERATION_DIRS:-}" ]; then
        printf '%s\n' "${VALARK_MODERATION_DIRS//:/$'\n'}"
        return
    fi
    [ -n "${VAL_ARK_UPLOADS:-}" ] && [ -d "${VAL_ARK_UPLOADS}" ] && printf '%s\n' "${VAL_ARK_UPLOADS}"
}

sweep() {
    mod_settings
    mkdir -p "$MOD_STATE" "$QUARANTINE"
    if [ "$MOD_ENABLED" != 1 ]; then log "moderation disabled — sweep skipped"; return 0; fi
    compact_marker

    local scanned=0 flagged=0 errors=0 f sz mt key out dec reason rel qdst
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        # -H: dereference a symlinked store dir given on the command line (else find -P
        # returns nothing for it and the whole store is silently unscreened) but NOT
        # symlinks found during traversal. -print0/-d '' so odd filenames can't split.
        while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            case "$f" in "$MOD_STATE"/*) continue ;; esac       # never screen our own state tree
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            mt=$(stat -c%Y "$f" 2>/dev/null || echo 0)
            key=$(_key "$f" "$sz" "$mt" "$MOD_SENS")
            already_screened "$key" && continue
            [ "$scanned" -ge "$MAX_FILES" ] && break 2
            scanned=$((scanned + 1))
            # Screen it at the ADMIN's configured sensitivity (type decided by magic bytes
            # INSIDE moderation.sh, never here) — not a hardcoded 'balanced' default.
            out=$(bash "$MOD" check "$f" --sensitivity "$MOD_SENS" 2>/dev/null)
            dec=$(printf '%s' "$out" | sed -n 's/.*"decision":"\([a-z]*\)".*/\1/p' | head -1)
            case "$dec" in allow|block|hold|skip) ;; *) dec=hold ;; esac   # unknown/empty → fail-closed hold
            if [ "$dec" = allow ]; then
                mark_screened "$key" allow
                continue
            fi
            # non-allow (block|hold|skip) → MOVE the file out of the store (quarantine).
            reason=$(printf '%s' "$out" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)
            rel=$(printf '%s' "$f" | sed 's#[^A-Za-z0-9._-]#_#g' | tail -c 80)
            qdst="${QUARANTINE}/$(_now)_$(_rand)_${rel}"
            # Refuse to clobber, and only record the file as resolved if the move ACTUALLY
            # succeeded — otherwise it's still served, so leave it UNMARKED to be retried.
            if [ ! -e "$qdst" ] && mv "$f" "$qdst" 2>/dev/null; then
                flagged=$((flagged + 1))
                printf '{"ts":%s,"path":"%s","decision":"%s","reason":"%s","quarantine":"%s"}\n' \
                    "$(_now)" "$(_json "$f")" "$dec" "$(_json "$reason")" "$(_json "$qdst")" >> "$QUEUE"
                mark_screened "$key" "$dec"
            else
                errors=$((errors + 1))
                log "ERROR: could not quarantine $f (still served — will retry next sweep)"
            fi
        done < <(find -H "$d" -type f -print0 2>/dev/null)
    done < <(sweep_dirs)

    log "sweep: scanned ${scanned}, quarantined ${flagged}, errors ${errors}"
    if [ "$errors" -gt 0 ]; then return 11; fi     # hard failure: a flagged file is still served
    [ "$flagged" -gt 0 ] && return 10 || return 0  # rc 10 = quarantined something (loop logs a heal event)
}

case "${1:-sweep}" in
    sweep)    sweep ;;
    settings) mod_settings; echo "enabled=${MOD_ENABLED} sensitivity=${MOD_SENS}" ;;
    *) echo "usage: mod-sweep.sh [sweep|settings]" >&2; exit 2 ;;
esac
