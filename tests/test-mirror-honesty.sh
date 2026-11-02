#!/bin/bash
###############################################################################
# Test: a mirror/clone job is HONEST — it finishes with a verified result, or it
# fails visibly with a reason. Never a fake download, never a silent stall.
#
# The owner's report: "trying to mirror piper-tts fakes a download and doesn't
# finish, no warning no error etc from the ui". Root cause (reproduced): piper's
# archive wraps its files in a top directory, so after a SUCCESSFUL mirror the
# status scan (top level only) still called the tool "empty"/"Not Mirrored"; the
# Mirror button kept coming back and a re-click "completed" in ~1s ("Already
# extracted - skipping") without ever changing the badge. Around that bug the job
# layer was dishonest in general: exit 0 == "complete" even when NOTHING was
# mirrored (GitHub rate limit / no asset / 404 all exited 0), a progress bar that
# sat at 0% unless a script printed "Progress: N%", failures with no reason,
# a cancelled job overwritten to "failed", a "queued" tool run that exited 0.
#
# Sandboxed + offline (curl is a shim; the server runs in a temp copy of scripts/
# with stub tool scripts). Set VALARK_TEST_SCRIPTS_SRC to a DIFFERENT checkout's
# repo root to run the same suite against old code (the negative control):
#   VALARK_TEST_SCRIPTS_SRC=/path/to/old-checkout bash tests/test-mirror-honesty.sh
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${VALARK_TEST_SCRIPTS_SRC:-$ROOT}"
PARTS="${VALARK_TEST_PARTS:-AB}"    # A = shell layer, B = server job layer (old code retries 5 x 15s: use B for the negative control)
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: no flock" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "${T:?}" 2>/dev/null; }
trap cleanup EXIT

# jq-free JSON helper: jget '<file or ->' '<python expression on d>'
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

###############################################################################
# PART A — the shell layer (scripts/tools/_common.sh) with a shim curl
###############################################################################
if [[ "$PARTS" == *A* ]]; then
SHIM="$T/shim"; mkdir -p "$SHIM" "$T/a"
cat > "$SHIM/curl" <<'EOF'
#!/bin/bash
# Shim curl. Mode in $SHIM_DIR/mode; every invocation is logged to $SHIM_DIR/calls.
d="$(dirname "$0")"; mode="$(cat "$d/mode" 2>/dev/null)"; all="$*"
echo "$all" >> "$d/calls"
out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
is_head=0; case "$all" in *-fsIL*|*" -I "*) is_head=1;; esac
is_probe=0; case "$all" in *"%{http_code}"*) is_probe=1;; esac
is_api=0; case "$all" in *api.github.com*) is_api=1;; esac
if [ "$is_api" = 1 ]; then
    case "$mode" in
        ratelimit) echo '{"message":"API rate limit exceeded for 203.0.113.9. (But here is the good news)","documentation_url":"https://docs.github.com"}'; exit 0 ;;
        noasset)   echo '{"tag_name":"v1","assets":[{"browser_download_url":"https://example.invalid/dl/tool_windows_amd64.zip"}]}'; exit 0 ;;
        unreachable) exit 6 ;;
        *) echo '{"tag_name":"v1","assets":[{"browser_download_url":"https://example.invalid/dl/tool_linux_aarch64.tar.gz"}]}'; exit 0 ;;
    esac
fi
if [ "$is_probe" = 1 ]; then
    case "$mode" in 404) printf 404;; 403) printf 403;; stall|unreachable) printf 000;; *) printf 200;; esac; exit 0
fi
if [ "$is_head" = 1 ]; then
    case "$mode" in
        404|403) exit 22 ;;
        zero|stall) printf 'HTTP/1.1 200 OK\r\n\r\n'; exit 0 ;;
        *) printf 'HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n'; exit 0 ;;
    esac
fi
case "$mode" in
    404|403) exit 22 ;;
    zero)    : > "$out"; exit 0 ;;
    stall)   exit 28 ;;
    *)       printf 'hello' > "$out"; exit 0 ;;
