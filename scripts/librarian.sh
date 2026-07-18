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
#   evict  --need BYTES    free space (lowest value/byte, protect diversity+pins)
#   catalog [kind]         list not-yet-downloaded items (content|model|installer)
#   request KIND ID        pin + fetch ONE item now (auto-evicts to fit the cap)
#   pin/unpin/pins         manage durable user requests (pins [--refill])
#
# fill/maintain opts: --max-bytes B  --max-items N  --time SECONDS  --budget B
#   KIND = content | model | tool   (request / pin)
###############################################################################
set -o pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "${_LIB}/valark-env.sh"
. "${_LIB}/catalog.sh"

PLANNER="${_LIB}/planner.py"
MANIFEST="${STATE_DIR}/manifest.tsv"
PINS="${STATE_DIR}/pins.tsv"
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

# --- pin registry ----------------------------------------------------------
# A pin marks an item the user explicitly requested. Pinned items are (1) never
# evicted (planner --pins) and (2) re-filled by the loop if they go missing, so a
# request is durable across reboots, disk swaps and interrupted downloads.
# Schema (TAB):  kind  id  epoch  note      kind = content|model|tool
pin_has()    { [ -f "$PINS" ] && cut -f2 "$PINS" 2>/dev/null | grep -qxF "$1"; }
pin_add() {
    ensure_state
    pin_has "$2" && return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "${3:-}" >> "$PINS"
}
pin_remove() {
    [ -f "$PINS" ] || return 0
    awk -F'\t' -v id="$1" '$2!=id' "$PINS" > "${PINS}.tmp" 2>/dev/null && mv "${PINS}.tmp" "$PINS"
}

# Is a single resolved candidate (9-col fields) already fully on disk?
# Mirrors planner.marker_present so `request`/`pins --refill` skip complete items.
candidate_present() {
    local source="$3" bytes="$5" dest="$8" url="$7" sz fn
    case "$source" in
        zim|url)
            [ -f "$dest" ] || return 1
            sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
            if [ "$bytes" -gt 0 ]; then [ "$sz" -ge $(( bytes * 97 / 100 )) ]; else [ "$sz" -gt 0 ]; fi ;;
        hf-file)
            fn="${dest}/$(basename "$url")"; [ -f "$fn" ] || return 1
            sz=$(stat -c%s "$fn" 2>/dev/null || echo 0)
            if [ "$bytes" -gt 0 ]; then [ "$sz" -ge $(( bytes * 90 / 100 )) ]; else [ "$sz" -gt 0 ]; fi ;;
        hf-repo)
            [ -d "$dest" ] && [ -n "$(find "$dest" -type f 2>/dev/null | head -1)" ] ;;
        *) return 1 ;;
    esac
}

# A mirrored tool is present when any platform dir carries content.
tool_present() {
    [ -n "$(find "$TOOLS_DIR" -maxdepth 2 -type d -name "$1" 2>/dev/null \
        -exec sh -c '[ -n "$(ls -A "$1" 2>/dev/null)" ] && echo "$1"' _ {} \; | head -1)" ]
}

# --- download one candidate (rugged; never aborts) -------------------------
CURL_OPTS=(-fL --connect-timeout 30 --retry 5 --retry-delay 15 --retry-all-errors
           -A "val-ark-librarian/1.0" --progress-bar)

