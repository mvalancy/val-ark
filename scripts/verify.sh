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
RESULT_LINES=()   # "STATUS|label" per check → serialized into verify.json for the Health page
RED=''; GREEN=''; YELLOW=''; NC=''
if [ -t 1 ] && [ "${FORCE_COLOR:-}" != "0" ]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'; fi
chk()  { PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $*"; RESULT_LINES+=("PASS|$*"); }
bad()  { FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $*"; RESULT_LINES+=("FAIL|$*"); }
skip() { SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $*"; RESULT_LINES+=("SKIP|$*"); }

# JSON-escape a label (guard \, ", and whitespace/control).
# Any other control character (a program's ANSI colour, a stray \x01) is dropped: raw, it
# would make the whole report unparseable.
_json_str() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//[[:cntrl:]]/}; printf '"%s"' "$s"; }
# Attribute a check to a Health-page component so faults point at the right thing.
_verify_comp() {
    case "$1" in
        *kiwix*|*ZIM*|*zim*)                 echo library ;;
        *"tool runs"*|*"tool present"*|*"native tool"*) echo apps ;;
        *llama*|*inference*|*gguf*)          echo models ;;
        *"web server"*|*"SAFE MODE"*)        echo server ;;
        *integrity*)                         echo integrity ;;
        *fleet*)                             echo mesh ;;
        *) echo other ;;
    esac
}