esac
EOF
chmod +x "$SHIM/curl"
count_gets() { grep -c -- '--progress-bar' "$SHIM/calls" 2>/dev/null || echo 0; }
run_dl() {  # run_dl <mode> : download_file against the shim; sets A_OUT / A_RC
    echo "$1" > "$SHIM/mode"; : > "$SHIM/calls"
    A_OUT="$(PATH="$SHIM:$PATH" FORCE_COLOR=0 VAL_ARK_DATA="$T/a" VALARK_DL_RETRIES=3 VALARK_DL_RETRY_DELAY=0 \
        bash -c 'source "'"$SRC"'/scripts/tools/_common.sh"; download_file "https://example.invalid/x.bin" "'"$T"'/a/x.bin" "demo-tool linux-arm64"' 2>&1)"
    A_RC=$?
}

# A1. a 404 is permanent: ONE attempt (no 5 x back-off), and the reason names the HTTP status
rm -f "${T:?}/a/x.bin" "${T:?}/a/x.bin.part"
run_dl 404
[ "$A_RC" != 0 ] && pass || fail "A1 a 404 download must return non-zero"
echo "$A_OUT" | grep -q 'HTTP 404' && pass || fail "A1 the 404 error must say 'HTTP 404' (got: $(echo "$A_OUT" | tail -1))"
[ "$(grep -c -- '--progress-bar' "$SHIM/calls")" = 1 ] && pass || fail "A1 a 404 must be tried ONCE, not retried (GET calls: $(grep -c -- '--progress-bar' "$SHIM/calls"))"

# A2. auth required (403) is permanent and says so
run_dl 403
echo "$A_OUT" | grep -qi 'access denied\|authentication' && pass || fail "A2 a 403 must say access denied / auth required (got: $(echo "$A_OUT" | tail -1))"
[ "$(grep -c -- '--progress-bar' "$SHIM/calls")" = 1 ] && pass || fail "A2 a 403 must not be retried"

# A3. zero-byte response is rejected with its own reason (never mv'd into place)
run_dl zero
[ "$A_RC" != 0 ] && pass || fail "A3 a zero-byte download must fail"
echo "$A_OUT" | grep -qi 'zero-byte' && pass || fail "A3 the error must say zero-byte (got: $(echo "$A_OUT" | tail -1))"
[ ! -s "$T/a/x.bin" ] && pass || fail "A3 a zero-byte file must never be left at the final name"

# A4. transient/stalled network: retried up to the cap, then fails with a reason (exit 28 = timeout)
run_dl stall
[ "$A_RC" != 0 ] && pass || fail "A4 a stalled download must fail after its retries"
[ "$(grep -c -- '--progress-bar' "$SHIM/calls")" = 3 ] && pass || fail "A4 a transient failure must use the retry budget (GET calls: $(grep -c -- '--progress-bar' "$SHIM/calls"), want 3)"
echo "$A_OUT" | grep -q 'FAILED:' && pass || fail "A4 final failure must be logged as FAILED: with a reason"

# A5. the happy path still works and reports the real file (markers only when the web server asked)
run_dl ok
[ "$A_RC" = 0 ] && [ "$(cat "$T/a/x.bin" 2>/dev/null)" = hello ] && pass || fail "A5 a normal download must succeed (rc=$A_RC)"
echo "$A_OUT" | grep -q '@@valark-dl' && fail "A5 progress markers must NOT be emitted unless VALARK_JOB_MARKERS=1" || pass
rm -f "${T:?}/a/x.bin"
M="$(PATH="$SHIM:$PATH" FORCE_COLOR=0 VAL_ARK_DATA="$T/a" VALARK_JOB_MARKERS=1 bash -c 'source "'"$SRC"'/scripts/tools/_common.sh"; download_file "https://example.invalid/x.bin" "'"$T"'/a/x.bin" "demo label"' 2>&1)"
echo "$M" | grep -qP '@@valark-dl\t5\t.*x\.bin\.part\t0\tdemo label' && pass || fail "A5 with VALARK_JOB_MARKERS=1 the real size + .part path must be announced (got: $(echo "$M" | grep valark-dl))"

