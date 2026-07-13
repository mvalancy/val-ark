#!/bin/bash
###############################################################################
# Test: mirrored tool binaries match their platform dir's architecture.
#
# Catches the class of bug where a source-compiled tool (redis, built with `make`
# on the mirror host) or a mis-picked release asset lands the WRONG arch in a
# platform dir — an x86 binary under tools/linux-arm64/ → "Exec format error" on
# the target, which the Health page flags as "tool present but won't run".
#
# Checks the key runnable binaries verify.sh actually execs (resolve-by-name under
# each tool dir), so it's fast + high-signal. Skips on a bare checkout / CI (no
# mirror) or where `file` is absent.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
command -v file >/dev/null 2>&1 || { echo "SKIP: no 'file' utility" >&2; exit 0; }
TOOLS="$ROOT/tools"
[ -d "$TOOLS" ] || { echo "SKIP: no tools mirror on this host (fresh checkout/CI)" >&2; exit 0; }

# tool-dir : binary-name  (same resolve-by-name set verify.sh runs)
BINS="ffmpeg:ffmpeg syncthing:syncthing btop:btop helix:hx kiwix:kiwix-serve
      redis:redis-server sqlite:sqlite3 tmux:tmux dev-cli:rg dev-cli:jq
      llama-cpp:llama-cli whisper-cpp:whisper-cli piper:piper"

check_plat() { # $1=platform dir  $2=expected `file` arch substring
    local plat="$1" want="$2" d="$TOOLS/$1" pair tool name bin info n=0
    [ -d "$d" ] || return 0
    for pair in $BINS; do
        tool="${pair%%:*}"; name="${pair##*:}"
        bin="$(find "$d/$tool" -name "$name" -type f -perm -u+x 2>/dev/null | head -1)"
        [ -n "$bin" ] || continue
        info="$(file -L "$bin" 2>/dev/null)"
        case "$info" in *ELF*) ;; *) continue ;; esac   # only ELF (skip wrapper scripts)
        n=$((n + 1))
        if printf '%s' "$info" | grep -q "$want"; then
            PASS=$((PASS + 1))
        else
            fail "$plat/$tool/$name is NOT $want: $(printf '%s' "$info" | grep -oE 'ARM aarch64|x86-64|Intel 80386|ARM,' | head -1)"
        fi
    done
    echo "  ${plat}: checked ${n} runnable binaries" >&2
}

check_plat linux-arm64  "ARM aarch64"
check_plat linux-x86_64 "x86-64"

echo "tool-arch: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
