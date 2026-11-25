#!/bin/bash
# Val Ark - Mirror Lastbook, the free offline survival library (https://lastbook.org, MIT;
# source https://github.com/Immortal-Protocols/lastbook): manuals, videos, ZIMs, offline maps,
# address search and a local AI model, plus the app installers that read them.
#
# scripts/lib/lastbook_mirror.py reads the live release manifests (manifest-v1.json, app-v1.json,
# SHA256SUMS.txt), fetches the selection, and keeps the CURRENT release only under
#
#   content/lastbook/
#     packs/  maps/  addresses/  models/  app/<version>/     sha256-verified copies
#     manifest-v1.json  app-v1.json  SHA256SUMS.txt          the upstream manifests, as read
#
# content/ is a served tree: LAN users download the installer and the packs from the Ark.
#
# DEFAULT: THE LIBRARIAN'S PLANNER SIZES IT (#203). Each pack, state map (+ its address index),
# the model and the installers are librarian candidates with a value and a size like every ZIM,
# model and installer (scripts/lib/catalog.sh catalog_lastbook_candidates), so planner.py's
# phases (essentials, diversity, value per byte, fill) decide what fits on this disk and profile.
# The packs nest (Small < Medium < All): the planner takes at most one, a held larger pack
# satisfies a smaller one, and the survival profile lists the Small pack + installers as
# essentials (data/essentials.tsv). This script then fetches what was planned:
#   - from `librarian.sh fill`, which passes its plan rows (--plan-file FILE);
#   - run on its own (the weekly `download-tools.sh all`, the web UI's Mirror button), it asks
#     the planner first (`librarian.sh lastbook-plan`).
# Either way it calls lastbook_mirror.py with --pack auto --pack-limit <planned pack> (every auto
# guard still applies: step up never down, HEAD-confirmed upgrades, keep the held pack), the
# planned maps / model / installers, and --plus-held, so what is already held keeps refreshing.
# Once a larger pack is verified the smaller packs nested in it are pruned; prune touches only
# files the mirror recorded and refuses truncated-looking releases (#182/#194).
# VALARK_LASTBOOK_MAPS / _ADDRESSES (follow|none) / _MODEL (no = never) / _APPS (none) filter what
# is offered to the planner.
#
# OPERATOR-CHOSEN SELECTION (the planner stays out of it; sized by the share below):
#   SERVERS / NAS MIRRORS opt in to everything (all three packs, every map, the model, ~570 GB):
#     VALARK_LASTBOOK_PACK=every VALARK_LASTBOOK_MAPS=all VALARK_LASTBOOK_MODEL=yes  (in .env), or
#     scripts/tools/lastbook.sh --pack every --maps all --model yes
#   Any VALARK_LASTBOOK_PACK other than auto, an explicit VALARK_LASTBOOK_BUDGET (bytes, -1 = no
#   limit), VALARK_LASTBOOK_PLAN=0, or a selection option on the command line (--pack, --maps,
#   --addresses, --model, --apps, --budget, --share, --cap) uses this mode. Its budget: Lastbook
#   may hold VALARK_LASTBOOK_BUDGET_PCT (default 50) percent of (headroom above the reserve on the
#   disk that holds content/lastbook, capped by VALARK_MAX_GB, + what it already holds).
#   DEPRECATED: setting VALARK_LASTBOOK_BUDGET_PCT on its own also selects this mode (the old
#   fixed share) and logs a warning; drop it to let the planner size Lastbook.
# Preview without fetching: scripts/tools/lastbook.sh --dry-run   (or: plan)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOOL_NAME="lastbook"
LASTBOOK_PY="${PROJECT_ROOT}/scripts/lib/lastbook_mirror.py"
LASTBOOK_DIR="${VALARK_LASTBOOK_DIR:-${CONTENT_DIR:-${VALARK_HOME:-$PROJECT_ROOT}/content}/lastbook}"