# A6. GitHub API failures are NOT silent (asset lookup used to just return nothing)
echo ratelimit > "$SHIM/mode"
E="$(PATH="$SHIM:$PATH" FORCE_COLOR=0 VAL_ARK_DATA="$T/a" bash -c 'source "'"$SRC"'/scripts/tools/_common.sh"; u=$(github_asset_url rhasspy/piper 2023.11.14-2 linux_aarch64.tar.gz); echo "URL=[$u]"' 2>&1)"
echo "$E" | grep -qi 'rate limit' && pass || fail "A6 a GitHub rate limit must be reported as such (got: $E)"
echo "$E" | grep -q 'URL=\[\]' && pass || fail "A6 no URL may be returned on an API error"
echo "$E" | grep -q 'GITHUB_TOKEN' && pass || fail "A6 the rate-limit message must tell the operator what to do (GITHUB_TOKEN)"
echo noasset > "$SHIM/mode"
E="$(PATH="$SHIM:$PATH" FORCE_COLOR=0 VAL_ARK_DATA="$T/a" bash -c 'source "'"$SRC"'/scripts/tools/_common.sh"; github_asset_url rhasspy/piper v1 linux_aarch64.tar.gz' 2>&1)"
echo "$E" | grep -qi 'no release asset matching' && pass || fail "A6 'release has no build for this arch' (aarch64) must be reported (got: $E)"

# A6b. git source: an auth-required / missing repo FAILS with its reason (and never waits at a prompt)
cat > "$SHIM/git" <<'EOF2'
#!/bin/bash
echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-unset}" >> "$(dirname "$0")/gitcalls"
echo "fatal: could not read Username for 'https://example.invalid': terminal prompts disabled" >&2; exit 128
EOF2
chmod +x "$SHIM/git"
G="$(PATH="$SHIM:$PATH" FORCE_COLOR=0 VAL_ARK_DATA="$T/a" bash -c 'source "'"$SRC"'/scripts/tools/_common.sh"; clone_repo https://example.invalid/r.git main "'"$T"'/a/clonedest" demo-repo; echo "rc=$?"' 2>&1)"
echo "$G" | grep -q 'rc=1' && pass || fail "A6b a failed git clone must return non-zero"
echo "$G" | grep -qi 'authentication required' && pass || fail "A6b the clone error must say authentication required (got: $(echo "$G" | tail -2 | tr '\n' ' '))"
grep -q 'GIT_TERMINAL_PROMPT=0' "$SHIM/gitcalls" && pass || fail "A6b git must run with GIT_TERMINAL_PROMPT=0 so it can never hang at a credentials prompt"

# A7. truthful exit status for a tool script (opt-in VALARK_STRICT_EXIT=1, set by run_tool)
mk_tool() {  # mk_tool <name> <body>
    printf '#!/bin/bash\nsource "%s/scripts/tools/_common.sh"\n%s\n' "$SRC" "$2" > "$T/a/$1.sh"
}
mk_tool allfail 'log_error "Could not find demo linux-arm64 asset"; log_success "Demo download complete"'
mk_tool partial 'DOWNLOAD_SUCCESS=1; log_error "Could not find demo linux-arm64 asset"; log_success "Demo download complete"'
mk_tool clean   'log_success "Demo download complete"'
VAL_ARK_DATA="$T/a" VALARK_STRICT_EXIT=1 FORCE_COLOR=0 bash "$T/a/allfail.sh" >/dev/null 2>&1; [ $? = 1 ] && pass || fail "A7 a run where every fetch failed must exit 1 under strict mode (it used to exit 0 = 'complete')"
VAL_ARK_DATA="$T/a" VALARK_STRICT_EXIT=1 FORCE_COLOR=0 bash "$T/a/partial.sh" >/dev/null 2>&1; [ $? = 0 ] && pass || fail "A7 a PARTIAL result (some platforms ok) must stay exit 0"
VAL_ARK_DATA="$T/a" VALARK_STRICT_EXIT=1 FORCE_COLOR=0 bash "$T/a/clean.sh" >/dev/null 2>&1; [ $? = 0 ] && pass || fail "A7 a clean run must exit 0"
VAL_ARK_DATA="$T/a" FORCE_COLOR=0 bash "$T/a/allfail.sh" >/dev/null 2>&1; [ $? = 0 ] && pass || fail "A7 without VALARK_STRICT_EXIT other callers keep their exit status"