native_tools_dir() {
    local a; a=$(uname -m)
    case "$(uname -s)/$a" in
        Darwin/*) echo "$TOOLS_DIR/macos-arm64" ;;
        Linux/aarch64) echo "$TOOLS_DIR/linux-arm64" ;;
        Linux/*) echo "$TOOLS_DIR/linux-x86_64" ;;
        *) echo "$TOOLS_DIR/linux-x86_64" ;;
    esac
}

verify_cad_agent() {
    local td="$1" dir="$1/cad-agent" py="" v wheel
    wheel=$(ls "$dir"/wheelhouse/cad_agent-*.whl 2>/dev/null | head -1)
    [ -n "$wheel" ] || return 0              # not mirrored here: nothing to check
    # The wheels target the mirrored python-standalone's CPython (cp312).
    for v in "$td/python-standalone/bin/python3" "$(command -v python3 2>/dev/null)"; do
        [ -n "$v" ] && [ -x "$v" ] || continue
        if "$v" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else 1)' 2>/dev/null; then py="$v"; break; fi
    done
    [ -n "$py" ] || { skip "cad-agent: no CPython 3.12 (python-standalone) to test the wheelhouse with"; return 0; }
    local t; t=$(mktemp -d "${TMPDIR:-/tmp}/valark-verify-cad.XXXXXX") || return 0
    if PYTHONDONTWRITEBYTECODE=1 timeout 300 "$py" -m venv "$t/venv" >/dev/null 2>&1 && \
       timeout 300 "$t/venv/bin/python" -m pip install -q --no-index --disable-pip-version-check \
           --find-links "$dir/wheelhouse" "$wheel" >/dev/null 2>&1 && \
       timeout 60 "$t/venv/bin/cad-agent" --help >/dev/null 2>&1; then
        chk "tool runs: cad-agent (offline wheelhouse install, $(basename "$wheel" | cut -d- -f2))"
    else
        bad "tool present but won't run: cad-agent (offline install from $dir/wheelhouse failed)"
    fi
    rm -rf "${t:?}"
    local img
    for img in "$dir"/openfoam/*.tar; do
        [ -f "$img" ] || continue
        if tar --occurrence=1 -tf "$img" manifest.json >/dev/null 2>&1; then chk "tool present: cad-agent OpenFOAM image $(basename "$img")"
        else bad "tool present but won't run: cad-agent OpenFOAM image is not a docker archive ($(basename "$img"))"; fi
    done
}

verify_cad_agent_references() {
    # The private reference archive (scripts/tools/cad-agent-references.sh): every copy's
    # blob is present at its manifest size with its by-id link, a sample re-hashes to its
    # sha256, and a sample of git bundles passes `git bundle verify`.
    local dir="${1:-${VALARK_REFS_DIR:-${PRIVATE_DIR:-$VALARK_HOME/private}/cad-agent-references}}" out
    [ -s "$dir/manifest.jsonl" ] || return 0     # not mirrored here: nothing to check
    out=$(python3 "${_LIB}/references_mirror.py" verify --store "$dir" \
        --sample "${VALARK_REFS_VERIFY_SAMPLE:-5}" --bundles "${VALARK_REFS_VERIFY_BUNDLES:-2}" 2>&1)
    local rc=$? summary
    summary=$(printf '%s' "$out" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read().strip().splitlines()[-1])
except Exception: print("unreadable verify output"); sys.exit()
print("%d copies, %d re-hashed, %d bundle(s) verified" % (d["copies"], d["hashed"], d["bundles_verified"]) if d["ok"]
      else "; ".join(d["failures"][:3]) + (" (+%d more)" % (len(d["failures"]) - 3) if len(d["failures"]) > 3 else ""))' 2>/dev/null)
    if [ "$rc" = 0 ]; then chk "cad-agent references integrity: ${summary}"
    else bad "cad-agent references integrity: ${summary:-verify exited $rc}"; fi
}

verify_gitea() {
    # The mirrored Gitea binary for THIS host runs offline (#346): `gitea --version`
    # must answer with its version line. Not mirrored here: nothing to check.
    local bin="$1/gitea/gitea" out
    [ -f "$bin" ] || return 0
    [ -x "$bin" ] || chmod +x "$bin" 2>/dev/null
    out=$(timeout 30 "$bin" --version 2>&1 </dev/null)
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -qi '^gitea version [0-9]'; then
        chk "tool runs: gitea ($(printf '%s' "$out" | head -1 | awk '{print $3}'))"
    else
        bad "tool present but won't run: gitea ($bin: $(printf '%s' "$out" | head -1 | cut -c1-120))"
    fi
}

# Put the program a dev-stack check names into DIR and print its path; on failure print why
# and return 1. Only the named archive members are unpacked, and only as plain files: a name
# that is a folder brings nothing with it ('*' wildcards allowed; the first member is the
# program, any others are files it cannot start without). A bare, .bz2 or .xz file is the
# program itself. No unpacked file may grow past VALARK_DEVSTACK_CHECK_MAX_MB (default 2048):
# the size limit ends a decompression bomb.
_devstack_program() {
    local file="$1" dir="$3" exe bin members tool=""
    read -ra members <<< "$2"; bin="${members[0]}"
    case "$file" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2) tool=tar ;;
        *.zip) tool=unzip ;;
        *.bz2) tool=bunzip2 ;;
        *.xz)  tool=xz ;;
    esac
    [ -z "$tool" ] || command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found"; return 1; }
    (
        ulimit -f $(( ${VALARK_DEVSTACK_CHECK_MAX_MB:-2048} * 1024 )) 2>/dev/null
        case "$tool" in
            tar)   # GNU tar needs --wildcards; bsdtar matches patterns as-is and spells --no-recursion -n
                timeout -k 5 300 tar -xf "$file" -C "$dir" --no-recursion --wildcards "${members[@]}" 2>/dev/null || \
                timeout -k 5 300 tar -xf "$file" -C "$dir" -n "${members[@]}" 2>/dev/null ;;
            unzip)   timeout -k 5 300 unzip -qo "$file" "${members[@]}" -d "$dir" 2>/dev/null ;;
            bunzip2) timeout -k 5 300 bunzip2 -c "$file" > "$dir/program" 2>/dev/null ;;
            xz)      timeout -k 5 300 xz -dc "$file" > "$dir/program" 2>/dev/null ;;
            *)       cp "$file" "$dir/program" 2>/dev/null ;;
        esac
    ) 2>/dev/null || { echo "could not be unpacked"; return 1; }
    [ "$bin" = . ] && bin=program
    exe=$(find "$dir" -type f -name "${bin##*/}" 2>/dev/null | head -1)
    [ -n "$exe" ] && chmod +x "$exe" 2>/dev/null && echo "$exe" && return 0
    echo "could not be unpacked"; return 1
}

