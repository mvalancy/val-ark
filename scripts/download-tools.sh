#!/bin/bash
###############################################################################
# Val Ark - Tool Download Orchestrator
# Discovers and runs individual tool scripts from scripts/tools/*.sh
#
# Each tool has its own script in scripts/tools/<name>.sh that can be run
# independently or orchestrated through this script.
#
# Usage:
#   ./download-tools.sh all              Download all tools
#   ./download-tools.sh <tool-name>      Download specific tool
#   ./download-tools.sh validate         Check all download URLs
#   ./download-tools.sh list             List available tools
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_SCRIPTS="${SCRIPT_DIR}/tools"

# Source the shared library for logging and helpers
source "${TOOLS_SCRIPTS}/_common.sh"

# Setup logging
LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"
export LOG_FILE   # per-tool child shells must inherit it (log() writes here)
ensure_dir "$LOG_DIR"
SCRIPT_START=$(date +%s)

# Human elapsed time since an epoch timestamp (used in the session summary).
elapsed_since() {
    local s=$(( $(date +%s) - ${1:-$(date +%s)} ))
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
}

# Backward compatibility aliases (old names → new script names)
declare -A ALIASES=(
    [llama]="llama-cpp"
    [whisper]="whisper-cpp"
    [piper]="piper"
    [sd]="sd-cpp"
    [onnx]="onnxruntime"
    [ffmpeg]="ffmpeg"
    [vosk]="vosk"
    [bitnet]="bitnet"
)

###############################################################################
# Tool Discovery
###############################################################################

