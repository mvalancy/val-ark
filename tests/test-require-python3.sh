#!/bin/bash
###############################################################################
# Test: python-based validators skip locally but FAIL under CI without python3 (#255).
#
# Runs every tests/test-*.sh that uses tests/lib/require-python3.sh with a PATH holding no
# python3 (only `dirname`): with CI unset / CI=false it must skip (exit 0, "SKIP:"), with
# CI=true it must fail (exit 1, "FAIL:"). Also lints that no validator still carries a bare
# "SKIP ... python3 ... exit 0" guard, so a new one can't quietly reintroduce the hole.
# Offline; needs only bash + coreutils.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
BASH_BIN="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin"; ln -s "$(command -v dirname)" "$T/bin/dirname"
[ -x "$T/bin/python3" ] && { echo "FAIL: sandbox PATH unexpectedly has python3" >&2; exit 1; }

# run SCRIPT CI_VALUE -> sets RC + OUT
run() { OUT="$(env -i PATH="$T/bin" HOME="$T" CI="$2" "$BASH_BIN" "$1" 2>&1)"; RC=$?; }

n=0
for f in "$ROOT"/tests/test-*.sh; do
    [ "$f" = "$ROOT/tests/test-require-python3.sh" ] && continue
    grep -q '^[^#]*require_python3 ' "$f" || continue
    n=$((n + 1)); b="$(basename "$f")"
    for ci in "" false; do
        run "$f" "$ci"
        if [ "$RC" = 0 ] && grep -q '^SKIP: python3 not found' <<<"$OUT"; then pass
        else fail "$b with CI='$ci' and no python3 should skip (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    done
    run "$f" true
    if [ "$RC" = 1 ] && grep -q '^FAIL: python3 not found under CI' <<<"$OUT"; then pass
    else fail "$b with CI=true and no python3 should fail (rc=$RC): $(tail -1 <<<"$OUT")"; fi
done
# the guards #255 names must be among them
for b in test-doc-links.sh test-doc-art.sh test-secrets.sh; do
    if grep -q '^[^#]*require_python3 ' "$ROOT/tests/$b"; then pass; else fail "$b does not use require_python3"; fi
done
[ "$n" -ge 3 ] && pass || fail "expected several require_python3 users, found $n"

# lint: no other bare python3 skip-with-exit-0 guard left behind
bare="$(grep -lE 'command -v python3[^|]*\|\|[^}]*exit 0' "$ROOT"/tests/test-*.sh 2>/dev/null)"
bare="$bare$(grep -lE 'SKIP: python3 not found' "$ROOT"/tests/test-*.sh 2>/dev/null | grep -v "$(basename "${BASH_SOURCE[0]}")")"
if [ -z "$bare" ]; then pass; else fail "bare python3 skip guard (use tests/lib/require-python3.sh): $bare"; fi

echo "require-python3: $PASS passed, $FAIL failed ($n guarded validators)"
[ "$FAIL" -eq 0 ]