fi

###############################################################################
# PART B — the server job layer, end to end, in a temp copy of scripts/
###############################################################################
if [[ "$PARTS" == *B* ]]; then
R="$T/repo"; mkdir -p "$R/scripts" "$R/tools" "$R/state"
cp -r "$SRC/scripts/." "$R/scripts/"; cp "$SRC/VERSION" "$R/VERSION" 2>/dev/null
rm -rf "${R:?}/scripts/node_modules" 2>/dev/null
# Stub tool scripts: each is a scenario the web UI must report truthfully.
tool_stub() { printf '#!/bin/bash\nsource "$(dirname "$0")/_common.sh"\n%s\n' "$2" > "$R/scripts/tools/$1.sh"; }
PLAT="$R/tools/linux-x86_64"
# wrapped layout exactly like piper: tools/<plat>/<tool>/<tool>/<files>
tool_stub zzwrapped 'd="${TOOLS_DIR}/linux-x86_64/zzwrapped"
if [ -f "$d/zzwrapped/zzwrapped" ]; then log_info "Already extracted: zzwrapped - skipping"; DOWNLOAD_SKIPPED=1; log_success "zzwrapped download complete"; exit 0; fi
mkdir -p "$d/zzwrapped" "$d/.dist"; head -c 120000 /dev/urandom > "$d/zzwrapped/zzwrapped"; echo hi > "$d/zzwrapped/README"
( cd "$d" && tar -czf .dist/zzwrapped.tar.gz zzwrapped ); log_success "Extracted: zzwrapped"; log_success "zzwrapped download complete"'
# exits 0, mirrored NOTHING, says "complete" — the silent failure class
tool_stub zzsilent 'log_warn "No linux-arm64 asset found for zzsilent v1"; log_success "zzsilent download complete"'
# one platform fine, another has no upstream build
tool_stub zzpartial 'd="${TOOLS_DIR}/linux-x86_64/zzpartial"; mkdir -p "$d"; head -c 120000 /dev/urandom > "$d/zzpartial"; DOWNLOAD_SUCCESS=1
log_warn "No linux-arm64 asset found for zzpartial v1"; log_success "zzpartial download complete"'
tool_stub zzcrash 'echo "INFO: working"; sleep 0.3; kill -9 $$'
tool_stub zzfail 'log_error "FAILED: zzfail linux-x86_64: HTTP 404 - not found upstream (https://example.invalid/x)"; exit 1'
tool_stub zzstall 'echo "INFO: connecting"; sleep 60'
tool_stub zzbusy 'echo "WARN: busy"; exit 75'
tool_stub zzcorrupt 'd="${TOOLS_DIR}/linux-x86_64/zzcorrupt"; mkdir -p "$d/.dist"; head -c 120000 /dev/urandom > "$d/zzcorrupt"; head -c 5000 /dev/urandom > "$d/.dist/zzcorrupt.tar.gz"; log_success "Extracted: zzcorrupt"'
# a download whose .part grows for real: 4 MB announced, written 1 MB per tick
tool_stub zzslow 'd="${TOOLS_DIR}/linux-x86_64/zzslow"; mkdir -p "$d"; part="$d/zzslow.bin.part"
printf "@@valark-dl\t4194304\t%s\t0\tzzslow linux-x86_64\n" "$part"
for i in 1 2 3 4; do head -c 1048576 /dev/zero >> "$part"; echo "INFO: chunk $i"; sleep 1.2; done
mv "$part" "$d/zzslow.bin"; head -c 120000 /dev/urandom > "$d/zzslow"; log_success "Downloaded: zzslow linux-x86_64"'

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
B="http://127.0.0.1:$PORT"
start_server() {
    ( VAL_ARK_DATA="$R" VALARK_COMMISSIONED=1 VALARK_DISABLE_KIWIX=1 VALARK_BIND=127.0.0.1 VALARK_WEB_PORT="$PORT" \
      VALARK_HTTPS_PORT=$((PORT+1)) VALARK_JOB_STALL_SEC=3 VALARK_JOB_POLL_MS=200 VALARK_TEST_NO_SPAWN=1 \
      "$NODE" "$R/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 & echo $! > "$T/srv.pid" )
    SRV_PID="$(cat "$T/srv.pid")"
    local up=0 i; for i in $(seq 1 40); do sleep 0.25; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
    [ "$up" = 1 ]
}
start_server && pass || { fail "B0 sandbox server did not start (see $T/srv.log)"; cat "$T/srv.log" >&2; echo "mirror-honesty: ${PASS} passed, ${FAIL} failed"; exit 1; }

post() { curl -s --max-time 10 -X POST -H 'content-type: application/json' -d "$2" "$B$1"; }
start_tool() { post /api/download/tools "{\"target\":\"$1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'; }
# wait_job <id> <secs> -> prints final status (bounded)
wait_job() {
    local id="$1" n=$(( $2 * 5 )) i st
    for i in $(seq 1 "$n"); do
        curl -s --max-time 5 "$B/api/status/downloads" > "$T/jobs.json"
        st="$(jget "$T/jobs.json" "d.get('$id',{}).get('status','')")"
        case "$st" in running|queued|"") sleep 0.2 ;; *) echo "$st"; return 0 ;; esac
    done
    echo "TIMEOUT:$st"
}
job() { curl -s --max-time 5 "$B/api/status/downloads" > "$T/jobs.json"; jget "$T/jobs.json" "d['$1']$2"; }

