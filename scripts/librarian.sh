#!/bin/bash
###############################################################################
# Val Ark - Librarian: scalable, diversity-first disk-fill + curation engine.
#
# Fills a disk of ANY size from live catalogs (Kiwix ZIM, models, OS/router
# installers) in priority order:
#     diversity  ->  small valuable  ->  fill remaining  ->  evict-for-better
# Rugged: resumable downloads, retries, size verification, atomic rename,
# never aborts on a single failure, idempotent (skips what's already present).
#
# Commands:
#   status                 disk + coverage summary
#   plan   [--budget B]    dry-run: print the ordered plan
#   fill   [opts]          execute the plan, bounded (see opts)
#   maintain               refresh catalog + verify + top-up + report (loop core)
#   verify                 integrity-check managed files (size); requeue bad
#   evict  --need BYTES    free space (lowest value/byte, protect diversity)
#
# fill/maintain opts: --max-bytes B  --max-items N  --time SECONDS  --budget B
###############################################################################
set -o pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "${_LIB}/valark-env.sh"
. "${_LIB}/catalog.sh"

PLANNER="${_LIB}/planner.py"
MANIFEST="${STATE_DIR}/manifest.tsv"
FAILED="${STATE_DIR}/failed.tsv"
HEALTH="${STATE_DIR}/health.json"
STOP_FLAG="${STATE_DIR}/STOP"
TMPDIR_VA="${STATE_DIR}/tmp"
LL_LOG="${LOG_DIR}/librarian_$(date +%Y%m%d).log"

RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
if [ -t 1 ] && [ "${FORCE_COLOR:-}" != "0" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
fi
log()  { local m="[$(date '+%H:%M:%S')] $*"; echo -e "$m"; mkdir -p "$LOG_DIR" 2>/dev/null; echo "$m" >> "$LL_LOG" 2>/dev/null; }
ok()   { log "${GREEN}OK${NC} $*"; }
warn() { log "${YELLOW}WARN${NC} $*"; }
err()  { log "${RED}ERR${NC} $*"; }
human(){ valark_human "${1:-0}"; }

ensure_state() { mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMPDIR_VA" "$ZIM_DIR" "$INSTALLERS_DIR" "$MODELS_DIR" 2>/dev/null || true; }

# --- manifest --------------------------------------------------------------
# id  bucket  category  dest  bytes  value  source  epoch
manifest_add() {
    local id="$1" bucket="$2" cat="$3" dest="$4" bytes="$5" value="$6" source="$7"
    ensure_state
    grep -qF "$(printf '%s\t' "$id")" "$MANIFEST" 2>/dev/null && \
        grep -v -F "$(printf '%s\t' "$id")" "$MANIFEST" > "${MANIFEST}.tmp" 2>/dev/null && mv "${MANIFEST}.tmp" "$MANIFEST"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$bucket" "$cat" "$dest" "$bytes" "$value" "$source" "$(date +%s)" >> "$MANIFEST"
}

# --- download one candidate (rugged; never aborts) -------------------------
CURL_OPTS=(-fL --connect-timeout 30 --retry 5 --retry-delay 15 --retry-all-errors
           -A "val-ark-librarian/1.0" --progress-bar)

download_one() {
    local id="$1" bucket="$2" cat="$3" value="$4" bytes="$5" source="$6" url="$7" dest="$8" extra="$9"
    case "$source" in
        zim|url)
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            local tmp="${dest}.part" sz got=1 final=""
            # Prefer aria2 (8-connection ~3x faster on per-connection-throttled
            # mirrors like download.kiwix.org); fall back to single-stream curl
            # if aria2 is absent or fails. Both resume an existing *.part.
            if command -v aria2c >/dev/null 2>&1; then
                aria2c -x8 -s8 -j1 --max-tries=5 --retry-wait=15 --continue=true \
                    --auto-file-renaming=false --allow-overwrite=true --content-disposition=false \
                    --console-log-level=warn --summary-interval=0 \
                    -d "$(dirname "$dest")" -o "$(basename "$tmp")" "$url" >>"$LL_LOG" 2>&1 && got=0
            fi
            # aria2 may land the bytes in EITHER the .part or the final name
            # (it can honour the server filename) — pick whichever has the data.
            if [ "$got" -eq 0 ]; then
                if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null||echo 0)" -ge "$(stat -c%s "$tmp" 2>/dev/null||echo 0)" ]; then final="$dest"
                elif [ -f "$tmp" ]; then final="$tmp"; fi
            fi
            if [ -z "$final" ]; then
                curl "${CURL_OPTS[@]}" -C - -o "$tmp" "$url" 2>>"$LL_LOG" && [ -f "$tmp" ] && final="$tmp"
            fi
            if [ -n "$final" ]; then
                sz=$(stat -c%s "$final" 2>/dev/null || echo 0)
                if [ "$bytes" -gt 0 ] && [ "$sz" -lt $(( bytes * 90 / 100 )) ]; then
                    warn "size short for $id ($sz < $bytes)"; rm -f "$tmp" "${tmp}.aria2" 2>/dev/null; return 1
                fi
                [ "$final" != "$dest" ] && mv -f "$final" "$dest"
                rm -f "$tmp" "${dest}.aria2" "${tmp}.aria2" 2>/dev/null   # never leave stubs/control files
                manifest_add "$id" "$bucket" "$cat" "$dest" "$sz" "$value" "$source" && return 0
            fi
            rm -f "$tmp" "${tmp}.aria2" 2>/dev/null   # clean the stub on definitive failure
            return 1 ;;
        hf-file)
            mkdir -p "$dest" 2>/dev/null
            local fn; fn="$(basename "$url")"
            local tmp="${dest}/${fn}.part"
            if curl "${CURL_OPTS[@]}" -C - -o "$tmp" "$url" 2>>"$LL_LOG"; then
                local sz; sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
                [ "$sz" -gt 0 ] || { rm -f "$tmp"; return 1; }
                mv -f "$tmp" "${dest}/${fn}" && manifest_add "$id" "$bucket" "$cat" "${dest}/${fn}" "$sz" "$value" "$source" && return 0
            fi
            return 1 ;;
        hf-repo)
            local hf="${HF_CLI:-$HOME/.local/bin/hf}"; [ -x "$hf" ] || hf="$(command -v hf 2>/dev/null)"
            [ -n "$hf" ] || { warn "hf CLI missing; skip $id"; return 1; }
            mkdir -p "$dest" 2>/dev/null
            if "$hf" download "$url" --local-dir "$dest" --include "$extra" >>"$LL_LOG" 2>&1; then
                local sz; sz=$(du -sb "$dest" 2>/dev/null | cut -f1); manifest_add "$id" "$bucket" "$cat" "$dest" "${sz:-0}" "$value" "$source" && return 0
            fi
            return 1 ;;
    esac
    return 1
}

# --- build the plan (candidates | planner) ---------------------------------
gen_candidates() { catalog_all_candidates; }

build_plan() {
    local budget="$1"
    gen_candidates | python3 "$PLANNER" --budget "$budget" \
        --model-max-bytes "$(valark_model_max_bytes)" 2> "${TMPDIR_VA}/plan.summary"
}

# --- commands --------------------------------------------------------------
cmd_status() {
    ensure_state
    echo -e "${CYAN}Val Ark Librarian — status${NC}"
    valark_env_summary
    echo ""
    local managed=0; [ -f "$MANIFEST" ] && managed=$(wc -l < "$MANIFEST")
    echo "  managed items: $managed   (manifest: $MANIFEST)"
    echo "  fillable now : $(human "$(valark_fillable_bytes)")"
    if [ -n "$VALARK_MAX_GB" ]; then
        echo "  footprint cap: ${VALARK_MAX_GB}GB total (used $(human "$(valark_data_used_bytes)"), budget left $(human "$(valark_budget_bytes)"))"
    fi
    [ -n "$VALARK_MODEL_MAX_GB" ] && echo "  model cap    : skip any single model > ${VALARK_MODEL_MAX_GB}GB (apps + small models)"
    echo ""
    echo "  ZIM content: $(find "$ZIM_DIR" -maxdepth 1 -name '*.zim' 2>/dev/null | wc -l) files, $(du -sh "$ZIM_DIR" 2>/dev/null | cut -f1)"
    echo "  installers : $(find "$INSTALLERS_DIR" -type f 2>/dev/null | wc -l) files, $(du -sh "$INSTALLERS_DIR" 2>/dev/null | cut -f1)"
    echo "  models     : $(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
    if [ -f "$MANIFEST" ]; then
        echo ""
        echo "  coverage by category (managed):"
        cut -f3 "$MANIFEST" | sort | uniq -c | sort -rn | head -40 | sed 's/^/    /'
    fi
}