# Why the operator's own selection applies (prints the reason), else nothing: the planner sizes it.
lastbook_manual_reason() {
    local a
    for a in "$@"; do
        case "$a" in
            --pack|--pack=*|--maps|--maps=*|--addresses|--addresses=*|--model|--model=*|--apps|--apps=*|\
            --budget|--budget=*|--share|--share=*|--cap|--cap=*|--pack-limit|--pack-limit=*)
                echo "a selection option on the command line"; return ;;
        esac
    done
    [ "${VALARK_LASTBOOK_PLAN:-1}" = "0" ] && { echo "VALARK_LASTBOOK_PLAN=0"; return; }
    case "$(printf '%s' "${VALARK_LASTBOOK_PACK:-auto}" | tr 'A-Z' 'a-z')" in
        auto) ;;
        *) echo "VALARK_LASTBOOK_PACK=${VALARK_LASTBOOK_PACK}"; return ;;
    esac
    [ -n "${VALARK_LASTBOOK_BUDGET:-}" ] && { echo "VALARK_LASTBOOK_BUDGET"; return; }
    [ -n "${VALARK_LASTBOOK_BUDGET_PCT:-}" ] && { echo "VALARK_LASTBOOK_BUDGET_PCT (deprecated)"; return; }
}

# The mirror selection for the Lastbook rows of a planner plan (planner.py output, 10 columns):
# one option or value per line.
lastbook_planned_sel() {
    local f="$1" pack maps model=no apps=none addr=follow
    pack=$(awk -F'\t' '$6=="lastbook" && $1 ~ /^lastbook:pack:/ {sub(/^lastbook:pack:/, "", $1); print $1}' "$f" 2>/dev/null | paste -sd, -)
    maps=$(awk -F'\t' '$6=="lastbook" && $1 ~ /^lastbook:map:/ {sub(/^lastbook:map:/, "", $1); print $1}' "$f" 2>/dev/null | paste -sd, -)
    awk -F'\t' '$6=="lastbook" && $1 ~ /^lastbook:model:/ {f=1} END {exit !f}' "$f" 2>/dev/null && model=yes
    awk -F'\t' '$6=="lastbook" && $1 ~ /^lastbook:app:/ {f=1} END {exit !f}' "$f" 2>/dev/null && apps=current
    [ "$(printf '%s' "${VALARK_LASTBOOK_ADDRESSES:-follow}" | tr 'A-Z' 'a-z')" = none ] && addr=none
    printf '%s\n' --pack auto --pack-limit "$pack" --maps "${maps:-none}" --addresses "$addr" \
        --model "$model" --apps "$apps" --plus-held --budget -1
}