_DEVSTACK_TMP=""    # verify_devstack's temp dir, removed by its EXIT trap if the run is killed
verify_devstack() {
    # The developer stack's run checks (#397): for each data/dev-stack-checks.tsv row whose
    # project is mirrored, lib/devstack.js names the newest version's file for THIS platform.
    # Its program is pulled into a temp dir and run there: a timeout that ends in KILL, a clean
    # environment (minimal PATH, HOME = the temp dir), stdin closed, and no network where
    # unshare(1) can give it an empty network namespace. PASS / FAIL / SKIP per project.
    # A PASS is remembered per file (path + size + mtime + the check row) in
    # STATE_DIR/devstack-checks.tsv for VALARK_DEVSTACK_CHECK_DAYS (default 7), so a loop
    # cycle does not unpack every archive again; a FAIL or SKIP is tried again each time.
    # Nothing is installed or fetched, and a tree that is not mirrored has nothing to check.
    # Test seam: VALARK_DEVSTACK_CHECKS = another check file.
    local platform="$1" data="${_LIB}/../../data" node t n=0 to plan
    [ -d "$DEVSTACK_DIR" ] || return 0
    node="$HOME/.local/node/bin/node"; [ -x "$node" ] || node="$(command -v node 2>/dev/null)"
    [ -n "$node" ] || { skip "dev-stack run checks: node not found"; return 0; }
    to=$(command -v timeout 2>/dev/null)
    [ -n "$to" ] || { skip "dev-stack run checks: timeout(1) not found"; return 0; }
    t=$(mktemp -d "${TMPDIR:-/tmp}/valark-verify-devstack.XXXXXX") || return 0
    _DEVSTACK_TMP="$t"
    trap '[ -n "$_DEVSTACK_TMP" ] && rm -rf "$_DEVSTACK_TMP"' EXIT
    trap 'exit 143' TERM; trap 'exit 130' INT
    if ! plan=$("$node" "${_LIB}/devstack.js" checks "${VALARK_DEVSTACK_CHECKS:-$data/dev-stack-checks.tsv}" "$data/dev-stack.tsv" "$DEVSTACK_DIR" "$platform" 2>"$t/plan.err"); then
        bad "dev-stack run checks could not be planned ($(head -1 "$t/plan.err" | LC_ALL=C tr -cd '\40-\176' | cut -c1-120))"
        rm -rf "${t:?}"; _DEVSTACK_TMP=""; return 0
    fi
    local jail=(); local us; us=$(command -v unshare 2>/dev/null)
    [ -n "$us" ] && "$us" -rn true 2>/dev/null && jail=("$us" -rn)
    local cache="${STATE_DIR}/devstack-checks.tsv" secs="${VALARK_DEVSTACK_CHECK_TIMEOUT:-30}" now fresh
    now=$(date +%s); fresh=$(( now - ${VALARK_DEVSTACK_CHECK_DAYS:-7} * 86400 ))
    local status name file bin args expect d exe out rc label st spec at
    : > "$t/cache.new"
    while IFS=$'\x1f' read -r status name file bin args expect; do
        [ -n "$status" ] || continue
        if [ "$status" != run ]; then skip "tool present: dev-stack $name has no $platform build to run"; continue; fi
        label="tool runs: dev-stack $name (${file##*/})"
        st=$(stat -c '%s %Y' "$file" 2>/dev/null || stat -f '%z %m' "$file" 2>/dev/null); spec="$bin|$args|$expect"
        # a PASS for this exact file and check row, young enough: keep it (with its own date)
        at=$(F="$file" S="${st% *}" M="${st#* }" SPEC="$spec" MIN="$fresh" awk -F'\t' \
            '$1==ENVIRON["F"] && $2==ENVIRON["S"] && $3==ENVIRON["M"] && $5==ENVIRON["SPEC"] && $4+0>=ENVIRON["MIN"]+0 {print $4; exit}' "$cache" 2>/dev/null)
        if [ -n "$at" ]; then
            chk "$label"; printf '%s\t%s\t%s\t%s\t%s\n' "$file" "${st% *}" "${st#* }" "$at" "$spec" >> "$t/cache.new"; continue
        fi
        n=$((n+1)); d="$t/$n"; mkdir -p "$d"
        if exe=$(_devstack_program "$file" "$bin" "$d"); then
            # shellcheck disable=SC2086  # args is a space-separated list from our own TSV
            out=$(cd "$d" && env -i PATH=/usr/bin:/bin HOME="$d" TMPDIR="$d" "${jail[@]}" "$to" -k 5 "$secs" "$exe" $args 2>&1 </dev/null | head -c 65536); rc=$?
            if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Eqa -- "$expect"; then
                chk "$label"; printf '%s\t%s\t%s\t%s\t%s\n' "$file" "${st% *}" "${st#* }" "$now" "$spec" >> "$t/cache.new"
            else
                # the program's own words go into the label: printable ASCII only
                bad "tool present but won't run: dev-stack $name (${file##*/}: $(printf '%s' "$out" | head -1 | LC_ALL=C tr -cd '\40-\176' | cut -c1-120))"
            fi
        else
            skip "tool present: dev-stack $name: $exe (${file##*/})"
        fi
        rm -rf "${d:?}"
    done <<< "$plan"
    mkdir -p "$STATE_DIR" 2>/dev/null
    mv -f "$t/cache.new" "$cache" 2>/dev/null
    rm -rf "${t:?}"; _DEVSTACK_TMP=""
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
    verify_gitea "$td"
    verify_devstack "${td##*/}"

    # 1b) cad-agent's mirrored wheelhouse installs OFFLINE (pip --no-index) into a
    # throwaway venv and the CLI runs. Core package only: the full extras set is
    # what install.sh proves; it is too heavy for every loop cycle.
    verify_cad_agent "$td"
    verify_cad_agent_references

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
    # Pick the smallest *generative* model under models/{assistant,llm} — the
    # curated setup-assistant chat models land in models/assistant (see
    # data/models-extra.tsv), and on footprint-capped or mid-fill boxes an
    # assistant gguf may be the ONLY generative model present, so search both or
    # the check perpetually SKIPs and a corrupt assistant model goes uncaught.
    # Exclude models/embed — embedding models there are BERT-arch and can't
    # text-generate (false FAIL); the >10M filter also skips zero-byte/stub
    # ggufs. Cold loads off NTFS are slow, hence the generous timeout; the fast
    # inference path is the fleet GPU.
    local lc; lc=$(find "$td/llama-cpp" -name 'llama-cli' -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)
    [ -n "$lc" ] || lc="$td/llama-cli"
    local sg; sg=$(find "$MODELS_DIR/assistant" "$MODELS_DIR/llm" -name '*.gguf' -size +10M -printf '%s\t%p\n' 2>/dev/null | sort -n | head -1 | cut -f2)
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
    if echo "$hb" | grep -q '"safeMode"[[:space:]]*:[[:space:]]*true'; then
        bad "Val Ark is in SAFE MODE — config corrupt; recover from the box UI or 'valark setpassword' (content is safe)"
    elif echo "$hb" | grep -qE '"status"[[:space:]]*:[[:space:]]*"(ok|safe-mode)"'; then
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
g=\$(find "$fdata/models/assistant" "$fdata/models/llm" "$fdata/models/embed" -name '*.gguf' 2>/dev/null | sort | head -1)
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
    local tmp="${STATE_DIR}/verify.json.tmp" checks="" line status label comp first=1
    for line in "${RESULT_LINES[@]}"; do
        status="${line%%|*}"; label="${line#*|}"; comp="$(_verify_comp "$label")"
        [ "$first" = 1 ] && first=0 || checks="${checks},"
        checks="${checks}"$'\n'"    { \"status\": \"${status}\", \"comp\": \"${comp}\", \"label\": $(_json_str "$label") }"
    done
    {
        printf '{ "ts": "%s", "pass": %d, "fail": %d, "skip": %d,\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PASS" "$FAIL" "$SKIP"
        printf '  "checks": [%s\n  ] }\n' "$checks"
    } > "$tmp" && mv -f "$tmp" "${STATE_DIR}/verify.json"
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