download_one() {
    local id="$1" bucket="$2" cat="$3" value="$4" bytes="$5" source="$6" url="$7" dest="$8" extra="$9"
    case "$source" in
        zim|url)
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            local tmp="${dest}.part" ctrl="${dest}.part.aria2" sz got=1 final="" have_aria2=0
            # Prefer aria2 (8-connection ~3x faster on per-connection-throttled
            # mirrors like download.kiwix.org); fall back to single-stream curl
            # if aria2 is absent or fails — but NEVER let curl resume an
            # aria2-owned partial (see below).
            command -v aria2c >/dev/null 2>&1 && have_aria2=1
            if [ "$have_aria2" -eq 1 ]; then
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
                # An aria2 .part is SEGMENTED (8 non-contiguous ranges, prealloc
                # holes), not a linear prefix — `curl -C -` on it resumes from the
                # byte-length and "completes" a hole-filled file that passes the
                # size gate: silent corruption. The .aria2 control file is the
                # reliable marker of an aria2-owned partial: while it exists only
                # aria2 may touch the .part.
                if [ -f "$ctrl" ]; then
                    if [ "$have_aria2" -eq 1 ]; then
                        warn "aria2 partial kept for $id (control file present); skipping curl fallback — aria2 resumes next cycle"
                    else
                        warn "aria2 partial for $id but aria2c is no longer installed; discarding it so curl restarts cleanly"
                        rm -f "$tmp" "$ctrl" 2>/dev/null
                        curl "${CURL_OPTS[@]}" -C - -o "$tmp" "$url" 2>>"$LL_LOG" && [ -f "$tmp" ] && final="$tmp"
                    fi
                else
                    curl "${CURL_OPTS[@]}" -C - -o "$tmp" "$url" 2>>"$LL_LOG" && [ -f "$tmp" ] && final="$tmp"
                fi
            fi
            if [ -n "$final" ]; then
                sz=$(stat -c%s "$final" 2>/dev/null || echo 0)
                if [ "$bytes" -gt 0 ] && [ "$sz" -lt $(( bytes * 90 / 100 )) ]; then
                    # The downloader claimed COMPLETION yet the size disagrees with
                    # the catalog — a mismatched/truncated serve, not a partial.
                    # Resuming it would wedge forever (or splice two file versions),
                    # so clear it and retry fresh next cycle.
                    warn "size short for $id ($sz < $bytes)"; rm -f "$tmp" "$ctrl" 2>/dev/null; return 1
                fi
                [ "$final" != "$dest" ] && mv -f "$final" "$dest"
                rm -f "$tmp" "${dest}.aria2" "$ctrl" 2>/dev/null   # never leave stubs/control files
                manifest_add "$id" "$bucket" "$cat" "$dest" "$sz" "$value" "$source" && return 0
            fi
            # Transient failure: KEEP .part + .aria2 so the next cycle RESUMES
            # instead of restarting a many-GB download from byte 0. Stale pairs
            # are GC'd by cmd_verify after VALARK_PARTIAL_MAX_AGE_DAYS.
            [ -f "$tmp" ] && log "download failed for $id; keeping $(human "$(stat -c%s "$tmp" 2>/dev/null || echo 0)") partial + resume state for next cycle"
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
    # GC stale partials: download failures deliberately KEEP .part/.aria2 so big
    # downloads resume across cycles (download_one), so bound them here — a pair
    # untouched for VALARK_PARTIAL_MAX_AGE_DAYS (dead URL, catalog rotation) is
    # deleted rather than stranding gigabytes forever. Active retries refresh
    # mtime every cycle, so anything this old is genuinely abandoned.
    local gc_age="${VALARK_PARTIAL_MAX_AGE_DAYS:-14}" gc=0 f
    while IFS= read -r f; do
        rm -f "$f" 2>/dev/null && gc=$(( gc+1 ))
    done < <(find "$ZIM_DIR" "$INSTALLERS_DIR" "$MODELS_DIR" \
                  \( -name '*.part' -o -name '*.aria2' \) -type f -mtime "+${gc_age}" 2>/dev/null)
    [ "$gc" -gt 0 ] && log "verify: GC'd $gc stale partial/control file(s) older than ${gc_age}d"
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
    # Pinned (user-requested) items are never proposed as victims.
    gen_candidates | python3 "$PLANNER" --budget 1 --evict-need "$need" --manifest "$MANIFEST" --pins "$PINS" | \
    while IFS=$'\t' read -r id cat dest bytes value; do
        warn "evict $id ($cat, $(human "$bytes"), value $value) -> $dest"
        rm -f "$dest" 2>/dev/null && grep -v -F "$(printf '%s\t' "$id")" "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    done
}

# --- catalog: list every not-yet-downloaded candidate (the web browse feed) --
# Emits absent candidates as 10-col plan rows (id bucket cat value bytes source
# url dest extra phase=0), most valuable-per-byte first. Optional kind filter
# (content|model|installer) narrows the bucket. Used by server.js /api/catalog/*.
cmd_catalog() {
    local kind="${1:-all}"
    ensure_state
    local bucket=""
    case "$kind" in
        content) bucket="content" ;;
        model|models) bucket="models" ;;
        installer|installers) bucket="installers" ;;
        all|"") bucket="" ;;
        *) err "unknown catalog kind: $kind (content|model|installer|all)" >&2; return 1 ;;
    esac
    # The live Kiwix OPDS refresh only feeds the CONTENT (ZIM) bucket — model and
    # installer candidates come from local TSVs. Refresh ONLY when content rows are
    # requested (content | all), so a `catalog model`/`catalog installer` browse
    # never blocks on a multi-language OPDS fetch. This matters after #57: server.js
    # no longer forces VALARK_ZIM_LANGS=eng (that single-language fetch would clobber
    # the full multi-language cache), so an unconditional refresh here now pays the
    # full ~9-language live-fetch cost (up to 90s/lang) on every browse — the models
    # feed doesn't need it, and paying it there times out /api/catalog/models. (#57)
    if [ -z "$bucket" ] || [ "$bucket" = "content" ]; then
        catalog_refresh_zim >/dev/null 2>&1 || warn "ZIM catalog refresh failed; using cache if any" >&2
    fi
    if [ -n "$bucket" ]; then
        gen_candidates | awk -F'\t' -v b="$bucket" '$2==b' | python3 "$PLANNER" --budget 1 --list-absent
    else
        gen_candidates | python3 "$PLANNER" --budget 1 --list-absent
    fi
}

