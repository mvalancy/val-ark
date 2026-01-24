#!/bin/bash
###############################################################################
# Val Ark - ZIM Content Downloader
# Downloads offline content archives (ZIM files) for Kiwix serving.
#
# ZIM files are compressed offline snapshots of websites like Wikipedia,
# Khan Academy, Stack Overflow, Project Gutenberg, and more.
#
# Usage:
#   ./download-zims.sh              # Download all configured ZIMs
#   ./download-zims.sh list         # List available ZIMs and status
#   ./download-zims.sh serve        # Start kiwix-serve with all ZIMs
#   ./download-zims.sh status       # Show download progress
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
ZIM_DIR="${PROJECT_ROOT}/content/zim"
TOOLS_DIR="${PROJECT_ROOT}/tools"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }
log_ok() { log "${GREEN}OK${NC}: $*"; }
log_info() { log "${BLUE}INFO${NC}: $*"; }
log_warn() { log "${YELLOW}WARN${NC}: $*"; }
log_err() { log "${RED}ERROR${NC}: $*"; }

###############################################################################
# ZIM Catalog — ordered smallest to largest
###############################################################################

# Each entry: "id|filename|url|expected_size_gb|description"
ZIM_CATALOG=(
    "wikipedia-simple|wikipedia_en_simple_all_maxi_2025-11.zim|https://download.kiwix.org/zim/wikipedia/wikipedia_en_simple_all_maxi_2025-11.zim|3.1|Wikipedia Simple English (all articles, images)"
    "wikipedia-full|wikipedia_en_all_maxi_2025-08.zim|https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_maxi_2025-08.zim|111|Wikipedia English Full (all articles, all images)"
)

###############################################################################
# Helper Functions
###############################################################################

parse_entry() {
    local entry="$1"
    ZIM_ID=$(echo "$entry" | cut -d'|' -f1)
    ZIM_FILE=$(echo "$entry" | cut -d'|' -f2)
    ZIM_URL=$(echo "$entry" | cut -d'|' -f3)
    ZIM_SIZE_GB=$(echo "$entry" | cut -d'|' -f4)
    ZIM_DESC=$(echo "$entry" | cut -d'|' -f5)
}

get_file_size_gb() {
    local file="$1"
    if [ -f "$file" ]; then
        local bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)
        echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

check_disk_space() {
    local available_gb=$(df --output=avail "$PROJECT_ROOT" 2>/dev/null | tail -1)
    echo $(( available_gb / 1048576 ))
}

find_kiwix_serve() {
    local arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        echo "${TOOLS_DIR}/linux-x86_64/kiwix/kiwix-serve"
    elif [ "$arch" = "aarch64" ]; then
        echo "${TOOLS_DIR}/linux-arm64/kiwix/kiwix-serve"
    fi
}

###############################################################################
# Commands
###############################################################################

cmd_list() {
    echo ""
    echo -e "${CYAN}Val Ark - Offline Content Library${NC}"
    echo -e "${CYAN}==================================${NC}"
    echo ""

    local total_size=0
    local downloaded=0

    for entry in "${ZIM_CATALOG[@]}"; do
        parse_entry "$entry"
        local filepath="${ZIM_DIR}/${ZIM_FILE}"
        local status=""

        if [ -f "$filepath" ]; then
            local actual_gb=$(get_file_size_gb "$filepath")
            local expected_bytes=$(echo "$ZIM_SIZE_GB * 1073741824" | bc 2>/dev/null || echo 0)
            local actual_bytes=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
            # Consider complete if within 1% of expected
            local threshold=$(echo "$expected_bytes * 0.99" | bc 2>/dev/null || echo 0)
            if [ "$(echo "$actual_bytes >= ${threshold%.*}" | bc 2>/dev/null || echo 0)" = "1" ]; then
                status="${GREEN}[COMPLETE]${NC} ${actual_gb} GB"
                downloaded=$((downloaded + 1))
            else
                local pct=$(echo "scale=0; $actual_bytes * 100 / $expected_bytes" | bc 2>/dev/null || echo "?")
                status="${YELLOW}[PARTIAL ${pct}%]${NC} ${actual_gb}/${ZIM_SIZE_GB} GB"
            fi
        else
            status="${RED}[NOT DOWNLOADED]${NC} ${ZIM_SIZE_GB} GB"
        fi

        printf "  %-20s %s\n" "$ZIM_ID" "$status"
        echo -e "                       ${ZIM_DESC}"
        echo ""
    done

    echo -e "  ${BLUE}Total ZIMs:${NC} ${#ZIM_CATALOG[@]} | ${GREEN}Downloaded:${NC} ${downloaded}"
    echo -e "  ${BLUE}Disk free:${NC} $(check_disk_space) GB"
    echo ""
}