cmd_plan() {
    local budget="${1:-$(valark_budget_bytes)}"
    ensure_state
    catalog_refresh_zim >/dev/null 2>&1 || warn "ZIM catalog refresh failed; using cache if any"
    build_plan "$budget" > "${TMPDIR_VA}/plan.tsv"
    cat "${TMPDIR_VA}/plan.summary" >&2
    echo -e "${CYAN}Planned downloads (id | category | size | phase):${NC}"
    awk -F'\t' '{printf "  %-44s %-22s %12s  p%s\n", $1, $3, $5, $10}' "${TMPDIR_VA}/plan.tsv" \
        | awk '{ if (NR<=60) print } END { if (NR>60) print "  ... (" NR-60 " more)" }'
    local n; n=$(wc -l < "${TMPDIR_VA}/plan.tsv")
    local tot; tot=$(awk -F'\t' '{s+=$5} END{print s+0}' "${TMPDIR_VA}/plan.tsv")
    echo "  ── ${n} items, $(human "$tot") total ──"
}

cmd_fill() {
    local max_bytes=0 max_items=0 time_budget=0 budget=""
    while [ $# -gt 0 ]; do case "$1" in
        --max-bytes) max_bytes="$2"; shift 2;;
        --max-items) max_items="$2"; shift 2;;
        --time) time_budget="$2"; shift 2;;
        --budget) budget="$2"; shift 2;;
        *) shift;; esac; done
    ensure_state
    [ -f "$STOP_FLAG" ] && { warn "STOP flag present ($STOP_FLAG); not filling"; return 0; }
    # Single-filler lock: a background fill and the loop's fill must never race
    # on the same files. Non-blocking — if another fill holds it, this is a no-op.
    exec 9>"${STATE_DIR}/fill.lock"
    if ! flock -n 9; then warn "another fill is already running; skipping"; return 0; fi
    [ -z "$budget" ] && budget="$(valark_budget_bytes)"
    catalog_refresh_zim >/dev/null 2>&1 || warn "ZIM catalog refresh failed; using cache"
    build_plan "$budget" > "${TMPDIR_VA}/plan.tsv"
    cat "${TMPDIR_VA}/plan.summary" >&2
    local start; start=$(date +%s)
    local n_ok=0 n_fail=0 bytes_done=0 items=0
    log "fill: starting (budget $(human "$budget"), $(wc -l < "${TMPDIR_VA}/plan.tsv") planned)"
    while IFS=$'\t' read -r id bucket cat value bytes source url dest extra phase; do
        [ -f "$STOP_FLAG" ] && { warn "STOP flag; halting fill"; break; }
        [ "$max_items" -gt 0 ] && [ "$items" -ge "$max_items" ] && break
        [ "$max_bytes" -gt 0 ] && [ "$bytes_done" -ge "$max_bytes" ] && break
        if [ "$time_budget" -gt 0 ]; then
            local elapsed=$(( $(date +%s) - start )); [ "$elapsed" -ge "$time_budget" ] && { log "time budget reached"; break; }
        fi
        # Always re-check real headroom (respects concurrent growth / reserve).
        local fillable; fillable=$(valark_fillable_bytes)
        if [ "$bytes" -gt 0 ] && [ "$fillable" -lt $(( bytes + 1073741824 )) ]; then
            warn "low headroom ($(human "$fillable")); stopping before $id"; break
        fi
        items=$(( items + 1 ))
        log "[$items] ${id} (${cat}, $(human "$bytes"), p${phase})"
        if download_one "$id" "$bucket" "$cat" "$value" "$bytes" "$source" "$url" "$dest" "$extra"; then
            ok "$id"; n_ok=$(( n_ok + 1 )); bytes_done=$(( bytes_done + bytes ))
        else
            err "$id (logged for retry)"; n_fail=$(( n_fail + 1 ))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$bucket" "$cat" "$value" "$bytes" "$source" "$url" "$dest" "$extra" >> "$FAILED"
        fi
    done < "${TMPDIR_VA}/plan.tsv"
    log "fill done: ${GREEN}${n_ok} ok${NC}, ${RED}${n_fail} failed${NC}, $(human "$bytes_done") added, $(human "$(valark_fillable_bytes)") fillable left"
    echo "$n_ok"
}

