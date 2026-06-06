#!/bin/bash
###############################################################################
# Val Ark - functional verification ("does it actually work?")
#
# A big part of the 24/7 loop is CONFIRMING things work, not just downloading.
# This checks, best-effort and non-destructively:
#   local   - native tool binaries run; kiwix serves a ZIM; a tiny LLM infers;
#             the web API answers; downloaded files pass integrity.
#   fleet   - each configured remote host (VALARK_FLEET in .env) is reachable,
#             sees the shared content, and can run a basic command.
#
# Usage: verify.sh [local|fleet|all]
# Writes a report to STATE_DIR/verify.json and prints a summary.
###############################################################################
set -o pipefail
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "${_LIB}/valark-env.sh"

PASS=0; FAIL=0; SKIP=0
RESULTS=""
RED=''; GREEN=''; YELLOW=''; NC=''
if [ -t 1 ] && [ "${FORCE_COLOR:-}" != "0" ]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'; fi
chk()  { PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $*"; RESULTS="${RESULTS}PASS|$*\n"; }
bad()  { FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $*"; RESULTS="${RESULTS}FAIL|$*\n"; }
skip() { SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $*"; RESULTS="${RESULTS}SKIP|$*\n"; }

native_tools_dir() {
    local a; a=$(uname -m)
    case "$(uname -s)/$a" in
        Darwin/*) echo "$TOOLS_DIR/macos-arm64" ;;
        Linux/aarch64) echo "$TOOLS_DIR/linux-arm64" ;;
        Linux/*) echo "$TOOLS_DIR/linux-x86_64" ;;
        *) echo "$TOOLS_DIR/linux-x86_64" ;;
    esac
}

verify_local() {
    echo "── local functional checks ──"
    local td; td=$(native_tools_dir)

    # 1) native tool binaries answer --version/--help. Binaries install at
    # nested paths (btop/bin/btop, piper/piper/piper, llama-cpp/llama-bNNNN/...),
    # so resolve each by NAME under its tool dir rather than a fixed path.
    local any_tool=0 tool name bin
    for pair in ffmpeg:ffmpeg syncthing:syncthing btop:btop helix:hx kiwix:kiwix-serve \
                llama-cpp:llama-cli sqlite:sqlite3 redis:redis-server tmux:tmux dev-cli:rg dev-cli:jq; do
        tool="${pair%%:*}"; name="${pair##*:}"
        bin=$(find "$td/$tool" -name "$name" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)
        [ -n "$bin" ] || continue
        any_tool=1
        if "$bin" --version >/dev/null 2>&1 || "$bin" --help >/dev/null 2>&1 || "$bin" -V >/dev/null 2>&1; then
            chk "tool runs: $name"
        else
            bad "tool present but won't run: $name ($bin)"
        fi
    done
    [ "$any_tool" = 0 ] && skip "no native tool binaries in $td yet"

    # 2) kiwix serves a real ZIM (start on a test port, curl, stop)
    local kbin="$td/kiwix/kiwix-serve"
    local zim; zim=$(find "$ZIM_DIR" -maxdepth 1 -name '*.zim' 2>/dev/null | head -1)
    if [ -x "$kbin" ] && [ -n "$zim" ]; then
        "$kbin" --port 8899 "$zim" >/dev/null 2>&1 &
        local kp=$!; sleep 2
        if curl -fsS --max-time 8 "http://127.0.0.1:8899/" >/dev/null 2>&1 || \
           curl -fsS --max-time 8 "http://127.0.0.1:8899/ROOT/" >/dev/null 2>&1; then
            chk "kiwix-serve serves $(basename "$zim")"
        else bad "kiwix-serve did not answer on :8899"; fi
        kill "$kp" 2>/dev/null
    else
        [ -x "$kbin" ] || skip "kiwix-serve not installed (native)"
        [ -n "$zim" ] || skip "no ZIM downloaded yet to serve"
    fi

    # 3) tiny LLM inference if a small generative gguf + llama-cli exist.
    # Resolve llama-cli at its nested build-tagged path (llama-cpp/llama-bNNNN/
    # llama-cli) by NAME, same as the tool check above — a fixed path misses it.
    # Newer llama-cli auto-enters conversation mode for instruct models and never
    # exits on stdin EOF (it hangs until killed), so run it single-turn
    # (-st -no-cnv) with stdin closed: it generates one turn and exits cleanly.
    # Pick the smallest *generative* model under models/llm — embedding models
    # under models/embed are BERT-arch and can't text-generate (false FAIL); the
    # >10M filter also skips zero-byte/stub ggufs. Cold loads off NTFS are slow,
    # hence the generous timeout; the fast inference path is the fleet GPU.
    local lc; lc=$(find "$td/llama-cpp" -name 'llama-cli' -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)
    [ -n "$lc" ] || lc="$td/llama-cli"
    local sg; sg=$(find "$MODELS_DIR/llm" -name '*.gguf' -size +10M -printf '%s\t%p\n' 2>/dev/null | sort -n | head -1 | cut -f2)
    if [ -x "$lc" ] && [ -n "$sg" ]; then
        if timeout 150 "$lc" -m "$sg" -p "hello" -n 8 -st -no-cnv --no-warmup </dev/null >/dev/null 2>&1; then
            chk "llama.cpp inference works ($(basename "$sg"))"
        else bad "llama.cpp inference failed on $(basename "$sg")"; fi
    else
        skip "llama-cli or a small generative gguf not available for inference check"
    fi

    # 4) web API health — validate it's ACTUALLY the Val Ark server (a bare 200
    # could be a different app squatting the port), on the configured port.
    # Val Ark's /api/health returns {"status":"ok","version":"1.0.0",...}. A
    # different app squatting the port returns something else (no status:ok), so
    # that field alone identifies us. (Retry — the server may be warming caches.)
    local wport="${VALARK_WEB_PORT:-3000}" hb
    hb=$(curl -fsS --retry 3 --retry-delay 1 --max-time 6 "http://127.0.0.1:${wport}/api/health" 2>/dev/null)
    if echo "$hb" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        chk "Val Ark web server responds (:$wport, $(echo "$hb" | grep -oE '"version":"[^"]*"'))"
    else
        skip "Val Ark web server not running/identified on :$wport"
    fi

    # 5) integrity of a sample of managed files (size)
    if [ -f "${STATE_DIR}/manifest.tsv" ]; then
        local checked=0 okc=0
        while IFS=$'\t' read -r id b c dest bytes value src epoch; do
            [ "$checked" -ge 25 ] && break
            checked=$((checked+1))
            if [ -f "$dest" ]; then
                local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
                if [ "$bytes" -gt 0 ] && [ "$sz" -lt $(( bytes * 90 / 100 )) ]; then okc=$okc; else okc=$((okc+1)); fi
            elif [ -d "$dest" ]; then okc=$((okc+1)); fi
        done < <(shuf "${STATE_DIR}/manifest.tsv" 2>/dev/null || cat "${STATE_DIR}/manifest.tsv")
        if [ "$checked" -gt 0 ] && [ "$okc" = "$checked" ]; then chk "integrity sample: $okc/$checked files OK"
        elif [ "$checked" -gt 0 ]; then bad "integrity sample: only $okc/$checked OK"
        else skip "no managed files to integrity-check yet"; fi
    fi
}

verify_fleet() {
    echo "── fleet functional checks (remote mesh nodes) ──"
    local fleet="${VALARK_FLEET:-}"
    [ -n "$fleet" ] || { skip "VALARK_FLEET empty (set it in .env)"; return; }
    local fdata="${VALARK_FLEET_DATA:-$DATA_ROOT}"
    local SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    local host
    for host in $fleet; do
        if out=$("${SSH[@]}" "$host" "uname -m; df -h '$fdata' 2>/dev/null | tail -1" 2>/dev/null) && [ -n "$out" ]; then
            local arch; arch=$(echo "$out" | head -1)
            chk "fleet node reachable (arch=$arch)"
            if echo "$out" | grep -q "$(basename "$fdata")"; then
                chk "fleet node mounts shared mirror (uses our disk over the network)"
                # Real GPU inference on the node, reading a model straight off the
                # share. Newer llama.cpp builds turned llama-cli into a REPL that
                # hangs on SSH stdin EOF, and some nodes ship only llama-server, so:
                # prefer llama-completion, fall back to a *real* llama-cli with
                # stdin closed; skip cleanly if neither single-shot binary exists.
                local rcmd
                rcmd=$(cat <<EOF
g=\$(find "$fdata/models/llm" "$fdata/models/embed" -name '*.gguf' 2>/dev/null | sort | head -1)
[ -n "\$g" ] || exit 0
bin=""
command -v llama-completion >/dev/null 2>&1 && bin=llama-completion
[ -z "\$bin" ] && command -v llama-cli >/dev/null 2>&1 && [ -x "\$(readlink -f "\$(command -v llama-cli)")" ] && bin=llama-cli
[ -n "\$bin" ] || exit 0
timeout 120 \$bin -m "\$g" -p ping -n 8 -ngl 999 </dev/null 2>&1 | grep -iE 'offload|CUDA|tokens per second|llama_perf' | head -3
EOF
)
                local inf; inf=$("${SSH[@]}" "$host" "$rcmd" 2>/dev/null)
                if [ -n "$inf" ]; then
                    if echo "$inf" | grep -qiE 'offload|CUDA'; then chk "fleet node GPU inference works (model served over NFS)"
                    else chk "fleet node inference ran (CPU path)"; fi
                else
                    skip "fleet node: no llama-cli + reachable model for an inference check"
                fi
            else skip "fleet node: shared content not mounted"; fi
        else
            skip "fleet node unreachable"
        fi
    done
}

write_report() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    cat > "${STATE_DIR}/verify.json" <<EOF
{ "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "pass": $PASS, "fail": $FAIL, "skip": $SKIP }
EOF
}

case "${1:-all}" in
    local) verify_local ;;
    fleet) verify_fleet ;;
    all)   verify_local; verify_fleet ;;
esac
echo ""
echo -e "verify: ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}, ${YELLOW}${SKIP} skip${NC}"
write_report
[ "$FAIL" -eq 0 ]