cmd_download() {
    mkdir -p "$ZIM_DIR"
    local disk_free=$(check_disk_space)
    log_info "Disk free: ${disk_free} GB"
    echo ""

    for entry in "${ZIM_CATALOG[@]}"; do
        parse_entry "$entry"
        local filepath="${ZIM_DIR}/${ZIM_FILE}"

        # Skip if already complete
        if [ -f "$filepath" ]; then
            local actual_bytes=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
            local expected_bytes=$(echo "${ZIM_SIZE_GB} * 1073741824" | bc 2>/dev/null || echo 0)
            local threshold=$(echo "$expected_bytes * 0.99" | bc 2>/dev/null || echo 0)
            if [ "$(echo "$actual_bytes >= ${threshold%.*}" | bc 2>/dev/null || echo 0)" = "1" ]; then
                log_ok "Already have: ${ZIM_ID} (${ZIM_SIZE_GB} GB)"
                continue
            fi
        fi

        # Check disk space
        local needed_gb=$(echo "$ZIM_SIZE_GB" | cut -d. -f1)
        needed_gb=$((needed_gb + 5))  # 5GB buffer
        disk_free=$(check_disk_space)
        if [ "$disk_free" -lt "$needed_gb" ]; then
            log_warn "Skipping ${ZIM_ID}: needs ~${ZIM_SIZE_GB}GB, only ${disk_free}GB free"
            continue
        fi

        log_info "Downloading: ${ZIM_ID} (${ZIM_SIZE_GB} GB)"
        log_info "  ${ZIM_DESC}"
        log_info "  URL: ${ZIM_URL}"

        # Download with resume support
        curl -L --continue-at - \
            --progress-bar \
            -o "$filepath" \
            "$ZIM_URL"

        if [ $? -eq 0 ] && [ -f "$filepath" ]; then
            local final_size=$(get_file_size_gb "$filepath")
            log_ok "${ZIM_ID}: ${final_size} GB downloaded"
        else
            log_err "Failed to download ${ZIM_ID}"
        fi
        echo ""
    done

    echo ""
    log_info "Download complete. Run './download-zims.sh serve' to start Kiwix server."
}

cmd_serve() {
    local kiwix_serve=$(find_kiwix_serve)

    if [ ! -x "$kiwix_serve" ]; then
        log_err "kiwix-serve not found. Run update.sh first to download Kiwix tools."
        exit 1
    fi

    # Find all ZIM files
    local zim_files=()
    for f in "${ZIM_DIR}"/*.zim; do
        [ -f "$f" ] && zim_files+=("$f")
    done

    if [ ${#zim_files[@]} -eq 0 ]; then
        log_err "No ZIM files found in ${ZIM_DIR}. Run './download-zims.sh' to download."
        exit 1
    fi

    local port="${1:-8888}"
    log_info "Starting Kiwix server on port ${port} with ${#zim_files[@]} ZIM file(s)..."
    for f in "${zim_files[@]}"; do
        log_info "  $(basename "$f") ($(get_file_size_gb "$f") GB)"
    done
    echo ""
    log_ok "Access at: http://localhost:${port}"
    log_info "Press Ctrl+C to stop"
    echo ""

    "$kiwix_serve" --port "$port" "${zim_files[@]}"
}

cmd_status() {
    echo ""
    echo -e "${CYAN}Download Status${NC}"
    echo ""

    for entry in "${ZIM_CATALOG[@]}"; do
        parse_entry "$entry"
        local filepath="${ZIM_DIR}/${ZIM_FILE}"

        if [ -f "$filepath" ]; then
            local actual_bytes=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
            local expected_bytes=$(echo "${ZIM_SIZE_GB} * 1073741824" | bc 2>/dev/null || echo 0)
            if [ "$expected_bytes" != "0" ] && [ "$expected_bytes" != "" ]; then
                local pct=$(echo "scale=1; $actual_bytes * 100 / $expected_bytes" | bc 2>/dev/null || echo "?")
                local actual_gb=$(get_file_size_gb "$filepath")
                printf "  %-20s %s/%s GB  (%s%%)\n" "$ZIM_ID" "$actual_gb" "$ZIM_SIZE_GB" "$pct"
            else
                printf "  %-20s downloading...\n" "$ZIM_ID"
            fi
        else
            printf "  %-20s not started\n" "$ZIM_ID"
        fi
    done
    echo ""
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in
    list)   cmd_list ;;
    serve)  cmd_serve "${2:-8888}" ;;
    status) cmd_status ;;
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (none)    Download all configured ZIM files"
        echo "  list      Show ZIM catalog and download status"
        echo "  serve     Start kiwix-serve with all downloaded ZIMs"
        echo "  status    Show download progress"
        echo "  help      Show this help"
        ;;
    *)      cmd_download ;;
esac