# B1. THE piper bug: a successful mirror whose files sit in a wrapper dir must be seen as
#     mirrored (it used to be 'empty' -> "Not Mirrored" forever) and the job must say what it did.
id=$(start_tool zzwrapped); st=$(wait_job "$id" 20)
[ "$st" = complete ] && pass || fail "B1 wrapped-layout mirror must end 'complete' (got $st; $(job "$id" "['error']"))"
curl -s "$B/api/status/tools" > "$T/tools.json"
ct="$(jget "$T/tools.json" "d['zzwrapped']['linux-x86_64']['contentType']")"
[ "$ct" = binary ] && pass || fail "B1 the status scan must see through the wrapper dir (contentType=$ct, want binary — this is the piper-tts bug)"
job "$id" "['outcome']['summary']" | grep -q 'Mirrored linux-x86_64.*verified' && pass || fail "B1 the job must report what was mirrored + verified (got: $(job "$id" "['outcome']['summary']"))"
[ "$(job "$id" "['outcome']['platforms'][1]['verified']")" = True ] && pass || fail "B1 the mirrored archive must be integrity-checked (verified=true)"
# ...and a re-click on an already-mirrored tool says so instead of pretending to download
id=$(start_tool zzwrapped); st=$(wait_job "$id" 20)
[ "$st" = complete ] && job "$id" "['outcome']['summary']" | grep -qi 'already mirrored' && pass || fail "B1 re-mirroring an up-to-date tool must say 'Already mirrored' (got $st: $(job "$id" "['outcome']['summary']"))"

