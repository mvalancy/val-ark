#!/bin/bash
# Offline regression: a launched browser tier must never disappear from the gate.
# Stub Playwright and curl; run the real runner/converter/HTML generator in a sandbox.
set -o pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE="$(command -v node)" || { echo 'SKIP: node required for browser-report regression'; exit 0; }
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tests/lib" "$T/tests/report" "$T/tests/screenshots/node_modules/.bin" "$T/bin"
cp "$TEST_DIR/run-all.sh" "$T/tests/"
cp "$TEST_DIR/lib/results.sh" "$T/tests/lib/"
cp "$TEST_DIR/report/"{from-playwright,generate}.mjs "$T/tests/report/"
ln -s "$NODE" "$T/bin/node"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/tests/test-pass.sh"
cat > "$T/tests/screenshots/node_modules/.bin/playwright" <<'STUB'
#!/bin/bash
if [ "$PW_CASE" != missing ]; then
    cp "$PW_FIXTURE" "$PLAYWRIGHT_JSON_OUTPUT_NAME"
fi
printf 'stub browser diagnostic\n'
exit "$PW_EXIT"
STUB
chmod +x "$T/bin/curl" "$T/tests/screenshots/node_modules/.bin/playwright"
cat > "$T/pass.json" <<'JSON'
{"suites":[{"file":"smoke.spec.ts","specs":[{"title":"page renders","tests":[{"status":"expected","results":[{"status":"passed","duration":1}]}]}]}],"errors":[]}
JSON
printf '{"suites":[],"errors":[]}' > "$T/empty.json"
printf '{"suites":[],"errors":[{"message":"collection failed"}]}' > "$T/global.json"
printf 'broken JSON' > "$T/malformed.json"
python3 - "$T" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); data=json.loads((p/'pass.json').read_text())
data['errors']=[{'message':'teardown failed'}]
(p/'global-with-pass.json').write_text(json.dumps(data))
data['errors']=[];data['suites'][0]['specs'][0]['tests'][0]['status']='unexpected'
(p/'failed-test.json').write_text(json.dumps(data))
PY
PASS=0; FAIL=0
check_run() { # name, fixture, process exit, expected runner exit (zero/nonzero), mode
    local name="$1" fixture="$2" exit_code="$3" expected="$4" mode="${5:-report}" rc
    HOME="$T" PATH="$T/bin:$PATH" VALARK_NO_PLAYWRIGHT=0 VALARK_RUN_VM=0 \
        PW_CASE="$mode" PW_FIXTURE="$T/$fixture.json" PW_EXIT="$exit_code" \
        bash "$T/tests/run-all.sh" > "$T/output" 2>&1
    rc=$?
    if { [ "$expected" = zero ] && [ "$rc" -eq 0 ]; } || { [ "$expected" = nonzero ] && [ "$rc" -ne 0 ]; }; then
        PASS=$((PASS+1))
    else
        echo "FAIL: $name returned $rc (expected $expected)" >&2; FAIL=$((FAIL+1))
    fi
    # Errors must be visible in the saved report, not just the process exit code.
    if python3 - "$T/tests/results" "$expected" <<'PY'
import json,pathlib,sys
reports=[json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob('*.json') if not p.name.startswith('.')]
failed=sum(r.get('summary',{}).get('failed',0) for r in reports)
assert (failed>0)==(sys.argv[2]=='nonzero'),f'failed cases: {failed}'
PY
    then PASS=$((PASS+1)); else echo "FAIL: $name report evidence" >&2; FAIL=$((FAIL+1)); fi
}
check_run 'missing JSON with failing process' pass 1 nonzero missing
check_run 'missing JSON with successful process' pass 0 nonzero missing
check_run 'malformed JSON' malformed 0 nonzero
check_run 'empty report' empty 0 nonzero
check_run 'global collection failure' global 0 nonzero
check_run 'global error alongside passing tests' global-with-pass 0 nonzero
check_run 'nonzero process despite passing report' pass 1 nonzero
check_run 'failed test despite zero process' failed-test 0 nonzero
check_run 'complete successful report' pass 0 zero
# A stale hidden report must not rescue the next missing-output run.
cp "$T/pass.json" "$T/tests/results/.playwright.json"
check_run 'stale report followed by no output' pass 0 nonzero missing
if [ -f "$T/tests/results/playwright.log" ] && grep -q 'stub browser diagnostic' "$T/tests/results/playwright.log"; then
    PASS=$((PASS+1))
else echo 'FAIL: browser diagnostic log not retained' >&2; FAIL=$((FAIL+1)); fi
printf 'playwright-runner: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