cmd_verify() {
    ensure_state
    [ -f "$MANIFEST" ] || { echo "no manifest"; return 0; }
    local bad=0 good=0
    while IFS=$'\t' read -r id bucket cat dest bytes value source epoch; do
        if [ -f "$dest" ]; then
            local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
            if [ "$bytes" -gt 0 ] && [ "$sz" -lt $(( bytes * 90 / 100 )) ]; then
                warn "corrupt/short: $id ($sz < $bytes) -> removing for re-download"; rm -f "$dest"; bad=$(( bad+1 ))
            else good=$(( good+1 )); fi
        elif [ -d "$dest" ]; then good=$(( good+1 ))
        else warn "missing: $id ($dest)"; bad=$(( bad+1 )); fi
    done < "$MANIFEST"
    log "verify: ${good} ok, ${bad} bad/missing"
    echo "$bad"
}

cmd_evict() {
    local need=0; while [ $# -gt 0 ]; do case "$1" in --need) need="$2"; shift 2;; *) shift;; esac; done
    [ "$need" -gt 0 ] || { echo "usage: evict --need BYTES"; return 1; }
    gen_candidates | python3 "$PLANNER" --budget 1 --evict-need "$need" --manifest "$MANIFEST" | \
    while IFS=$'\t' read -r id cat dest bytes value; do
        warn "evict $id ($cat, $(human "$bytes"), value $value) -> $dest"
        rm -f "$dest" 2>/dev/null && grep -v -F "$(printf '%s\t' "$id")" "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    done
}

cmd_maintain() {
    ensure_state
    log "maintain: begin"
    catalog_refresh_zim --force >/dev/null 2>&1 && ok "catalog refreshed" || warn "catalog refresh failed (using cache)"
    cmd_verify >/dev/null
    # Top-up fill bounded by time so the loop stays responsive.
    local added; added=$(cmd_fill --time "${MAINTAIN_FILL_SECONDS:-1800}" 2>>"$LL_LOG" | tail -1)
    # health report
    local fillable avail; fillable=$(valark_fillable_bytes); avail=$(valark_avail_bytes)
    cat > "$HEALTH" <<EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "data_root": "$DATA_ROOT",
  "avail_bytes": ${avail:-0},
  "fillable_bytes": ${fillable:-0},
  "managed_items": $( [ -f "$MANIFEST" ] && wc -l < "$MANIFEST" || echo 0 ),
  "zim_files": $(find "$ZIM_DIR" -maxdepth 1 -name '*.zim' 2>/dev/null | wc -l),
  "installer_files": $(find "$INSTALLERS_DIR" -type f 2>/dev/null | wc -l),
  "failed_queued": $( [ -f "$FAILED" ] && wc -l < "$FAILED" || echo 0 )
}
EOF
    ok "maintain: done (health -> $HEALTH)"
}

case "${1:-status}" in
    status)   cmd_status ;;
    plan)     shift; [ "$1" = "--budget" ] && cmd_plan "$2" || cmd_plan ;;
    fill)     shift; cmd_fill "$@" ;;
    verify)   cmd_verify ;;
    evict)    shift; cmd_evict "$@" ;;
    maintain) cmd_maintain ;;
    refresh)  catalog_refresh_zim --force && ok "catalog cached: $ZIM_CACHE ($(wc -l < "$ZIM_CACHE") entries)" ;;
    *) echo "usage: librarian.sh {status|plan|fill|verify|evict|maintain|refresh}"; exit 1 ;;
esac
