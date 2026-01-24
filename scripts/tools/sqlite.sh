#!/bin/bash
# Val Ark - Download SQLite
source "$(dirname "$0")/_common.sh"

TOOL_NAME="sqlite"
PINNED_VERSION="3480000"
PINNED_YEAR="2025"

download_sqlite() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local year="${PINNED_YEAR}"
    local source_url="https://www.sqlite.org/${year}/sqlite-amalgamation-${ver}.zip"

    # linux-arm64: download source and compile
    local dest="${TOOLS_DIR}/linux-arm64/sqlite"
    ensure_dir "$dest"
    local tmp_file="${dest}/.tmp_sqlite-amalgamation.zip"
    download_file "$source_url" "$tmp_file" "sqlite source (linux-arm64)"
    if [ -f "$tmp_file" ] && [ -s "$tmp_file" ]; then
        log_info "Extracting sqlite source (linux-arm64)..."
        unzip -o -q "$tmp_file" -d "$dest" 2>/dev/null
        rm -f "$tmp_file" 2>/dev/null
        # Attempt to compile
        local src_dir="${dest}/sqlite-amalgamation-${ver}"
        if [ -d "$src_dir" ]; then
            log_info "Compiling sqlite3 for linux-arm64..."
            (cd "$src_dir" && gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl 2>/dev/null) && {
                cp "${src_dir}/sqlite3" "${dest}/sqlite3"
                chmod +x "${dest}/sqlite3"
                log_success "Compiled sqlite3 for linux-arm64"
            } || {
                log_warn "Compilation failed (may need cross-compiler for arm64)"
                cat > "${dest}/BUILD.txt" << 'BUILDEOF'
SQLite3 Build Instructions (linux-arm64):

1. Source is already extracted in sqlite-amalgamation-3480000/
2. Compile with:
   cd sqlite-amalgamation-3480000
   gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl
3. Copy the sqlite3 binary to this directory
BUILDEOF
            }
        fi
    fi

    # linux-x86_64: download source and compile
    dest="${TOOLS_DIR}/linux-x86_64/sqlite"
    ensure_dir "$dest"
    tmp_file="${dest}/.tmp_sqlite-amalgamation.zip"
    download_file "$source_url" "$tmp_file" "sqlite source (linux-x86_64)"
    if [ -f "$tmp_file" ] && [ -s "$tmp_file" ]; then
        log_info "Extracting sqlite source (linux-x86_64)..."
        unzip -o -q "$tmp_file" -d "$dest" 2>/dev/null
        rm -f "$tmp_file" 2>/dev/null
        local src_dir="${dest}/sqlite-amalgamation-${ver}"
        if [ -d "$src_dir" ]; then
            log_info "Compiling sqlite3 for linux-x86_64..."
            (cd "$src_dir" && gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl 2>/dev/null) && {
                cp "${src_dir}/sqlite3" "${dest}/sqlite3"
                chmod +x "${dest}/sqlite3"
                log_success "Compiled sqlite3 for linux-x86_64"
            } || {
                log_warn "Compilation failed"
                cat > "${dest}/BUILD.txt" << 'BUILDEOF'
SQLite3 Build Instructions (linux-x86_64):

1. Source is already extracted in sqlite-amalgamation-3480000/
2. Compile with:
   cd sqlite-amalgamation-3480000
   gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl
3. Copy the sqlite3 binary to this directory
BUILDEOF
            }
        fi
    fi

    # windows-x64: prebuilt tools
    dest="${TOOLS_DIR}/windows-x64/sqlite"
    local win_url="https://www.sqlite.org/${year}/sqlite-tools-win-x64-${ver}.zip"
    download_and_extract "$win_url" "$dest" "sqlite windows-x64" 0
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_sqlite
