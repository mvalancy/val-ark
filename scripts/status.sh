#!/bin/bash
###############################################################################
# Val Ark - Status Script
# Shows what's currently installed and disk usage
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

MODEL_ROOT="/home/uat-admin/models"
TOOLS_ROOT="${MODEL_ROOT}/tools"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}Val Ark - Status${NC}"
echo -e "${DIM}══════════════════════════════════════${NC}"
echo ""

###############################################################################
# Project Structure
###############################################################################

echo -e "${CYAN}Project:${NC} ${PROJECT_ROOT}"
echo ""

###############################################################################
# Tools Status
###############################################################################

echo -e "${BOLD}Tools${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

if [ -d "${PROJECT_ROOT}/tools" ]; then
    for platform_dir in "${PROJECT_ROOT}/tools"/*/; do
        [ -d "$platform_dir" ] || continue
        plat=$(basename "$platform_dir")
        count=$(find "$platform_dir" -type f 2>/dev/null | wc -l)
        size=$(du -sh "$platform_dir" 2>/dev/null | cut -f1)
        printf "  %-20s %6s (%d files)\n" "$plat" "$size" "$count"
    done
else
    echo -e "  ${DIM}No tools downloaded yet${NC}"
fi

if [ -d "${TOOLS_ROOT}" ]; then
    echo ""
    echo -e "  ${DIM}AI inference tools (${TOOLS_ROOT}):${NC}"
    for tool_dir in "${TOOLS_ROOT}"/*/; do
        [ -d "$tool_dir" ] || continue
        tool=$(basename "$tool_dir")
        size=$(du -sh "$tool_dir" 2>/dev/null | cut -f1)
        printf "    %-24s %s\n" "$tool" "$size"
    done
fi
echo ""

###############################################################################
# Source Repos
###############################################################################

echo -e "${BOLD}Source Repos${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

if [ -d "${PROJECT_ROOT}/sources" ]; then
    for repo_dir in "${PROJECT_ROOT}/sources"/*/; do
        [ -d "$repo_dir" ] || continue
        name=$(basename "$repo_dir")
        if [ -d "$repo_dir/.git" ]; then
            tag=$(git -C "$repo_dir" describe --tags --abbrev=0 2>/dev/null || echo "HEAD")
            printf "  %-24s %s\n" "$name" "$tag"
        fi
    done
else
    echo -e "  ${DIM}No sources cloned yet${NC}"
fi
echo ""

###############################################################################
# Models Status
###############################################################################

echo -e "${BOLD}AI Models${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

if [ -d "${MODEL_ROOT}" ]; then
    for cat_dir in llm tts stt vlm image-gen nvidia-special; do
        dir="${MODEL_ROOT}/${cat_dir}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            count=$(find "$dir" -type f -name "*.gguf" -o -name "*.bin" -o -name "*.safetensors" -o -name "*.onnx" 2>/dev/null | wc -l)
            printf "  %-20s %6s (%d model files)\n" "$cat_dir" "$size" "$count"
        fi
    done
    echo ""
    total=$(du -sh "${MODEL_ROOT}" 2>/dev/null | cut -f1)
    echo -e "  ${BOLD}Total models: ${total}${NC}"
else
    echo -e "  ${DIM}No models downloaded yet${NC}"
    echo "  Run: ./start.sh download models tier1"
fi
echo ""

###############################################################################
# Ollama Installers
###############################################################################

echo -e "${BOLD}Ollama Installers${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"

OLLAMA_DIR="${PROJECT_ROOT}/assets/ollama"
if [ -d "$OLLAMA_DIR" ] && ls -d "${OLLAMA_DIR}"/v* &>/dev/null; then
    for ver_dir in "${OLLAMA_DIR}"/v*/; do
        [ -d "$ver_dir" ] || continue
        ver=$(basename "$ver_dir")
        files=$(ls "$ver_dir" 2>/dev/null | wc -l)
        printf "  %-12s (%d installers)\n" "$ver" "$files"
    done
else
    echo -e "  ${DIM}None downloaded yet${NC}"
fi
echo ""

###############################################################################
# Disk Space
###############################################################################

echo -e "${BOLD}Disk Space${NC}"
echo -e "${DIM}──────────────────────────────────────${NC}"
df -h "${PROJECT_ROOT}" | tail -1 | awk '{printf "  Total: %s | Used: %s | Available: %s (%s)\n", $2, $3, $4, $5}'
echo ""