# Get list of all available tool scripts (excluding _common.sh)
list_tools() {
    local tools=()
    for script in "${TOOLS_SCRIPTS}"/*.sh; do
        local name=$(basename "$script" .sh)
        [ "$name" = "_common" ] && continue
        tools+=("$name")
    done
    echo "${tools[@]}"
}

# Check if a tool script exists
tool_exists() {
    local name="$1"
    [ -f "${TOOLS_SCRIPTS}/${name}.sh" ]
}

# Resolve a target name (handles aliases)
resolve_target() {
    local target="$1"
    if [ -n "${ALIASES[$target]+x}" ]; then
        echo "${ALIASES[$target]}"
    else
        echo "$target"
    fi
}

###############################################################################
# Run a single tool download
###############################################################################

run_tool() {
    local name="$1"
    local script="${TOOLS_SCRIPTS}/${name}.sh"

    if [ ! -f "$script" ]; then
        log_error "No script found for tool: ${name}"
        log_info "Available tools: $(list_tools)"
        return 1
    fi

    log "──────────────────────────────────────────"
    log "Tool: ${name}"
    log "──────────────────────────────────────────"

    # Run the tool script (it sources _common.sh itself)
    bash "$script"
    local status=$?

    if [ $status -ne 0 ]; then
        log_error "Tool ${name} exited with code ${status}"
    fi
    return $status
}

###############################################################################
# Download All Tools
###############################################################################

run_all() {
    echo ""
    echo "=================================================================="
    echo "  Val Ark - Tool Downloader"
    echo "  Downloading all tools for all platforms"
    echo "=================================================================="
    echo ""

    ensure_dir "$TOOLS_DIR"
    log "Tools directory: ${TOOLS_DIR}"

    local avail_gb
    avail_gb=$(df -BG "$TOOLS_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//') || avail_gb="unknown"
    log_info "Available disk space: ${avail_gb} GB"

    local tools=($(list_tools))
    local total=${#tools[@]}
    local current=0
    local failed=0

    log_info "Found ${total} tool scripts"
    echo ""

    # Download order: smallest/fastest first
    local ordered_tools=(
        # Small/fast tools first
        bitnet claude-code kicad vlc n8n milvus coolify comfyui mosquitto tmux
        # Medium tools
        vosk btop helix sqlite kiwix mqtt-explorer tailscale syncthing redis postgresql
        # Larger tools
        piper onnxruntime dev-cli miniforge python-standalone influxdb
        ollama vscodium godot freecad
        # Largest tools last
        sd-cpp whisper-cpp llama-cpp ffmpeg blender
    )

    # Add any tools not in the ordered list
    for t in "${tools[@]}"; do
        local found=0
        for o in "${ordered_tools[@]}"; do
            [ "$t" = "$o" ] && found=1 && break
        done
        [ $found -eq 0 ] && ordered_tools+=("$t")
    done

    for name in "${ordered_tools[@]}"; do
        tool_exists "$name" || continue
        current=$((current + 1))
        local pct=$((current * 100 / total))
        log_info "Progress: ${pct}% (${current}/${total})"

        run_tool "$name" || failed=$((failed + 1))
        echo ""
    done

    # Summary
    echo ""
    log "============================================================"
    log "TOOL DOWNLOAD SESSION COMPLETE"
    log "============================================================"

    local total_size
    total_size=$(du -sh "$TOOLS_DIR" 2>/dev/null | cut -f1) || total_size="unknown"
    log_info "Total tools size: ${total_size}"
    log_info "Elapsed: $(elapsed_since $SCRIPT_START)"
    log_info "Results: $((total - failed)) succeeded | ${failed} failed"

    [ $failed -gt 0 ] && return 1
    return 0
}

###############################################################################
# Validate Mode
###############################################################################

run_validate() {
    echo ""
    echo "=================================================================="
    echo "  Val Ark - Tool URL Validation"
    echo "=================================================================="
    echo ""

    local pass=0 fail=0
    local tools=($(list_tools))

    for name in "${tools[@]}"; do
        echo "${name}:"
        # Check if script has a validate function
        if grep -q "validate_${name//-/_}" "${TOOLS_SCRIPTS}/${name}.sh" 2>/dev/null; then
            bash -c "source '${TOOLS_SCRIPTS}/${name}.sh' && validate_${name//-/_}" && pass=$((pass+1)) || fail=$((fail+1))
        else
            echo "  (no validation function)"
        fi
    done

    echo ""
    echo "=================================================================="
    echo -e "  Results: ${GREEN}${pass} validated${NC} | ${RED}${fail} failed${NC}"
    echo "=================================================================="
    return $fail
}

###############################################################################
# CLI Dispatch
###############################################################################

show_usage() {
    echo ""
    echo "Usage: $0 [target]"
    echo ""
    echo "Targets:"
    echo "  all              Download all tools for all platforms"
    echo "  list             List available tool scripts"
    echo "  validate         Check download URLs"
    echo ""
    echo "Individual tools:"
    local tools=($(list_tools))
    for t in "${tools[@]}"; do
        printf "  %-20s %s\n" "$t" ""
    done
    echo ""
    echo "Aliases (backward compat):"
    for alias in "${!ALIASES[@]}"; do
        printf "  %-10s → %s\n" "$alias" "${ALIASES[$alias]}"
    done
    echo ""
}

# --- Serialize tool mirroring across ALL entry points (issue #55) -------------
# download-tools.sh is spawned four ways with no shared lock: the loop's weekly
# tool_refresh (`all`), the web one-click "request tool" (librarian.sh request →
# here) and POST /api/download/tools, and manual CLI runs. Two runs mirroring the
# SAME tool both `curl -C -` into the same <dest>.part at independent offsets,
# interleaving bytes; when the HEAD Content-Length is empty (chunked responses)
# the size check (_common.sh) can't catch it and the corrupt part is mv'd into
# place, version-stamped current, and served. A single whole-run flock on
# tools.lock serialises every entry point — and covers version_gate/version_stamp
# and the "already extracted" file-count check too, which a per-.part lock would
# not. Single-tool runs WAIT briefly then report "queued" (the tool is already
# pinned, and a running bulk mirrors it anyway); the bulk `all` refresh yields
# immediately (-n) so the loop retries it on a later tick.
TOOLS_LOCK_FD=7
acquire_tools_lock() {
    local mode="$1" sdir="${STATE_DIR:-${TOOLS_DIR}/.state}"
    command -v flock >/dev/null 2>&1 || return 0        # no flock → best-effort, don't serialise
    mkdir -p "$sdir" 2>/dev/null || true
    ( : > "${sdir}/tools.lock" ) 2>/dev/null || { log_warn "cannot create tools.lock in ${sdir} — proceeding unlocked"; return 0; }
    exec 7>"${sdir}/tools.lock"
    if [ "$mode" = bulk ]; then
        flock -n "$TOOLS_LOCK_FD" && return 0
        log_warn "another tool mirror is in progress — skipping this bulk refresh (retries next tick)"
        return 1
    fi
    flock -w "${VALARK_TOOL_LOCK_WAIT:-30}" "$TOOLS_LOCK_FD" && return 0
    log_info "tool mirror busy — request queued; the running refresh/mirror will complete it"
    return 1
}

case "${1:-all}" in
    all)
        # Bulk refresh yields to any in-flight mirror; exit 75 (temp-fail) so the
        # loop's tool_refresh takes its retry path instead of stamping "done".
        acquire_tools_lock bulk || exit 75
        run_all
        ;;
    validate)
        run_validate
        ;;
    list)
        echo ""
        echo "Available tools:"
        for t in $(list_tools); do
            echo "  $t"
        done
        echo ""
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        target=$(resolve_target "$1")
        if tool_exists "$target"; then
            # Single-tool request: wait briefly for an in-flight mirror, else queue.
            # exit 0 (success) — the tool is pinned before we get here (librarian
            # request) and the running mirror will complete it.
            acquire_tools_lock single || exit 0
            run_tool "$target"
        else
            echo -e "${RED}Unknown tool:${NC} $1"
            show_usage
            exit 1
        fi
        ;;
esac
