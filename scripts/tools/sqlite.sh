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

    # The amalgamation is C source compiled with `gcc`, which targets the BUILD
    # HOST's arch. Compile ONLY for the platform matching this host; for the other
    # Linux arch, keep source + a build hint and scrub any binary — else mirroring on
    # an x86_64 host drops an x86 sqlite3 into linux-arm64/ ("Exec format error").
    local host_plat
    case "$(uname -m)" in
        aarch64|arm64) host_plat="linux-arm64" ;;
        x86_64|amd64)  host_plat="linux-x86_64" ;;
        *)             host_plat="" ;;
    esac

    local plat dest tmp_file src_dir
    for plat in linux-arm64 linux-x86_64; do
        dest="${TOOLS_DIR}/${plat}/sqlite"
        ensure_dir "$dest"
        tmp_file="${dest}/.tmp_sqlite-amalgamation.zip"
        download_file "$source_url" "$tmp_file" "sqlite source (${plat})"
        [ -f "$tmp_file" ] && [ -s "$tmp_file" ] || continue
        unzip -o -q "$tmp_file" -d "$dest" 2>/dev/null
        rm -f "$tmp_file" 2>/dev/null
        src_dir="${dest}/sqlite-amalgamation-${ver}"
        [ -d "$src_dir" ] || continue

        if [ "$plat" = "$host_plat" ]; then
            log_info "Compiling sqlite3 for ${plat} (native build host)..."
            if (cd "$src_dir" && gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl 2>/dev/null); then
                cp "${src_dir}/sqlite3" "${dest}/sqlite3"; chmod +x "${dest}/sqlite3"
                log_success "Compiled sqlite3 for ${plat}"
            else
                log_warn "sqlite compile failed for ${plat}"; rm -f "${dest}/sqlite3" 2>/dev/null
            fi
        else
            # scrub any wrong-arch binary from an older mirror — both the copied one
            # and the one left inside the source dir (verify.sh finds by name anywhere).
            rm -f "${dest}/sqlite3" "${src_dir}/sqlite3" 2>/dev/null
            write_install_hint "$dest" "sqlite" \
"SQLite3 for ${plat}
===================
Cross-compiling from a $(uname -m) host would produce a wrong-arch binary. The
amalgamation source is mirrored here; build it natively on the ${plat} box (one file):
  cd sqlite-amalgamation-${ver} && gcc -o sqlite3 shell.c sqlite3.c -lpthread -ldl && cp sqlite3 ../
Or use the system package: apt install sqlite3"
        fi
    done

    # windows-x64: prebuilt tools
    dest="${TOOLS_DIR}/windows-x64/sqlite"
    local win_url="https://www.sqlite.org/${year}/sqlite-tools-win-x64-${ver}.zip"
    download_and_extract "$win_url" "$dest" "sqlite windows-x64" 0
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_sqlite