# B2. exit 0 but NOTHING mirrored is a failure with the script's own reason (never 'complete')
id=$(start_tool zzsilent); st=$(wait_job "$id" 20)
[ "$st" = failed ] && pass || fail "B2 a run that mirrored nothing must be 'failed', not '$st'"
job "$id" "['error']" | grep -qi 'nothing was mirrored' && pass || fail "B2 the error must say nothing was mirrored (got: $(job "$id" "['error']"))"
job "$id" "['error']" | grep -q 'No linux-arm64 asset' && pass || fail "B2 the error must carry the script's reason (wrong-arch: no linux-arm64 asset) (got: $(job "$id" "['error']"))"

# B3. partial: complete, with a visible per-platform warning naming the arch that is missing
id=$(start_tool zzpartial); st=$(wait_job "$id" 20)
[ "$st" = complete ] && pass || fail "B3 a partial mirror must end 'complete' with warnings (got $st)"
job "$id" "['warnings']" | grep -q 'linux-arm64' && pass || fail "B3 the missing aarch64 platform must be listed as a warning (got: $(job "$id" "['warnings']"))"

# B4. crash (SIGKILL) -> failed with a reason, not 'complete' and not stuck 'running'
id=$(start_tool zzcrash); st=$(wait_job "$id" 20)
[ "$st" = failed ] && pass || fail "B4 a killed job must be 'failed' (got $st)"
job "$id" "['error']" | grep -q 'SIGKILL' && pass || fail "B4 the reason must name the signal (got: $(job "$id" "['error']"))"

# B5. non-zero exit -> failed with the script's most informative error line
id=$(start_tool zzfail); st=$(wait_job "$id" 20)
[ "$st" = failed ] && job "$id" "['error']" | grep -q 'HTTP 404' && pass || fail "B5 a failing script must surface its reason ('HTTP 404'), got $st: $(job "$id" "['error']")"
[ "$(job "$id" "['retryable']")" = True ] && pass || fail "B5 a failed job must be retryable"

# B6. stall: no output and no byte growth -> killed with a 'Stalled' reason (no-progress timeout)
id=$(start_tool zzstall); st=$(wait_job "$id" 25)
[ "$st" = failed ] && job "$id" "['error']" | grep -q 'Stalled' && pass || fail "B6 a stalled job must fail as 'Stalled: no download progress…' (got $st: $(job "$id" "['error']"))"

# B7. exit 75 (busy) is NOT success
id=$(start_tool zzbusy); st=$(wait_job "$id" 20)
[ "$st" = deferred ] && pass || fail "B7 'busy' (exit 75) must be 'deferred', not '$st'"

# B8. a corrupt archive fails verification instead of showing 'Mirrored'
id=$(start_tool zzcorrupt); st=$(wait_job "$id" 20)
[ "$st" = failed ] && job "$id" "['error']" | grep -qi 'verification failed' && pass || fail "B8 a truncated archive must fail verification (got $st: $(job "$id" "['error']"))"

# B9. real bytes: the percent comes from the growing .part file, never a guess
id=$(start_tool zzslow); sleep 2.4
curl -s "$B/api/status/downloads" > "$T/jobs.json"
p="$(jget "$T/jobs.json" "d['$id']['progress']")"; by="$(jget "$T/jobs.json" "d['$id']['bytes']")"; tot="$(jget "$T/jobs.json" "d['$id']['total']")"
[ "$tot" = 4194304 ] && pass || fail "B9 total must be the announced size (got $tot)"
case "$p" in 25|50|75) pass ;; *) fail "B9 mid-download progress must be the measured part-file fraction (got $p%, bytes=$by)" ;; esac
[ "$by" -gt 0 ] 2>/dev/null && [ "$by" -lt 4194304 ] && pass || fail "B9 mid-download bytes must be partial and real (got $by)"
st=$(wait_job "$id" 20); [ "$st" = complete ] && [ "$(job "$id" "['progress']")" = 100 ] && pass || fail "B9 must complete at 100% (got $st)"

