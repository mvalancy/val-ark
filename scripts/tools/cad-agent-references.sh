#!/bin/bash
# Val Ark - Back up every source in cad-agent's reference knowledge base.
#
# cad-agent (https://github.com/Valpatel/cad-agent) cites, and has catalogued
# for later study, ~760 sources: open-hardware repos, design guides, vendor
# tables, datasheets and papers. It publishes the list beside its site
# (catalog/references/index.json + records.json + one <area>.json per area).
# This entry reads that list (the Ark keeps no URL list of its own) and keeps a
# private, offline copy of every source, so cad-agent's references can be read,
# cited and mined with no internet:
#
#   private/cad-agent-references/
#     manifest.jsonl        one line per fetch outcome (schema: docs/knowledge/decisions.md)
#     blobs/<aa>/<sha256>.<ext>   content-addressed copies: .bundle (full-history git
#                                 bundle), .html (monolith single file), .pdf, other files
#     by-id/<record id>.<ext>     the record's latest copy (relative symlink)
#     index/                      the published index as last read (every record field)
#
# Owner decision (2026-11-04): mirror EVERYTHING, whatever the licence, with
# no repo size cap by default (~36 GB). The licence class only sets each
# copy's `redistribute` flag, which governs SERVING, never keeping. That is
# why the store lives under private/, outside every tree the web server
# serves (tools, models, content, sources, assets, installers, docs).
#
# OPT-IN: this is not a tool refresh. download-tools.sh `all` (the loop's weekly
# refresh, start.sh "download all") skips it, and the web UI cannot start it,
# because its first pass is ~37 GB and can take a day. Run it yourself, detached,
# straight from this script (not through download-tools.sh, which would hold the
# tool lock for the whole pass):
#   nohup scripts/tools/cad-agent-references.sh >> <state>/logs/references.log 2>&1 &
# It resumes where it stopped (each item is its own manifest line), so re-run it
# after an interruption, and again now and then (e.g. a monthly cron) to re-check.
#
# Options (also from .env): --dry-run (plan + size estimate, fetches only the
# index), --max-repo-mb N / VALARK_REFS_MAX_REPO_MB (pointer only above N MB,
# for small disks), --refresh (re-check every copy now; otherwise copies older
# than VALARK_REFS_REFRESH_DAYS, default 30, are re-checked), --limit N,
# --index URL|path / VALARK_REFS_INDEX, --github-sizes (repo sizes from the
# GitHub API for the dry-run estimate).
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOOL_NAME="cad-agent-references"
REFS_PY="${PROJECT_ROOT}/scripts/lib/references_mirror.py"
REFS_INDEX="${VALARK_REFS_INDEX:-https://cad-agent.valpatel.com/catalog/references/index.json}"
REFS_DIR="${VALARK_REFS_DIR:-${PRIVATE_DIR:-${VALARK_HOME:-$PROJECT_ROOT}/private}/cad-agent-references}"
REFS_MAX_REPO_MB="${VALARK_REFS_MAX_REPO_MB:-0}"
REFS_REFRESH_DAYS="${VALARK_REFS_REFRESH_DAYS:-30}"
# monolith (Y2Z/monolith, CC0): one self-contained HTML file per page, no browser.
MONOLITH_VERSION="v2.12.0"
# sha256 of each v2.12.0 release asset (GitHub's published asset digests).
monolith_sha256() {
    case "$1" in
        monolith-cli-linux-x86_64)               echo 5d6db497e19b51db0c95362b41c966d2e4b18ecd415795f7ac2d324fd5adbcf6 ;;
        monolith-cli-linux-aarch64)              echo 1933940d489c730e8a665dd81681bc6f3f4f3c6265dc3b3066765503626d0389 ;;
        monolith-cli-macos-aarch64-apple-darwin) echo 2dc89a796d9c6932e7c7c7a6d58011ec7d99b9c6f454619283664e2aeb0148a9 ;;
        monolith-cli-macos-x86_64-apple-darwin)  echo fcb8261e2ab45ab047bf05336cc7f5cfc472afb2d821be1e309d630b676f891c ;;
    esac
}

# The monolith binary for this host: $VALARK_MONOLITH, one on PATH, or the pinned
# release fetched into the store's .bin/ and checked against its sha256. Prints its
# path only if it actually runs (`-V`; a noexec mount fails here), else nothing:
# pages are then kept as raw HTML, recorded as tool "raw-html".
refs_monolith() {
    if [ -n "${VALARK_MONOLITH+x}" ]; then echo "$VALARK_MONOLITH"; return 0; fi
    local onpath; onpath=$(command -v monolith 2>/dev/null)
    if refs_runs "$onpath"; then echo "$onpath"; return 0; fi
    local asset
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64)          asset=monolith-cli-linux-x86_64 ;;
        Linux/aarch64)         asset=monolith-cli-linux-aarch64 ;;
        Darwin/arm64)          asset=monolith-cli-macos-aarch64-apple-darwin ;;
        Darwin/x86_64)         asset=monolith-cli-macos-x86_64-apple-darwin ;;
        *) return 0 ;;
    esac
    local bin="${REFS_DIR}/.bin/monolith-${MONOLITH_VERSION}" want got
    if [ ! -f "$bin" ]; then
        download_file "${VALARK_MONOLITH_BASE_URL:-https://github.com/Y2Z/monolith/releases/download}/${MONOLITH_VERSION}/${asset}" "$bin" \
            "monolith ${MONOLITH_VERSION}" >&2 || { rm -f "${bin:?}"; return 0; }
        want=$(monolith_sha256 "$asset")
        got=$( (sha256sum "$bin" 2>/dev/null || shasum -a 256 "$bin" 2>/dev/null) | cut -d' ' -f1)
        if [ -z "$want" ] || [ "$got" != "$want" ]; then
            log_warn "${TOOL_NAME}: monolith ${asset} sha256 ${got:-?} is not the pinned ${want:-?} - not used" >&2
            rm -f "${bin:?}"; return 0
        fi
        chmod +x "$bin" 2>/dev/null
    fi
    refs_runs "$bin" && echo "$bin"
}

