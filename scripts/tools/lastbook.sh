#!/bin/bash
# Val Ark - Mirror Lastbook, the free offline survival library (https://lastbook.org, MIT;
# source https://github.com/Immortal-Protocols/lastbook): manuals, videos, ZIMs, offline maps,
# address search and a local AI model, plus the app installers that read them.
#
# scripts/lib/lastbook_mirror.py reads the live release manifests (manifest-v1.json, app-v1.json,
# SHA256SUMS.txt), picks what fits, and keeps the CURRENT release only under
#
#   content/lastbook/
#     packs/  maps/  addresses/  models/  app/<version>/     sha256-verified copies
#     manifest-v1.json  app-v1.json  SHA256SUMS.txt          the upstream manifests, as read
#
# content/ is a served tree: LAN users download the installer and the packs from the Ark.
#
# DEFAULT (part of `download-tools.sh all`, so the weekly refresh keeps it current):
#   --pack auto     the largest pack (Small 7.7 GB / Medium 67.5 GB / All 388 GB) that fits, with
#                   room left for the base maps + installers, in Lastbook's share: it may hold
#                   VALARK_LASTBOOK_BUDGET_PCT (default 50) percent of (headroom above the reserve on
#                   the disk that holds content/lastbook, capped by VALARK_MAX_GB, + what it already
#                   holds), so the librarian keeps the rest. Files already held cost nothing, so a
#                   pack once fetched stays chosen when the disk later fills. Once a larger pack is
#                   verified, the smaller packs nested in it are pruned (never with --pack every).
#   --maps auto     state maps in manifest order (largest states first) while they fit; addresses follow the maps
#   --model auto    the 16.9 GB GGUF when it still fits after the pack
#   --apps current  every installer of the current app version (mac, windows, Ubuntu debs)
# SERVERS / NAS MIRRORS opt in to everything (all three packs, every map, the model, ~570 GB):
#   VALARK_LASTBOOK_PACK=every VALARK_LASTBOOK_MAPS=all VALARK_LASTBOOK_MODEL=yes  (in .env), or
#   scripts/tools/lastbook.sh --pack every --maps all --model yes
# Preview without fetching: scripts/tools/lastbook.sh --dry-run   (or: plan)
# Any lastbook_mirror.py selection option given here overrides the .env defaults.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOOL_NAME="lastbook"
LASTBOOK_PY="${PROJECT_ROOT}/scripts/lib/lastbook_mirror.py"
LASTBOOK_DIR="${VALARK_LASTBOOK_DIR:-${CONTENT_DIR:-${VALARK_HOME:-$PROJECT_ROOT}/content}/lastbook}"

download_lastbook() {
    log "Mirroring ${TOOL_NAME}..."
    command -v python3 >/dev/null 2>&1 || { log_error "${TOOL_NAME}: python3 is required"; return 1; }
    # Python's TLS uses its own store; reuse the fresh CA bundle _common.sh found for curl.
    [ -n "${CURL_CA_BUNDLE:-}" ] && [ -z "${SSL_CERT_FILE:-}" ] && export SSL_CERT_FILE="$CURL_CA_BUNDLE"

    local cmd=mirror
    if [ "${1:-}" = plan ]; then cmd=plan; shift; fi

    # The bytes this run may ADD: an explicit VALARK_LASTBOOK_BUDGET (-1 = no limit), else
    # lastbook_mirror.py works it out: headroom above the reserve on the filesystem that holds
    # LASTBOOK_DIR (not DATA_ROOT: it may be another disk), capped by what VALARK_MAX_GB still
    # allows, and Lastbook may hold PCT percent of (that headroom + what it already holds), so its
    # share never compounds across runs. Downloads also stop at the reserve.
    local budget="${VALARK_LASTBOOK_BUDGET:-}" pct="${VALARK_LASTBOOK_BUDGET_PCT:-50}"
    case "$pct" in ''|*[!0-9]*) log_error "${TOOL_NAME}: VALARK_LASTBOOK_BUDGET_PCT wants 1-100"; return 2 ;; esac
    pct=$((10#$pct)); [ "$pct" -lt 1 ] && pct=1; [ "$pct" -gt 100 ] && pct=100
    local size_args=(--budget "$budget")
    if [ -z "$budget" ]; then
        size_args=(--share "$pct")
        case "${VALARK_MAX_GB:-}" in
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

    local sel=(--pack "${VALARK_LASTBOOK_PACK:-auto}" --maps "${VALARK_LASTBOOK_MAPS:-auto}"
               --addresses "${VALARK_LASTBOOK_ADDRESSES:-follow}" --model "${VALARK_LASTBOOK_MODEL:-auto}"
               --apps "${VALARK_LASTBOOK_APPS:-current}" "${size_args[@]}")
    if [ "$cmd" = plan ]; then
        python3 "$LASTBOOK_PY" plan --dest "$LASTBOOK_DIR" "${sel[@]}" "$@"
        return $?
    fi
    local a; for a in "$@"; do [ "$a" = --dry-run ] && { python3 "$LASTBOOK_PY" mirror --dest "$LASTBOOK_DIR" "${sel[@]}" "$@"; return $?; }; done

    ensure_dir "$LASTBOOK_DIR"
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
            log_warn "${TOOL_NAME}: incomplete - part of the selection did not fit the budget (${budget:-${pct}% share}); pack: $(_lb packs || echo none). Free space, raise VALARK_LASTBOOK_BUDGET_PCT / VALARK_MAX_GB, then re-run" ;;
        64) log_error "${TOOL_NAME}: bad option (see the header of scripts/tools/lastbook.sh)"; return 2 ;;
        *)  log_error "${TOOL_NAME}: mirror failed (exit ${rc}); partial downloads resume next run"; return 1 ;;
    esac
    return 0
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_lastbook "$@"