# B10. cancel: ends 'cancelled' (it used to be overwritten to 'failed' by its own exit)
id=$(start_tool zzstall)
sleep 0.5; post /api/download/cancel "{\"id\":\"$id\"}" > "$T/c.json"
st=$(wait_job "$id" 20); [ "$st" = cancelled ] && pass || fail "B10 a cancelled job must end 'cancelled' (got $st)"

# B11. Retry restarts EXACTLY the job that failed (it used to restart '<type> all')
failid=$(start_tool zzfail); wait_job "$failid" 20 >/dev/null
post /api/download/retry "{\"id\":\"$failid\"}" > "$T/r.json"
rid="$(jget "$T/r.json" "d.get('id','')")"
[ -n "$rid" ] && [ "$rid" != "$failid" ] && pass || fail "B11 retry must start a new job (got: $(cat "$T/r.json"))"
wait_job "$rid" 20 >/dev/null
[ "$(job "$rid" "['target']")" = zzfail ] && pass || fail "B11 retry must re-run the SAME target (got target=$(job "$rid" "['target']"))"
[ -z "$(job "$failid" "['status']")" ] && pass || fail "B11 the superseded failed job must disappear when its retry starts (no stale failed card beside the new run)"
cid=$(start_tool zzwrapped); wait_job "$cid" 20 >/dev/null
post /api/download/retry "{\"id\":\"$cid\"}" > "$T/r2.json"
grep -q 'error' "$T/r2.json" && pass || fail "B11 retrying a job that is not failed/cancelled/deferred must be refused (got: $(cat "$T/r2.json"))"

# B12. same target twice = attach to the running job; a different target queues (no scary error)
a=$(start_tool zzslow); sleep 0.3; a2=$(start_tool zzslow)
[ "$a" = "$a2" ] && pass || fail "B12 a second click on a running mirror must attach to it (ids $a vs $a2)"
b=$(start_tool zzwrapped); sleep 0.3
[ "$(job "$b" "['status']")" = queued ] && pass || fail "B12 a different tool must queue behind the running one (status $(job "$b" "['status']"))"
wait_job "$a" 25 >/dev/null; st=$(wait_job "$b" 25)
[ "$st" = complete ] && pass || fail "B12 the queued job must run after the first finishes (got $st)"

# B13. SSE: a (re)connecting client gets the FULL job snapshot, so a dropped stream re-syncs
curl -sN --max-time 2 "$B/api/downloads/stream" 2>/dev/null | head -c 60000 > "$T/sse.txt"
grep -q '^event: init' "$T/sse.txt" && grep -q '"jobs":{' "$T/sse.txt" && grep -q 'zzwrapped' "$T/sse.txt" && pass || fail "B13 SSE init must carry the job snapshot (got: $(head -c 200 "$T/sse.txt"))"

# B13b. Library "Mirror" on an unknown/typo'd content id must FAIL with its reason — it used to be
#       ignored and the script started downloading the WHOLE catalog (incl. 111 GB Wikipedia)
id=$(post /api/download/content '{"target":"no-such-zim"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'); st=$(wait_job "$id" 20)
[ "$st" = failed ] && job "$id" "['error']" | grep -q 'Unknown content target' && pass || fail "B13b an unknown content id must fail visibly (got $st: $(job "$id" "['error']"))"

# B14. server restart mid-job: history survives, the interrupted job is reported FAILED (not 'running' forever)
id=$(start_tool zzstall); sleep 0.6
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
# the job's process group would be orphaned; the new server must still report it honestly
start_server && pass || fail "B14 server restart failed"
st="$(job "$id" "['status']")"
[ "$st" = failed ] && job "$id" "['error']" | grep -qi 'restarted' && pass || fail "B14 a job interrupted by a restart must be 'failed: ... restarted' (got $st: $(job "$id" "['error']"))"
[ "$(job "$b" "['status']")" = complete ] && pass || fail "B14 finished-job history must survive a restart (job $b: $(job "$b" "['status']"))"
pkill_orphans() { :; }   # (the orphaned zzstall sleeps 60s and exits on its own; we never pkill by pattern)

fi

echo "mirror-honesty: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
