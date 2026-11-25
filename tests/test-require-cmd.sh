#!/bin/bash
###############################################################################
# Test: runtime guards skip locally but FAIL under CI when python3 / node is missing (#255, #286).
#
#   1. tests/lib/require-cmd.sh itself: ci_is_set truth table (unset, '', false/0/no/off in any
#      case = not CI; true/1/yes/anything else = CI), require_cmd / missing_cmd exit codes.
#   2. Every tests/test-*.sh that calls require_python3 is run with a PATH that holds every
#      command except python3 (HOME pointed at the sandbox): it must skip when CI is unset or
#      false-ish and fail when CI is set.
#   3. Same for every whole-file node guard (require_cmd node / missing_cmd node), on a PATH with
#      everything except node; test-catalog-cache.sh (a per-case node skip) is run in full.
#   4. Lint: a test-*.sh that probes python3 or node must use the helper, so a new bare
#      "SKIP ... exit 0" guard can't quietly reintroduce the hole.
# Offline; bash + coreutils.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
BASH_BIN="$(command -v bash)"
SELF="$ROOT/tests/test-require-cmd.sh"

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT

# --- 1. the helper on its own -------------------------------------------------------------
probe() {   # probe CI_STATE -> "ci" / "local"; CI_STATE "-" = CI unset
    if [ "$1" = - ]; then
        env -u CI "$BASH_BIN" -c ". '$ROOT/tests/lib/require-cmd.sh'; ci_is_set && echo ci || echo local"
    else
        env CI="$1" "$BASH_BIN" -c ". '$ROOT/tests/lib/require-cmd.sh'; ci_is_set && echo ci || echo local"
    fi
}
for v in - '' false FALSE False 0 no NO off Off; do
    [ "$(probe "$v")" = local ] && pass || fail "ci_is_set: CI='$v' must count as not CI"
done
for v in true TRUE 1 yes on github; do
    [ "$(probe "$v")" = ci ] && pass || fail "ci_is_set: CI='$v' must count as CI"
done
env -u CI "$BASH_BIN" -c ". '$ROOT/tests/lib/require-cmd.sh'; require_cmd valark-no-such-cmd x; exit 7" >/dev/null 2>&1
[ $? = 0 ] && pass || fail "require_cmd: a missing command skips (exit 0) without CI"
env CI=true "$BASH_BIN" -c ". '$ROOT/tests/lib/require-cmd.sh'; require_cmd valark-no-such-cmd x; exit 7" >/dev/null 2>&1
[ $? = 1 ] && pass || fail "require_cmd: a missing command fails (exit 1) under CI"
env CI=true "$BASH_BIN" -c ". '$ROOT/tests/lib/require-cmd.sh'; require_cmd bash x; exit 7" >/dev/null 2>&1
[ $? = 7 ] && pass || fail "require_cmd: a present command returns and the script carries on"

