#!/bin/bash
# Val Ark - Tool Mirroring Audit Script
# Shows what's downloaded vs what needs attention

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/../tools"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PLATFORMS=("linux-arm64" "linux-x86_64" "macos-arm64" "windows-x64")
MIN_BINARY_SIZE=50000  # 50KB threshold

# Check if directory has real binaries
has_real_binaries() {
    local dir="$1"
    [ ! -d "$dir" ] && return 1
    find "$dir" -type f ! -name "*.txt" ! -name "*.md" -size +${MIN_BINARY_SIZE}c 2>/dev/null | head -1 | grep -q .
}

get_size() {
    local dir="$1"
    [ -d "$dir" ] && du -sh "$dir" 2>/dev/null | cut -f1 || echo "-"
}

echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                 Val Ark Tool Mirroring Audit${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo ""

# Get all tool directories
ALL_TOOLS=$(for p in "${PLATFORMS[@]}"; do
    ls -1 "${TOOLS_DIR}/$p" 2>/dev/null
done | sort -u)

# Categorize tools
declare -A tool_status  # tool -> "full|partial|hint|missing"
declare -A tool_details # tool -> details string

for tool in $ALL_TOOLS; do
    downloaded=0
    hints=0
    missing=0
    details=""

    for platform in "${PLATFORMS[@]}"; do
        dir="${TOOLS_DIR}/${platform}/${tool}"
        if [ ! -d "$dir" ]; then
            ((missing++))
            details+="${platform}:- "
        elif has_real_binaries "$dir"; then
            ((downloaded++))
            size=$(get_size "$dir")
            details+="${platform}:${GREEN}${size}${NC} "
        else
            ((hints++))
            details+="${platform}:${YELLOW}hint${NC} "
        fi
    done

    if [ $downloaded -eq 4 ]; then
        tool_status[$tool]="full"
    elif [ $downloaded -gt 0 ]; then
        tool_status[$tool]="partial"
    elif [ $hints -gt 0 ]; then
        tool_status[$tool]="hint"
    else
        tool_status[$tool]="missing"
    fi
    tool_details[$tool]="$details"
done

# Print by category
echo -e "${GREEN}=== FULLY MIRRORED (4/4 platforms) ===${NC}"
for tool in $(echo "${!tool_status[@]}" | tr ' ' '\n' | sort); do
    [ "${tool_status[$tool]}" = "full" ] && echo -e "  ${tool}: ${tool_details[$tool]}"
done
echo ""

echo -e "${CYAN}=== PARTIALLY MIRRORED ===${NC}"
for tool in $(echo "${!tool_status[@]}" | tr ' ' '\n' | sort); do
    [ "${tool_status[$tool]}" = "partial" ] && echo -e "  ${tool}: ${tool_details[$tool]}"
done
echo ""

echo -e "${YELLOW}=== INSTALL HINTS ONLY ===${NC}"
for tool in $(echo "${!tool_status[@]}" | tr ' ' '\n' | sort); do
    [ "${tool_status[$tool]}" = "hint" ] && echo -e "  ${tool}: ${tool_details[$tool]}"
done
echo ""

# Summary counts
full=0; partial=0; hint=0; miss=0
for tool in "${!tool_status[@]}"; do
    case "${tool_status[$tool]}" in
        full) ((full++)) ;;
        partial) ((partial++)) ;;
        hint) ((hint++)) ;;
        missing) ((miss++)) ;;
    esac
done

echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                          SUMMARY${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Fully Mirrored:${NC}     $full tools (all 4 platforms)"
echo -e "  ${CYAN}Partially Mirrored:${NC} $partial tools (some platforms)"
echo -e "  ${YELLOW}Install Hints Only:${NC} $hint tools (instructions, no binaries)"
echo ""
echo -e "  Total tool directories: $((full + partial + hint + miss))"
echo ""
echo -e "${BLUE}To download a specific tool:${NC} ./start.sh tools <tool-name>"
echo -e "${BLUE}To download all tools:${NC}      ./start.sh tools"
