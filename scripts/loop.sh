#!/bin/bash
###############################################################################
# Val Ark - 24/7 self-healing + verification loop.
#
# One cycle (run by `/loop`, cron, or systemd) does, in order:
#   1. ensure the data disk is writable (self-heal NTFS/ro reverts)
#   2. repair the repo<->disk symlink layout
#   3. refresh the live catalog  -> ZIM/content links self-heal (no stale dates)
#   4. link check + repair        -> tool/installer URLs, web-ui assets, symlinks
#   5. integrity verify           -> requeue corrupt/short downloads
#   6. top-up fill (bounded)      -> keep filling per the curation priority model
#   7. functional verification    -> tools run, kiwix serves, fleet reachable
#   8. health report + coordination drop
#
# Designed to be SAFE to run repeatedly and concurrently with a standalone fill
# (the fill flock prevents double-downloading). Never aborts the cycle on a
# single failure.
#
# Usage:
#   loop.sh once          run a single maintenance cycle (cron / /loop)
#   loop.sh run [SECS]    run forever, sleeping SECS between cycles (default 1800)
###############################################################################
set -o pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_DIR}/lib/valark-env.sh"

LIBRARIAN="${_DIR}/librarian.sh"
VERIFY="${_DIR}/verify.sh"
LOOP_LOG="${LOG_DIR}/loop_$(date +%Y%m%d).log"
LINKREPORT="${STATE_DIR}/linkcheck.txt"
COORD_DIR="${STATE_DIR}/coordination"   # fleet-reachable notes drop (toaster etc.)
FILL_SECONDS="${LOOP_FILL_SECONDS:-1800}"

RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
if [ -t 1 ] && [ "${FORCE_COLOR:-}" != "0" ]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'; fi
log(){ local m="[$(date '+%F %T')] $*"; echo -e "$m"; mkdir -p "$LOG_DIR" 2>/dev/null; echo "$m" >> "$LOOP_LOG" 2>/dev/null; }
step(){ log "${CYAN}== $* ==${NC}"; }

# --- step 4: link check + repair -------------------------------------------
link_check_repair() {
    : > "$LINKREPORT"
    local dead=0 checked=0
    # (a) literal URLs hard-coded in tool scripts (catches e.g. moved CDN paths)
    local urls
    urls=$(grep -rhoE 'https?://[^"'"'"' )]+' "${_DIR}/tools/"*.sh 2>/dev/null \
           | grep -ivE 'example\.com|localhost' | sed 's/[).,]*$//' | sort -u)
    # (b) installer catalog URLs (verifiable direct links)
    local inst
    inst=$(awk -F'|' '/^[0-9]/{print $6}' "${PROJECT_ROOT}/data/installers.tsv" 2>/dev/null)
    # (c) a rotating sample of model URLs
    local models
    models=$(awk -F'|' '/^[0-9]/ && $6!="repo"{print "https://huggingface.co/"$4"/resolve/main/"$5}' \
             "${PROJECT_ROOT}/data/models-extra.tsv" 2>/dev/null | head -8)
    local u code
    for u in $urls $inst $models; do
        checked=$((checked+1))
        code=$(valark_url_ok "$u")
        if [ $? -ne 0 ]; then
            echo "DEAD($code) $u" >> "$LINKREPORT"; dead=$((dead+1))
        fi
    done
    # (d) repair the symlink layout + verify web-ui assets exist
    valark_ensure_layout
    local missing_assets=0
    while IFS= read -r asset; do
        [ -f "${PROJECT_ROOT}/web-ui/${asset}" ] || { echo "MISSING-ASSET ${asset}" >> "$LINKREPORT"; missing_assets=$((missing_assets+1)); }
    done < <(grep -ohE "(logos|screenshots)/[A-Za-z0-9._-]+\.(svg|png|jpg|webp)" "${PROJECT_ROOT}/web-ui/index.html" 2>/dev/null | sort -u)
    if [ "$dead" -eq 0 ] && [ "$missing_assets" -eq 0 ]; then
        log "${GREEN}links OK${NC} ($checked URLs checked, symlinks + web-ui assets fine)"
    else
        log "${YELLOW}link issues${NC}: $dead dead URL(s), $missing_assets missing asset(s) -> $LINKREPORT"
    fi
}

# --- step 8: coordination (read fleet notes if any) -------------------------
coordination() {
    mkdir -p "$COORD_DIR" 2>/dev/null
    [ -f "${COORD_DIR}/README.txt" ] || cat > "${COORD_DIR}/README.txt" <<'EOF'
Val Ark fleet coordination drop.
Agents running on other mesh nodes can leave notes here; this path lives on the
shared (exported) data disk and the loop reads any *.md / *.txt notes each
cycle. Drop files like:  <node>-ark-tests.md, <node>-notes.txt
EOF
    local notes; notes=$(find "$COORD_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) ! -name 'README.txt' 2>/dev/null)
    if [ -n "$notes" ]; then
        log "${CYAN}coordination notes present:${NC}"
        echo "$notes" | while read -r n; do log "  note: $n ($(stat -c%y "$n" 2>/dev/null | cut -d. -f1))"; done
    fi
}

loop_once() {
    step "cycle start"
    step "1. ensure data disk writable"
    if valark_ensure_writable; then log "${GREEN}writable${NC}: $DATA_ROOT"; else log "${RED}NOT writable${NC}: $DATA_ROOT (manual remount may be needed)"; fi

    step "2. repair layout"; valark_ensure_layout && log "layout ok"

    step "3. refresh live catalog (heals stale content links)"
    bash "$LIBRARIAN" refresh >/dev/null 2>&1 && log "catalog refreshed" || log "${YELLOW}catalog refresh failed (cache retained)${NC}"

    step "4. link check + repair"; link_check_repair

    step "5. integrity verify"; bash "$LIBRARIAN" verify 2>&1 | tail -1 | sed 's/^/    /'

    step "6. top-up fill (<=${FILL_SECONDS}s; skipped if a fill is already running)"
    FORCE_COLOR=0 bash "$LIBRARIAN" fill --time "$FILL_SECONDS" 2>&1 | tail -1 | sed 's/^/    /'

    step "7. functional verification"; FORCE_COLOR="${FORCE_COLOR:-1}" bash "$VERIFY" all 2>&1 | sed 's/^/    /'

    step "8. report + coordination"; bash "$LIBRARIAN" maintain >/dev/null 2>&1; coordination
    log "${GREEN}cycle complete${NC} | fillable $(valark_human "$(valark_fillable_bytes)") | health: ${STATE_DIR}/health.json"
}

case "${1:-once}" in
    once) loop_once ;;
    run)
        interval="${2:-1800}"
        log "loop: starting continuous run (interval ${interval}s). Touch ${STATE_DIR}/STOP to halt."
        while true; do
            [ -f "${STATE_DIR}/STOP" ] && { log "STOP flag present; exiting loop"; break; }
            loop_once
            log "sleeping ${interval}s"; sleep "$interval"
        done ;;
    *) echo "usage: loop.sh {once|run [interval_seconds]}"; exit 1 ;;
esac