# --- resolve ONE candidate by id (content/model) from the live catalog -------
# Prints the single best-matching 9-col candidate line, or returns 1. Matching:
# exact id (with/without bucket prefix) or exact content name, else substring;
# among ties the LARGEST (maxi over nopic/mini) wins — mirrors collapse_flavours.
resolve_candidate() {
    local kind="$1" want="$2" bucket pfx tok
    case "$kind" in
        content) bucket="content"; pfx="zim:" ;;
        model)   bucket="models";  pfx="model:" ;;
        *) return 1 ;;
    esac
    tok="${want#"$pfx"}"                     # bare token (prefix stripped) for substring match
    [ "$bucket" = "content" ] && { catalog_refresh_zim >/dev/null 2>&1 || true; }
    gen_candidates | awk -F'\t' -v b="$bucket" -v id="$want" -v pid="${pfx}${want}" -v tok="$tok" '
        $2!=b { next }
        {
            exact = ($1==id || $1==pid || $9==id || $9==tok) ? 0 : -1;
            if (exact==0) { print "0\t" $0; next }
            if (index($1,tok) || index($9,tok)) print "1\t" $0;
        }' | sort -t$'\t' -k1,1n -k6,6nr | head -1 | cut -f2-
}

# --- request ONE specific item (the headline user-triggered download) --------
# Pins it (durable), makes room within the footprint cap by evicting the lowest-
# value NON-pinned content, then fetches it. Honors the cap: never overfills.
cmd_request() {
    local kind="$1" id="$2"
    [ -n "$kind" ] && [ -n "$id" ] || { err "usage: request <content|model|tool> <id>"; return 1; }
    ensure_state
    [ -f "$STOP_FLAG" ] && { warn "STOP flag present; not requesting"; return 0; }

    case "$kind" in
        tool)
            pin_add tool "$id"
            if tool_present "$id"; then ok "tool already mirrored: $id"; return 0; fi
            log "request: mirroring tool ${CYAN}${id}${NC}"
            if bash "${_LIB%/lib}/download-tools.sh" "$id"; then ok "tool mirrored: $id"; return 0
            else err "tool mirror failed: $id"; return 1; fi ;;
        content|model) : ;;
        *) err "unknown request kind: $kind (content|model|tool)"; return 1 ;;
    esac

    local line; line="$(resolve_candidate "$kind" "$id")"
    [ -n "$line" ] || { err "no catalog match for ${kind} '${id}'"; return 1; }
    IFS=$'\t' read -r c_id c_bucket c_cat c_value c_bytes c_source c_url c_dest c_extra <<< "$line"

    # Pin by the CANONICAL id so eviction-skip + refill match the manifest exactly.
    pin_add "$kind" "$c_id"

    if candidate_present "$c_id" "$c_bucket" "$c_source" "$c_value" "$c_bytes" "$c_source" "$c_url" "$c_dest" "$c_extra"; then
        ok "already present: $c_id"; return 0
    fi

    # Serialize against the loop's fill so we never race on the same files/space.
    # Wait briefly; if a long fill holds the lock, the item is already pinned, so the
    # loop's pin-refill step will fetch it — report success (queued), not failure.
    exec 9>"${STATE_DIR}/fill.lock"
    if ! flock -w 8 9; then
        ok "queued: ${c_id} is pinned; it will be fetched automatically on the next cycle"
        return 0
    fi

    # Cap-aware room-making: need = item + 1GiB slack (same as cmd_fill's guard).
    local need budget deficit
    need=$(( c_bytes + 1073741824 ))
    budget=$(valark_budget_bytes)
    if [ "$c_bytes" -gt 0 ] && [ "$need" -gt "$budget" ]; then
        deficit=$(( need - budget ))
        log "request: ${id} needs $(human "$c_bytes"); freeing $(human "$deficit") by evicting lowest-value unpinned content"
        cmd_evict --need "$deficit"
        budget=$(valark_budget_bytes)
        if [ "$need" -gt "$budget" ]; then
            err "cannot free enough space for ${c_id} (need $(human "$need"), budget $(human "$budget")); remaining content is pinned or sole-of-category — unpin something or raise VALARK_MAX_GB"
            return 1
        fi
    fi

    log "request: fetching ${CYAN}${c_id}${NC} (${c_cat}, $(human "$c_bytes"))"
    if download_one "$c_id" "$c_bucket" "$c_cat" "$c_value" "$c_bytes" "$c_source" "$c_url" "$c_dest" "$c_extra"; then
        ok "requested item ready: $c_id"; return 0
    fi
    err "download failed: $c_id (pinned; the loop will retry)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c_id" "$c_bucket" "$c_cat" "$c_value" "$c_bytes" "$c_source" "$c_url" "$c_dest" "$c_extra" >> "$FAILED"
    return 1
}

