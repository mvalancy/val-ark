#!/bin/bash
###############################################################################
# Test: run-all.sh exit code without node (issue #49) — sandboxed.
#
# On a host with no node (fresh appliance / minimal container) the runner
# used to hard-code RC=0 on the "cannot render HTML report" path, silencing
# every suite's failures and falsely satisfying the "green tests/run-all.sh"
# gate. This copies run-all.sh + lib/results.sh into a sandbox with stub
# validators and runs it with a node-free PATH shim and a neutralized HOME,
# asserting:
#   * a failing validator  => non-zero exit even though node is unavailable
#   * all validators green => exit 0 as before
# No network requests; the services e2e probe points at a closed local port.
###############################################################################

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TPASS=0
TFAIL=0

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# Sandbox layout: <tmp>/tests/{run-all.sh,lib/results.sh,test-*.sh stubs}
mkdir -p "$SANDBOX/tests/lib" "$SANDBOX/bin"
cp "$TEST_DIR/run-all.sh" "$SANDBOX/tests/run-all.sh"
cp "$TEST_DIR/lib/results.sh" "$SANDBOX/tests/lib/results.sh"

# PATH shim WITHOUT node (python3 also omitted — results.sh has a sed/tr
# fallback), so the nested runner exercises the no-node report path.
for c in bash date mkdir rm basename dirname sed grep curl tr tail cat; do
    src="$(command -v "$c")" || { echo "SKIP: '$c' unavailable" >&2; exit 0; }
    ln -s "$src" "$SANDBOX/bin/$c"
done

printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/tests/test-aa-pass.sh"
printf '#!/bin/bash\necho boom >&2\nexit 1\n' > "$SANDBOX/tests/test-zz-fail.sh"

OUT_FILE="$SANDBOX/out.txt"
run_sandboxed() {
    HOME="$SANDBOX" PATH="$SANDBOX/bin" \
        VALARK_NO_PLAYWRIGHT=1 VALARK_RUN_VM=0 VALARK_URL="http://127.0.0.1:9" \
        bash "$SANDBOX/tests/run-all.sh" > "$OUT_FILE" 2>&1
}

expect() {  # <desc> <ok:0|1>
    if [ "$2" = "0" ]; then TPASS=$((TPASS + 1))
    else echo "FAIL: $1" >&2; sed 's/^/    | /' "$OUT_FILE" >&2; TFAIL=$((TFAIL + 1)); fi
}

# 1. A failing validator must red the runner even without node.
run_sandboxed; rc=$?
expect "no-node runner took the no-report path" "$(grep -q 'node not found' "$OUT_FILE"; echo $?)"
expect "no-node runner recorded the failing case" "$(grep -q '\[FAIL\] zz-fail' "$OUT_FILE"; echo $?)"
expect "no-node runner exits non-zero on validator failure (got rc=$rc)" "$([ "$rc" -ne 0 ]; echo $?)"

# 2. All-green validators still exit 0 without node.
rm "$SANDBOX/tests/test-zz-fail.sh"
run_sandboxed; rc=$?
expect "no-node runner took the no-report path (green run)" "$(grep -q 'node not found' "$OUT_FILE"; echo $?)"
expect "no-node runner exits 0 when all validators pass (got rc=$rc)" "$([ "$rc" -eq 0 ]; echo $?)"

echo "runner-exit: ${TPASS} passed, ${TFAIL} failed"
[ "$TFAIL" -eq 0 ] && exit 0 || exit 1
