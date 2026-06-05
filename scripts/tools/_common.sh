#!/bin/bash
###############################################################################
# Val Ark - Shared Download Library
# Sourced by individual tool download scripts
###############################################################################

# Don't re-source if already loaded
[ -n "$_COMMON_LOADED" ] && return 0
_COMMON_LOADED=1

# Resolve project root from this file's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Honour the unified data-root layout (.env / VAL_ARK_DATA) when available.
# Falls back to the classic repo-relative layout otherwise.
if [ -f "${PROJECT_ROOT}/scripts/lib/valark-env.sh" ]; then
    # shellcheck source=../lib/valark-env.sh
    . "${PROJECT_ROOT}/scripts/lib/valark-env.sh"
fi
TOOLS_DIR="${TOOLS_DIR:-${PROJECT_ROOT}/tools}"
LOG_DIR="${LOG_DIR:-${TOOLS_DIR}/.logs}"
MAX_RETRIES=5
RETRY_DELAY=15

# Optional GitHub token for higher API rate limits
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Counters (shared across tool scripts when orchestrated)
DOWNLOAD_SUCCESS="${DOWNLOAD_SUCCESS:-0}"
DOWNLOAD_FAILED="${DOWNLOAD_FAILED:-0}"
DOWNLOAD_SKIPPED="${DOWNLOAD_SKIPPED:-0}"

# Colors (disabled when FORCE_COLOR=0 or non-interactive)
if [ "${FORCE_COLOR:-}" = "0" ] || [ ! -t 1 ]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

###############################################################################
# Logging
###############################################################################

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "$msg"
    [ -n "$LOG_FILE" ] && echo -e "$msg" >> "$LOG_FILE" 2>/dev/null
}
log_success() { log "${GREEN}OK${NC}: $*"; }
log_error()   { log "${RED}ERROR${NC}: $*"; }
log_info()    { log "${BLUE}INFO${NC}: $*"; }
log_warn()    { log "${YELLOW}WARN${NC}: $*"; }

# Human-readable elapsed time since an epoch start (used by orchestrators).
elapsed_since() {
    local start="${1:-0}" now diff h m s
    now=$(date +%s); diff=$(( now - start ))
    [ "$diff" -lt 0 ] && diff=0
    h=$(( diff / 3600 )); m=$(( (diff % 3600) / 60 )); s=$(( diff % 60 ))
    if [ "$h" -gt 0 ]; then echo "${h}h ${m}m ${s}s"
    elif [ "$m" -gt 0 ]; then echo "${m}m ${s}s"
    else echo "${s}s"; fi
}

ensure_dir() {
    if [ -f "$1" ]; then
        # File exists at directory path - move it aside
        mv "$1" "${1}.bak" 2>/dev/null
        mkdir -p "$1" 2>/dev/null
        mv "${1}.bak" "$1/$(basename "$1")" 2>/dev/null
    else
        mkdir -p "$1" 2>/dev/null || true
    fi
}

###############################################################################
# GitHub API Helpers
###############################################################################

github_api_header() {
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "Authorization: token ${GITHUB_TOKEN}"
    else
        echo "X-No-Auth: true"
    fi
}