# Can this binary execute here? (A noexec data mount passes -x tests on some systems.)
refs_runs() { [ -n "$1" ] && timeout 20 "$1" -V >/dev/null 2>&1; }

download_cad_agent_references() {
    log "Mirroring ${TOOL_NAME}..."
    command -v git >/dev/null 2>&1 || { log_error "${TOOL_NAME}: git is required"; return 1; }
    command -v python3 >/dev/null 2>&1 || { log_error "${TOOL_NAME}: python3 is required"; return 1; }

    local dry=0 args=() pargs=() a
    while [ $# -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            --dry-run|plan) dry=1 ;;
            --max-repo-mb) REFS_MAX_REPO_MB="$1"; shift ;;
            --index) REFS_INDEX="$1"; shift ;;
            --refresh|--github-sizes) args+=("$a"); pargs+=("$a") ;;
            --limit) args+=(--limit "$1"); shift ;;
            *) log_error "${TOOL_NAME}: unknown option $a"; return 2 ;;
        esac
    done
    case "$REFS_MAX_REPO_MB" in ''|*[!0-9]*) log_error "${TOOL_NAME}: --max-repo-mb wants a number of MB"; return 2 ;; esac

    # The budget this run may add: the librarian's disk headroom and footprint cap.
    # -1 = unknown (no limit); 0 = a full disk: nothing new is fetched.
    local budget=-1
    declare -F valark_budget_bytes >/dev/null && budget=$(valark_budget_bytes 2>/dev/null)
    case "$budget" in ''|*[!0-9]*) budget=-1 ;; esac

    if [ "$dry" = 1 ]; then
        local st=()
        [ -f "${REFS_DIR}/manifest.jsonl" ] && st=(--store "$REFS_DIR")
        python3 "$REFS_PY" plan --index "$REFS_INDEX" --max-repo-mb "$REFS_MAX_REPO_MB" \
            --refresh-days "$REFS_REFRESH_DAYS" --budget "$budget" "${st[@]}" "${pargs[@]}"
        return $?
    fi

    ensure_dir "$REFS_DIR"
    local mono out rc
    mono=$(refs_monolith)
    [ -n "$mono" ] || log_warn "${TOOL_NAME}: no monolith for $(uname -s)/$(uname -m); pages are kept as raw HTML"
    out=$(python3 "$REFS_PY" mirror --store "$REFS_DIR" --index "$REFS_INDEX" --monolith "$mono" \
        --max-repo-mb "$REFS_MAX_REPO_MB" --refresh-days "$REFS_REFRESH_DAYS" --budget "$budget" "${args[@]}")
    rc=$?
    case "$rc" in
        0) ;;
        2) log_error "${TOOL_NAME}: the published reference index could not be read (${REFS_INDEX})"; return 1 ;;
        3) log_warn "${TOOL_NAME}: another mirror run holds the lock - skipping"; DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1)); return 0 ;;
        *) log_error "${TOOL_NAME}: mirror exited ${rc}"; return 1 ;;
    esac
    # One JSON summary line: {"statuses": {...}, "added_bytes": N, "deferred": N, ...}
    local summary failed blocked gone deferred added
    summary=$(printf '%s' "$out" | tail -1)
    local stopped; stopped=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stopped") or "")' 2>/dev/null)
    [ -n "$stopped" ] && log_warn "${TOOL_NAME}: stopped, ${stopped}; free space or raise VALARK_MAX_GB, then re-run"
    _refs_n() { printf '%s' "$summary" | python3 -c 'import json,sys; d=json.load(sys.stdin); k=sys.argv[1]; print(d.get("statuses",{}).get(k, d.get(k, 0)))' "$1" 2>/dev/null || echo 0; }
    failed=$(_refs_n failed); blocked=$(_refs_n blocked); gone=$(_refs_n gone); deferred=$(_refs_n deferred); added=$(_refs_n added_bytes)
    [ "${blocked:-0}" -gt 0 ] && log_warn "${TOOL_NAME}: ${blocked} source(s) refuse automated fetches (403/robots) - link only, retried in 30 days"
    [ "${gone:-0}" -gt 0 ] && log_warn "${TOOL_NAME}: ${gone} source(s) are gone (404/410) - the earlier copy, if any, is kept"
    [ "${deferred:-0}" -gt 0 ] && log_warn "${TOOL_NAME}: ${deferred} item(s) deferred (disk budget or --limit)"
    if [ "${failed:-0}" -gt 0 ]; then
        log_error "${TOOL_NAME}: ${failed} fetch(es) failed (retried next run); see manifest.jsonl"
        DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1)); return 1
    fi
    DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
    log_success "${TOOL_NAME}: up to date ($(valark_human "${added:-0}") added; store $(du -sh "$REFS_DIR" 2>/dev/null | cut -f1))"
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_cad_agent_references "$@"