download_lastbook() {
    log "Mirroring ${TOOL_NAME}..."
    command -v python3 >/dev/null 2>&1 || { log_error "${TOOL_NAME}: python3 is required"; return 1; }
    # Python's TLS uses its own store; reuse the fresh CA bundle _common.sh found for curl.
    [ -n "${CURL_CA_BUNDLE:-}" ] && [ -z "${SSL_CERT_FILE:-}" ] && export SSL_CERT_FILE="$CURL_CA_BUNDLE"

    local cmd=mirror plan_file=""
    if [ "${1:-}" = plan ]; then cmd=plan; shift; fi
    if [ "${1:-}" = --plan-file ]; then plan_file="${2:-}"; shift 2 2>/dev/null || shift; fi

    local manual sel=() budget="" pct="${VALARK_LASTBOOK_BUDGET_PCT:-50}"
    manual=$(lastbook_manual_reason "$@")
    if [ -n "$manual" ]; then
        case "$manual" in *deprecated*)
            log_warn "${TOOL_NAME}: VALARK_LASTBOOK_BUDGET_PCT is deprecated: it gives Lastbook a fixed ${pct}% share instead of letting the librarian's planner size it (#203). Remove it from .env to switch." ;;
        esac
        [ -n "$plan_file" ] && log_info "${TOOL_NAME}: ${manual} applies, so the planner's rows are ignored"
        # The bytes this run may ADD: an explicit VALARK_LASTBOOK_BUDGET (-1 = no limit), else
        # lastbook_mirror.py works it out: headroom above the reserve on the filesystem that holds
        # LASTBOOK_DIR (not DATA_ROOT: it may be another disk), capped by what VALARK_MAX_GB still
        # allows (only when LASTBOOK_DIR is inside the data trees that cap accounts for), and Lastbook
        # may hold PCT percent of (that headroom + what it already holds), so its share never
        # compounds across runs. Downloads also stop at the reserve.
        budget="${VALARK_LASTBOOK_BUDGET:-}"
        case "$pct" in ''|*[!0-9]*) log_error "${TOOL_NAME}: VALARK_LASTBOOK_BUDGET_PCT wants 1-100"; return 2 ;; esac
        pct=$((10#$pct)); [ "$pct" -lt 1 ] && pct=1; [ "$pct" -gt 100 ] && pct=100
        local size_args=(--budget "$budget")
        if [ -z "$budget" ]; then
            size_args=(--share "$pct")
            # VALARK_MAX_GB bounds Val Ark's own data trees (valark_data_used_bytes). A Lastbook dir
            # outside them is not in that accounting, so the cap would not count what Lastbook holds:
            # then it is not applied (the dest disk's headroom + reserve + share still are).
            local in_trees=0 d real_lb; real_lb=$(realpath -m "$LASTBOOK_DIR" 2>/dev/null || echo "$LASTBOOK_DIR")
            for d in "${MODELS_DIR:-}" "${TOOLS_DIR:-}" "${CONTENT_DIR:-}" "${SOURCES_DIR:-}" "${ASSETS_DIR:-}" "${INSTALLERS_DIR:-}" "${PRIVATE_DIR:-}"; do
                [ -n "$d" ] || continue
                d=$(realpath -m "$d" 2>/dev/null || echo "$d")
                case "$real_lb/" in "$d"/*) in_trees=1 ;; esac
            done
            if [ -n "${VALARK_MAX_GB:-}" ] && [ "$in_trees" = 0 ]; then
                log_info "${TOOL_NAME}: ${LASTBOOK_DIR} is outside the Val Ark data trees, so VALARK_MAX_GB does not bound it"
            fi
            local max_gb="${VALARK_MAX_GB:-}"; [ "$in_trees" = 1 ] || max_gb=""
            case "$max_gb" in
                ''|*[!0-9]*) ;;
                *) if declare -F valark_data_used_bytes >/dev/null; then
                       local used cap; used=$(valark_data_used_bytes 2>/dev/null)
                       case "$used" in ''|*[!0-9]*) ;; *)
                           cap=$(( VALARK_MAX_GB * 1073741824 - used )); [ "$cap" -lt 0 ] && cap=0
                           size_args+=(--cap "$cap") ;;
                       esac
                   fi ;;
            esac
        fi
        sel=(--pack "${VALARK_LASTBOOK_PACK:-auto}" --maps "${VALARK_LASTBOOK_MAPS:-auto}"
             --addresses "${VALARK_LASTBOOK_ADDRESSES:-follow}" --model "${VALARK_LASTBOOK_MODEL:-auto}"
             --apps "${VALARK_LASTBOOK_APPS:-current}" "${size_args[@]}")
    else
        # The planner decides (#203). Without rows from `librarian.sh fill`, ask it now.
        local own_plan=""
        if [ -z "$plan_file" ]; then
            own_plan=$(mktemp "${TMPDIR:-/tmp}/lastbook-plan.XXXXXX") || return 1
            plan_file="$own_plan"
            if ! bash "${PROJECT_ROOT}/scripts/librarian.sh" lastbook-plan > "$plan_file" 2>/dev/null; then
                log_warn "${TOOL_NAME}: the librarian's planner could not run; refreshing only what is held"
                : > "$plan_file"
            fi
        fi
        [ -f "$plan_file" ] || { log_error "${TOOL_NAME}: no plan file ${plan_file}"; return 2; }
        local line; while IFS= read -r line; do sel+=("$line"); done < <(lastbook_planned_sel "$plan_file")
        local planned; planned=$(awk -F'\t' '$6=="lastbook" {sub(/^lastbook:/, "", $1); print $1}' "$plan_file" | paste -sd' ' -)
        log_info "${TOOL_NAME}: sized by the librarian's planner: ${planned:-nothing new planned} (plus what is held)"
        [ -n "$own_plan" ] && rm -f "$own_plan"
        budget="planned"
    fi

    if [ "$cmd" = plan ]; then
        python3 "$LASTBOOK_PY" plan --dest "$LASTBOOK_DIR" "${sel[@]}" "$@"
        return $?
    fi
    local a; for a in "$@"; do [ "$a" = --dry-run ] && { python3 "$LASTBOOK_PY" mirror --dest "$LASTBOOK_DIR" "${sel[@]}" "$@"; return $?; }; done

    ensure_dir "$LASTBOOK_DIR"
    # One mirror run per Lastbook dir at a time: the librarian's fill and the weekly tool refresh
    # can both start one, and two writers on the same .part would corrupt it.
    local lock="${STATE_DIR:-$LASTBOOK_DIR}/lastbook.lock"
    if command -v flock >/dev/null 2>&1; then
        { exec 8>"$lock"; } 2>/dev/null && if ! flock -n 8; then
            DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
            log_warn "${TOOL_NAME}: another Lastbook mirror run is active; skipping (it resumes next run)"
            return 0
        fi
    fi
    local out rc
    out=$(python3 "$LASTBOOK_PY" mirror --dest "$LASTBOOK_DIR" "${sel[@]}" \
        --tries "${MAX_RETRIES:-5}" --retry-wait "${RETRY_DELAY:-15}" "$@")
    rc=$?
    # Progress (incl. the web UI's @@valark-dl job markers) went to stderr live; stdout ends
    # with one JSON summary line.
    local summary; summary=$(printf '%s\n' "$out" | tail -1)
    _lb() { printf '%s' "$summary" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(" ".join(v) if isinstance(v, list) else (v if v is not None else ""))' "$1" 2>/dev/null; }
    case "$rc" in
        0)  DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            log_success "${TOOL_NAME}: current release mirrored (pack: $(_lb packs || echo none); app $(_lb app_version); $(valark_human "$(_lb added_bytes)") added; $(du -sh "$LASTBOOK_DIR" 2>/dev/null | cut -f1) held)" ;;
        3)  DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
            if [ "$budget" = planned ]; then
                log_warn "${TOOL_NAME}: incomplete (pack: $(_lb packs || echo none)) - the disk reached the reserve before part of the planned selection, or a larger pack was skipped because upstream's size could not be confirmed / is wrong (see the lastbook: lines above); resumes / re-checked next run"
            else
                log_warn "${TOOL_NAME}: incomplete (pack: $(_lb packs || echo none)) - part of the selection did not fit the budget (${budget:-${pct}% share}), or a larger pack was skipped because upstream's size could not be confirmed / is wrong (see the lastbook: lines above). Budget: free space or raise VALARK_LASTBOOK_BUDGET_PCT / VALARK_MAX_GB; upstream: re-checked next run"
            fi ;;
        64) log_error "${TOOL_NAME}: bad option (see the header of scripts/tools/lastbook.sh)"; return 2 ;;
        *)  log_error "${TOOL_NAME}: mirror failed (exit ${rc}); partial downloads resume next run"; return 1 ;;
    esac
    return 0
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_lastbook "$@"