# Resolve latest release tag for a GitHub repo
# Usage: github_latest_tag "owner/repo" "fallback-tag"
github_latest_tag() {
    local repo="$1"
    local fallback="$2"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"

    local tag
    tag=$(curl -sS --connect-timeout 5 --max-time 10 -H "$(github_api_header)" "$api_url" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$tag" ]; then
        log_warn "Could not resolve latest for ${repo}, using: ${fallback}" >&2
        echo "$fallback"
    else
        log_info "Resolved ${repo} -> ${tag}" >&2
        echo "$tag"
    fi
}

# Find asset download URL matching a pattern in a release
# Usage: github_asset_url "repo" "tag" "grep-pattern"
github_asset_url() {
    local repo="$1"
    local tag="$2"
    local pattern="$3"
    local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

    curl -sS --connect-timeout 5 --max-time 10 -H "$(github_api_header)" "$api_url" 2>/dev/null \
        | grep "browser_download_url" | grep -i "$pattern" | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/'
}

###############################################################################
# Download Helpers
###############################################################################

# Download a file with retries (never aborts script)
download_file() {
    local url="$1"
    local dest_path="$2"
    local label="${3:-$(basename "$dest_path")}"
    local attempt=1

    ensure_dir "$(dirname "$dest_path")"

    if [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
        log_info "Already exists: ${label} - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    [ -f "$dest_path" ] && [ ! -s "$dest_path" ] && rm -f "$dest_path" 2>/dev/null

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading ${label} (attempt ${attempt}/${MAX_RETRIES})"

        if command -v curl >/dev/null 2>&1; then
            curl -fL --progress-bar --connect-timeout 30 --max-time 600 \
                -o "$dest_path" "$url" 2>&1
        elif command -v wget >/dev/null 2>&1; then
            wget --progress=dot:mega --timeout=60 --tries=1 \
                "$url" -O "$dest_path" 2>&1
        fi
        local status=$?

        if [ $status -eq 0 ] && [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
            local size=$(du -h "$dest_path" 2>/dev/null | cut -f1)
            log_success "Downloaded: ${label} (${size})"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            return 0
        else
            attempt=$((attempt + 1))
            if [ $attempt -le $MAX_RETRIES ]; then
                local delay=$((RETRY_DELAY * attempt))
                log_info "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "FAILED: ${label}"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    return 1
}

# Download and extract an archive
# Usage: download_and_extract URL DEST_DIR LABEL [STRIP_COMPONENTS]
download_and_extract() {
    local url="$1"
    local dest_dir="$2"
    local label="${3:-$(basename "$url")}"
    local strip="${4:-0}"

    ensure_dir "$dest_dir"

    # Check if already extracted (has real files in dest_dir, not just .tmp_*)
    local existing=0
    while IFS= read -r _; do
        existing=$((existing + 1))
        [ $existing -ge 2 ] && break
    done < <(find "$dest_dir" -type f ! -name '.tmp_*' 2>/dev/null)
    if [ "$existing" -ge 2 ]; then
        log_info "Already extracted: ${label} - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    local archive_name=$(basename "$url" | sed 's/?.*//')
    local tmp_file="${dest_dir}/.tmp_${archive_name}"

    download_file "$url" "$tmp_file" "$label"

    if [ ! -f "$tmp_file" ] || [ ! -s "$tmp_file" ]; then
        return 1
    fi

    log_info "Extracting: ${label}"

    local extract_status=0
    case "$archive_name" in
        *.tar.gz|*.tgz)
            if [ "$strip" -gt 0 ]; then
                tar -xzf "$tmp_file" -C "$dest_dir" --strip-components="$strip" 2>/dev/null || extract_status=$?
            else
                tar -xzf "$tmp_file" -C "$dest_dir" 2>/dev/null || extract_status=$?
            fi
            ;;
        *.tar.xz|*.txz)
            if [ "$strip" -gt 0 ]; then
                tar -xJf "$tmp_file" -C "$dest_dir" --strip-components="$strip" 2>/dev/null || extract_status=$?
            else
                tar -xJf "$tmp_file" -C "$dest_dir" 2>/dev/null || extract_status=$?
            fi
            ;;
        *.tar.zst|*.tar.zstd)
            if command -v zstd >/dev/null 2>&1; then
                if [ "$strip" -gt 0 ]; then
                    zstd -d "$tmp_file" --stdout | tar -x -C "$dest_dir" --strip-components="$strip" 2>/dev/null || extract_status=$?
                else
                    zstd -d "$tmp_file" --stdout | tar -x -C "$dest_dir" 2>/dev/null || extract_status=$?
                fi
            else
                log_error "zstd not installed, cannot extract ${archive_name}"
                extract_status=1
            fi
            ;;
        *.zip)
            unzip -o -q "$tmp_file" -d "$dest_dir" 2>/dev/null || extract_status=$?
            ;;
        *.AppImage)
            cp "$tmp_file" "${dest_dir}/$(basename "$url" | sed 's/?.*//')"
            chmod +x "${dest_dir}/$(basename "$url" | sed 's/?.*//')"
            ;;
        *)
            # Treat as raw binary
            local bin_name=$(echo "$archive_name" | sed 's/\.[^.]*$//')
            cp "$tmp_file" "${dest_dir}/${bin_name}"
            chmod +x "${dest_dir}/${bin_name}"
            ;;
    esac

    if [ $extract_status -ne 0 ]; then
        log_error "Extraction failed for ${label}"
        rm -f "$tmp_file" 2>/dev/null || true
        return $extract_status
    fi

    log_success "Extracted: ${label}"

    # Archive preservation: keep initial + previous + latest
    local dist_dir="${dest_dir}/.dist"
    ensure_dir "$dist_dir"
    local initial_file="${dist_dir}/initial-${archive_name}"
    local latest_file="${dist_dir}/${archive_name}"
    local prev_file="${dist_dir}/prev-${archive_name}"

    if [ ! -f "$initial_file" ]; then
        # First ever download - save as initial
        cp "$tmp_file" "$initial_file" 2>/dev/null
        log_info "Saved initial archive: ${archive_name}"
    fi

    if [ -f "$latest_file" ] && [ -s "$latest_file" ]; then
        # Rotate latest → previous (overwrite any existing prev)
        mv -f "$latest_file" "$prev_file" 2>/dev/null || true
    fi

    # Save as latest
    mv -f "$tmp_file" "$latest_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null

    return 0
}