# --- sandboxes: every command on PATH except the one under test ----------------------------
farm() {   # farm DIR EXCLUDE_REGEX
    mkdir -p "$1"
    local d f n IFS=:
    for d in $PATH; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n="${f##*/}"
            [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$1/$n" ] || continue
            [[ "$n" =~ $2 ]] && continue
            ln -s "$f" "$1/$n" 2>/dev/null
        done
    done
}
farm "$T/nopy" '^python'
farm "$T/nonode" '^(node|nodejs)$'
for sb in nopy:python3 nonode:node; do
    if env -i PATH="$T/${sb%%:*}" "$BASH_BIN" -c "command -v ${sb#*:}" >/dev/null 2>&1; then
        echo "FAIL: sandbox ${sb%%:*} still resolves ${sb#*:}" >&2; exit 1
    fi
done
mkdir -p "$T/home"

# run SANDBOX SCRIPT CI_STATE -> RC + OUT; CI_STATE "-" leaves CI unset
run() {
    if [ "$3" = - ]; then OUT="$(env -i PATH="$T/$1" HOME="$T/home" "$BASH_BIN" "$2" 2>&1)"; RC=$?
    else OUT="$(env -i PATH="$T/$1" HOME="$T/home" CI="$3" "$BASH_BIN" "$2" 2>&1)"; RC=$?; fi
}
expect_guard() {   # expect_guard SANDBOX CMD SCRIPT
    local b ci; b="$(basename "$3")"
    for ci in - '' false; do
        run "$1" "$3" "$ci"
        if [ "$RC" = 0 ] && grep -q "^SKIP: $2 not found" <<<"$OUT"; then pass
        else fail "$b with CI='$ci' and no $2 should skip (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    done
    for ci in true 1; do
        run "$1" "$3" "$ci"
        if [ "$RC" = 1 ] && grep -q "^FAIL: $2 not found under CI" <<<"$OUT"; then pass
        else fail "$b with CI=$ci and no $2 should fail (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    done
}

# --- 2. python3 guards ----------------------------------------------------------------------
npy=0
for f in "$ROOT"/tests/test-*.sh; do
    [ "$f" = "$SELF" ] && continue
    grep -q '^[^#]*require_python3 ' "$f" || continue
    npy=$((npy + 1)); expect_guard nopy python3 "$f"
done
for b in test-doc-links.sh test-doc-art.sh test-secrets.sh; do
    grep -q '^[^#]*require_python3 ' "$ROOT/tests/$b" && pass || fail "$b does not use require_python3"
done

# --- 3. node guards -------------------------------------------------------------------------
nnode=0
for f in "$ROOT"/tests/test-*.sh; do
    [ "$f" = "$SELF" ] && continue
    grep -qE '^[^#]*(require_cmd|missing_cmd) node ' "$f" || continue
    nnode=$((nnode + 1)); expect_guard nonode node "$f"
done
for b in test-playwright-runner.sh test-mirror-honesty.sh; do
    grep -qE '^[^#]*(require_cmd|missing_cmd) node ' "$ROOT/tests/$b" && pass || fail "$b does not guard node with the helper"
done
# a per-case node skip: the whole file runs, only that case skips locally / fails under CI
run nonode "$ROOT/tests/test-catalog-cache.sh" -
if [ "$RC" = 0 ] && grep -q "SKIP: no node runtime — parseCatalogTSV" <<<"$OUT"; then pass
else fail "test-catalog-cache.sh without node, CI unset: should pass with the case skipped (rc=$RC): $(tail -1 <<<"$OUT")"; fi
run nonode "$ROOT/tests/test-catalog-cache.sh" true
if [ "$RC" != 0 ] && grep -q "FAIL: parseCatalogTSV filter case needs node" <<<"$OUT"; then pass
else fail "test-catalog-cache.sh without node, CI=true: should fail (rc=$RC): $(tail -1 <<<"$OUT")"; fi

[ "$npy" -ge 10 ] && pass || fail "expected the python3 validators to use require_python3, found $npy"
[ "$nnode" -ge 10 ] && pass || fail "expected the node validators to use the node guard, found $nnode"

# --- 4. lint: probing python3 / node means using the helper --------------------------------
bare=""
for f in "$ROOT"/tests/test-*.sh; do
    [ "$f" = "$SELF" ] && continue
    b="$(basename "$f")"
    if grep -q 'command -v python3' "$f" && ! grep -qE '^[^#]*(require_python3|(require_cmd|missing_cmd) python3) ' "$f"; then
        bare="${bare}${bare:+$'\n'}$b: probes python3 without require_python3"
    fi
    # a node SKIP that is not tied to the helper (whole-file guard or a ci_is_set case)
    if grep -qiE 'SKIP[^"]*(no node|node required|\(no node)' "$f" && ! grep -qE '^[^#]*(require_cmd node|missing_cmd node|ci_is_set)' "$f"; then
        bare="${bare}${bare:+$'\n'}$b: skips on missing node without the helper"
    fi
    if grep -qE 'SKIP[^"]*(python3|no node)[^}]*exit 0' "$f"; then
        bare="${bare}${bare:+$'\n'}$b: bare one-line SKIP ... exit 0 runtime guard"
    fi
done
if [ -z "$bare" ]; then pass; else fail "bare runtime guards (use tests/lib/require-cmd.sh):"$'\n'"$bare"; fi

echo "require-cmd: $PASS passed, $FAIL failed ($npy python3 + $nnode node guarded validators)"
[ "$FAIL" -eq 0 ]