cmd_pin()   { [ -n "$1" ] && [ -n "$2" ] || { echo "usage: pin <content|model|tool> <id>"; return 1; }; pin_add "$1" "$2" && ok "pinned: $1 $2"; }
cmd_unpin() { [ -n "$1" ] || { echo "usage: unpin <id>"; return 1; }; pin_remove "$1" && ok "unpinned: $1 (files kept; now evictable)"; }

cmd_pins() {
    ensure_state
    [ -s "$PINS" ] || { echo "no pinned requests"; return 0; }
    echo -e "${CYAN}Pinned requests (never evicted; re-filled if missing):${NC}"
    local kind id epoch note present
    while IFS=$'\t' read -r kind id epoch note; do
        [ -n "$id" ] || continue
        if [ "$kind" = "tool" ]; then
            tool_present "${id#tool:}" && present="${GREEN}present${NC}" || present="${YELLOW}missing${NC}"
        elif grep -qF "$(printf '%s\t' "$id")" "$MANIFEST" 2>/dev/null; then
            local dest; dest=$(grep -F "$(printf '%s\t' "$id")" "$MANIFEST" 2>/dev/null | head -1 | cut -f4)
            { [ -e "$dest" ]; } && present="${GREEN}present${NC}" || present="${YELLOW}missing${NC}"
        else present="${YELLOW}missing${NC}"; fi
        printf "  %-8s %-46s %b\n" "$kind" "$id" "$present"
    done < "$PINS"
}

# Re-fetch any pinned item that is not currently on disk (loop self-healing).
cmd_pins_refill() {
    ensure_state
    [ -s "$PINS" ] || { log "no pins to refill"; return 0; }
    local kind id epoch note n=0
    while IFS=$'\t' read -r kind id epoch note; do
        [ -n "$id" ] || continue
        [ -f "$STOP_FLAG" ] && { warn "STOP flag; halting refill"; break; }
        if [ "$kind" = "tool" ]; then
            tool_present "${id#tool:}" && continue
            log "refill pinned tool: ${id}"; bash "${_LIB%/lib}/download-tools.sh" "${id#tool:}" >/dev/null 2>&1 && n=$(( n+1 )); continue
        fi
        # content/model: resolve fresh (urls rotate), skip if present, else fetch via request path.
        local line; line="$(resolve_candidate "$kind" "$id")"
        [ -n "$line" ] || { warn "refill: no catalog match for $id"; continue; }
        IFS=$'\t' read -r c_id c_bucket c_cat c_value c_bytes c_source c_url c_dest c_extra <<< "$line"
        candidate_present "$c_id" "$c_bucket" "$c_source" "$c_value" "$c_bytes" "$c_source" "$c_url" "$c_dest" "$c_extra" && continue
        log "refill pinned: ${c_id}"
        cmd_request "$kind" "$c_id" >/dev/null 2>&1 && n=$(( n+1 ))
    done < "$PINS"
    log "pins refill: ${n} re-fetched"
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

# When sourced (tests/tooling), expose the functions without dispatching a command.
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0

case "${1:-status}" in
    status)   cmd_status ;;
    plan)     shift; [ "$1" = "--budget" ] && cmd_plan "$2" || cmd_plan ;;
    fill)     shift; cmd_fill "$@" ;;
    verify)   cmd_verify ;;
    evict)    shift; cmd_evict "$@" ;;
    maintain) cmd_maintain ;;
    refresh)  catalog_refresh_zim --force && ok "catalog cached: $ZIM_CACHE ($(wc -l < "$ZIM_CACHE") entries)" ;;
    catalog)  shift; cmd_catalog "${1:-all}" ;;
    request)  shift; cmd_request "$1" "$2" ;;
    pin)      shift; cmd_pin "$1" "$2" ;;
    unpin)    shift; cmd_unpin "$1" ;;
    pins)     shift; [ "$1" = "--refill" ] && cmd_pins_refill || cmd_pins ;;
    *) echo "usage: librarian.sh {status|plan|fill|verify|evict|maintain|refresh|catalog|request|pin|unpin|pins}"; exit 1 ;;
esac