# Clone a git repo at a specific tag/branch
# Also creates a downloadable tarball for offline distribution
clone_repo() {
    local url="$1"
    local ref="$2"
    local dest="$3"
    local label="${4:-$(basename "$url" .git)}"

    if [ -d "$dest/.git" ]; then
        log_info "Already cloned: ${label} - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        # Ensure tarball exists even if clone was skipped
        create_source_tarball "$dest" "$label" "$ref"
        return 0
    fi

    ensure_dir "$(dirname "$dest")"
    log_info "Cloning ${label} (ref: ${ref})"

    if git clone --depth 1 --branch "$ref" "$url" "$dest" 2>/dev/null; then
        log_success "Cloned: ${label}"
        DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
        create_source_tarball "$dest" "$label" "$ref"
    else
        # Try without --branch for default branch
        if git clone --depth 1 "$url" "$dest" 2>/dev/null; then
            log_success "Cloned: ${label} (default branch)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            create_source_tarball "$dest" "$label" "$ref"
        else
            log_error "Clone failed: ${label}"
            DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
            return 1
        fi
    fi
}

# Create a tarball from a source directory for offline download
create_source_tarball() {
    local src_dir="$1"
    local label="$2"
    local version="${3:-source}"

    local dir_name=$(basename "$src_dir")
    local tarball="${src_dir}.tar.gz"

    # Skip if tarball already exists and is recent (within 24 hours)
    if [ -f "$tarball" ]; then
        local tarball_age=$(($(date +%s) - $(stat -c %Y "$tarball" 2>/dev/null || stat -f %m "$tarball" 2>/dev/null || echo 0)))
        if [ $tarball_age -lt 86400 ]; then
            log_info "Tarball exists: ${dir_name}.tar.gz"
            return 0
        fi
    fi

    log_info "Creating tarball: ${dir_name}.tar.gz"
    local parent_dir=$(dirname "$src_dir")

    # Create tarball excluding .git directory to save space
    if tar -czf "$tarball" -C "$parent_dir" --exclude='.git' "$dir_name" 2>/dev/null; then
        local size=$(du -h "$tarball" 2>/dev/null | cut -f1)
        log_success "Created: ${dir_name}.tar.gz (${size})"
    else
        log_warn "Could not create tarball for ${dir_name}"
    fi
}

# Create an install instructions file for package-managed tools
write_install_hint() {
    local dest_dir="$1"
    local tool_name="$2"
    local instructions="$3"

    ensure_dir "$dest_dir"
    if [ ! -f "${dest_dir}/INSTALL.txt" ]; then
        echo "$instructions" > "${dest_dir}/INSTALL.txt"
        log_info "Created install instructions for ${tool_name}"
    fi
}
