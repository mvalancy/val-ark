#!/bin/bash
###############################################################################
# Test: a missing command skips locally but FAILS under CI (#255, #286).
#
#   1. tests/lib/require-cmd.sh itself: ci_is_set truth table (unset, '', false/0/no/off in any
#      case = not CI; true/1/yes/anything else = CI), require_cmd / missing_cmd exit codes.
#   2. Every literal guard in tests/test-*.sh (require_python3, require_cmd <cmd>,
#      missing_cmd <cmd>) is exercised: the test runs on a PATH holding every command except that
#      one (HOME pointed at the sandbox) and must skip when CI is unset / empty / false and fail
#      when CI=true / CI=1.
#   3. Per-case skips run in full without their command: test-catalog-cache.sh (node) and
#      test-static-site.sh (zstd) pass with the case skipped locally and fail under CI.
#   4. Lint, on the real tests and on fixtures that must be caught: every skip-shaped line
#      (`echo "SKIP:`, `printf 'SKIP`, `|| exit 0`, `|| { …; exit 0; }`) needs `ci_is_set` in code
#      (not a comment) on that line or the one before, or -- only in a test on SKIP_OK_FILES -- a
#      `# ci-skip-ok: <non-empty why>` comment; a test that runs python3 calls require_python3; a
#      test that resolves node guards it. ci.yml pins CPython 3.12 (test-cad-agent.sh needs it, #315).
# Offline; bash + coreutils.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
BASH_BIN="$(command -v bash)"
SELF="$ROOT/tests/test-require-cmd.sh"
HELPER="$ROOT/tests/lib/require-cmd.sh"

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT

# --- 1. the helper on its own -------------------------------------------------------------
probe() {   # probe CI_STATE -> "ci" / "local"; CI_STATE "-" = CI unset
    if [ "$1" = - ]; then env -u CI "$BASH_BIN" -c ". '$HELPER'; ci_is_set && echo ci || echo local"
    else env CI="$1" "$BASH_BIN" -c ". '$HELPER'; ci_is_set && echo ci || echo local"; fi
}
for v in - '' false FALSE False fAlSe 0 no NO No off Off OFF; do
    [ "$(probe "$v")" = local ] && pass || fail "ci_is_set: CI='$v' must count as not CI"
done
for v in true TRUE 1 yes on github falsey 00; do
    [ "$(probe "$v")" = ci ] && pass || fail "ci_is_set: CI='$v' must count as CI"
done
grep -q '^[^#]*\${CI,,}' "$HELPER" && fail "require-cmd.sh must stay bash-3 safe (no \${CI,,})" || pass
env -u CI "$BASH_BIN" -c ". '$HELPER'; require_cmd valark-no-such-cmd x; exit 7" >/dev/null 2>&1
[ $? = 0 ] && pass || fail "require_cmd: a missing command skips (exit 0) without CI"
env CI=true "$BASH_BIN" -c ". '$HELPER'; require_cmd valark-no-such-cmd x; exit 7" >/dev/null 2>&1
[ $? = 1 ] && pass || fail "require_cmd: a missing command fails (exit 1) under CI"
env CI=true "$BASH_BIN" -c ". '$HELPER'; require_cmd bash x; exit 7" >/dev/null 2>&1
[ $? = 7 ] && pass || fail "require_cmd: a present command returns and the script carries on"

# --- sandboxes: every command on PATH except one -------------------------------------------
REAL_NODE="$HOME/.local/node/bin/node"; [ -x "$REAL_NODE" ] || REAL_NODE=""
excluded() {   # excluded CMD NAME: is NAME hidden from the sandbox that lacks CMD?
    case "$1" in
        python3) [[ "$2" == python* ]] ;;
        node)    [ "$2" = node ] || [ "$2" = nodejs ] ;;
        *)       [ "$2" = "$1" ] ;;
    esac
}
BASE="$T/base"; mkdir -p "$BASE"
( IFS=:; for d in $PATH; do       # every command on PATH, first one wins (as PATH lookup does)
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="${f##*/}"
        [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$BASE/$n" ] && ln -s "$f" "$BASE/$n" 2>/dev/null
    done
done )
# tests also look in ~/.local/node; HOME is the sandbox, so put that node on PATH instead
[ -n "$REAL_NODE" ] && [ ! -e "$BASE/node" ] && ln -s "$REAL_NODE" "$BASE/node"
farm() {   # farm CMD -> prints the sandbox bin dir: the base minus CMD (built once per CMD)
    local dir="$T/no-$1" f
    if [ ! -d "$dir" ]; then
        cp -a "$BASE" "$dir"
        for f in "$dir"/*; do excluded "$1" "${f##*/}" && rm -f "$f"; done
    fi
    echo "$dir"
}
mkdir -p "$T/home"

# run CMD SCRIPT CI_STATE -> RC + OUT; CI_STATE "-" leaves CI unset
run() {
    local bin; bin="$(farm "$1")"
    if env -i PATH="$bin" "$BASH_BIN" -c "command -v $1" >/dev/null 2>&1; then
        RC=99; OUT="sandbox still resolves $1"; return
    fi
    if [ "$3" = - ]; then OUT="$(env -i PATH="$bin" HOME="$T/home" "$BASH_BIN" "$2" 2>&1)"; RC=$?
    else OUT="$(env -i PATH="$bin" HOME="$T/home" CI="$3" "$BASH_BIN" "$2" 2>&1)"; RC=$?; fi
}
expect_guard() {   # expect_guard CMD SCRIPT
    local b ci; b="$(basename "$2")"
    for ci in - '' false; do
        run "$1" "$2" "$ci"
        if [ "$RC" = 0 ] && grep -q "^SKIP: $1 not found" <<<"$OUT"; then pass
        else fail "$b with CI='$ci' and no $1 should skip (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    done
    for ci in true 1; do
        run "$1" "$2" "$ci"
        if [ "$RC" = 1 ] && grep -q "^FAIL: $1 not found under CI" <<<"$OUT"; then pass
        else fail "$b with CI=$ci and no $1 should fail (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    done
}

# --- 2. every literal guard -----------------------------------------------------------------
declare -A seen=()
for f in "$ROOT"/tests/test-*.sh; do
    [ "$f" = "$SELF" ] && continue
    cmds="$(grep -oE '^[^#]*(require_python3|require_cmd [A-Za-z0-9._-]+|missing_cmd [A-Za-z0-9._-]+)' "$f" \
        | grep -oE '(require_python3|require_cmd [A-Za-z0-9._-]+|missing_cmd [A-Za-z0-9._-]+)$' \
        | sed -e 's/^require_python3$/python3/' -e 's/^[a-z_]* //' | sort -u)"
    for c in $cmds; do
        [[ "$c" == *.sh ]] && continue          # a required file (bootstrap.sh), not a PATH command
        seen[$c]=$(( ${seen[$c]:-0} + 1 ))
        expect_guard "$c" "$f"
    done
done
[ "${seen[python3]:-0}" -ge 20 ] && pass || fail "expected 20+ python3-guarded tests, found ${seen[python3]:-0}"
[ "${seen[node]:-0}" -ge 15 ] && pass || fail "expected 15+ node-guarded tests, found ${seen[node]:-0}"
for c in git flock openssl file; do
    [ "${seen[$c]:-0}" -ge 1 ] && pass || fail "no test guards $c with the helper"
done
for b in test-doc-links.sh test-doc-art.sh test-secrets.sh; do
    grep -q '^[^#]*require_python3 ' "$ROOT/tests/$b" && pass || fail "$b does not use require_python3"
done

# --- 3. per-case skips, whole file run without the command ----------------------------------
case_run() {   # case_run CMD SCRIPT SKIP_TEXT FAIL_TEXT
    run "$1" "$ROOT/tests/$2" -
    if [ "$RC" = 0 ] && grep -qF "$3" <<<"$OUT"; then pass
    else fail "$2 without $1, CI unset: should pass with the case skipped (rc=$RC): $(tail -1 <<<"$OUT")"; fi
    run "$1" "$ROOT/tests/$2" true
    if [ "$RC" != 0 ] && grep -qF "$4" <<<"$OUT"; then pass
    else fail "$2 without $1, CI=true: should fail (rc=$RC): $(tail -1 <<<"$OUT")"; fi
}
case_run node test-catalog-cache.sh "SKIP: no node runtime — parseCatalogTSV" "FAIL: parseCatalogTSV filter case needs node"
case_run zstd test-static-site.sh "SKIP: zstd cluster case" "FAIL: ZIM: zstd cluster case needs the zstd CLI"

# --- 4. lint --------------------------------------------------------------------------------
# The ONLY tests allowed a `# ci-skip-ok: <why>` skip (a skip that is right in CI too). Adding a
# file here is a reviewed, visible diff (#315), and every entry must still carry one.
SKIP_OK_FILES=(test-tool-arch.sh)
lint() {   # lint FILE... -> one offender per line
    local f b x allow
    for f in "$@"; do
        b="$(basename "$f")"; allow=0
        for x in "${SKIP_OK_FILES[@]}"; do [ "$b" = "$x" ] && allow=1; done
        # Every skip-shaped line (echo/printf SKIP, `|| exit 0`, `|| { …; exit 0; }`) must be tied to
        # ci_is_set in CODE (a comment does not count) on that line or the one before, or -- in a
        # SKIP_OK_FILES test only -- to a `# ci-skip-ok: <reason>` on that line or the one before.
        awk -v b="$b" -v allow="$allow" '
            function code(s) { sub(/(^|[ \t])#.*/, "", s); return s }
            {
                c = code($0)
                why = ($0 ~ /# ci-skip-ok:[ \t]*[^ \t]/) || (prev ~ /# ci-skip-ok:[ \t]*[^ \t]/)
                ok = (c ~ /ci_is_set/) || (prevc ~ /ci_is_set/) || (why && allow)
            }
            /# ci-skip-ok:/ && !allow { print b ":" NR ": # ci-skip-ok: in a test not on SKIP_OK_FILES" }
            /# ci-skip-ok:/ && $0 !~ /# ci-skip-ok:[ \t]*[^ \t]/ { print b ":" NR ": # ci-skip-ok: needs a reason" }
            c ~ /echo[^#]*SKIP:|printf[^#]*SKIP/ && !ok { print b ":" NR ": SKIP: not tied to ci_is_set / # ci-skip-ok:" }
            c ~ /command -v [^|]*\|\|[^#]*exit 0/ && !ok { print b ":" NR ": silent command -v ... || exit 0" }
            c ~ /\|\|[ \t]*(exit 0|\{[^}]*exit 0)/ && c !~ /command -v / && !ok { print b ":" NR ": silent || exit 0 not tied to ci_is_set" }
            { prev = $0; prevc = c }' "$f"
        if grep -qE '^[^#]*\bpython3\b' "$f" && ! grep -qE '^[^#]*(require_python3|require_cmd python3)' "$f"; then
            echo "$b: runs python3 without require_python3"
        fi
        if grep -qE '^[^#]*(command -v node|NODE=[^#]*\.local/node/bin/node)' "$f" \
                && ! grep -qE '^[^#]*(require_cmd node|missing_cmd node|ci_is_set)' "$f"; then
            echo "$b: resolves node without a guard"
        fi
    done
}
real=(); for f in "$ROOT"/tests/test-*.sh; do [ "$f" = "$SELF" ] || real+=("$f"); done
bare="$(lint "${real[@]}")"
if [ -z "$bare" ]; then pass; else fail "bare runtime guards (use tests/lib/require-cmd.sh):"$'\n'"$bare"; fi
for x in "${SKIP_OK_FILES[@]}"; do   # a stale allowlist entry is dropped, not left to cover a future skip
    grep -qE '# ci-skip-ok:[[:space:]]*[^[:space:]]' "$ROOT/tests/$x" 2>/dev/null && pass \
        || fail "SKIP_OK_FILES lists $x, which has no '# ci-skip-ok: <why>': drop it from the list"
done
CIYML="$ROOT/.github/workflows/ci.yml"   # test-cad-agent.sh's CPython 3.12 case fails under CI, so CI pins it
grep -qE '^[^#]*uses: actions/setup-python@[0-9a-f]{40}' "$CIYML" \
    && grep -qE "^[^#]*python-version: *['\"]?3\.12['\"]?" "$CIYML" && pass \
    || fail "ci.yml must pin python-version 3.12 with a SHA-pinned actions/setup-python (#315)"

# the lint must catch each bad form (fixtures), and accept the good ones
mkdir -p "$T/lint/ok" "$T/lint/empty-why"
{ cat "$ROOT/tests/test-health.sh"; echo 'echo "SKIP: extra (no node)" >&2'; } > "$T/lint/appended.sh"
printf '%s\n' 'if ! command -v python3 >/dev/null 2>&1; then' '    echo "SKIP: python3 not found"' '    exit 0' 'fi' \
    'python3 -c 1' > "$T/lint/multiline.sh"
printf '%s\n' 'ROOT=.' 'python3 - <<EOF' 'print(1)' 'EOF' > "$T/lint/unguarded-py.sh"
printf '%s\n' 'command -v zstd >/dev/null 2>&1 || exit 0' > "$T/lint/silent.sh"
printf '%s\n' 'NODE="$(command -v node)"' '"$NODE" -e 1' > "$T/lint/node.sh"
printf '%s\n' '# a comment naming ci_is_set does not tie the skip' 'echo "SKIP: x" >&2' > "$T/lint/comment-ci.sh"
printf '%s\n' 'x=1   # nor does a trailing ci_is_set comment' 'echo "SKIP: x" >&2' > "$T/lint/trailing-ci.sh"
printf '%s\n' '# ci-skip-ok: a reason, but this test is not on SKIP_OK_FILES' 'echo "SKIP: x" >&2' > "$T/lint/unlisted.sh"
printf '%s\n' '[ -d x ] || exit 0' > "$T/lint/or-exit.sh"
printf '%s\n' '[ -d x ] || { echo "no x" >&2; exit 0; }' > "$T/lint/or-brace-exit.sh"
printf '%s\n' "printf 'SKIP: x\\n' >&2" > "$T/lint/printf-skip.sh"
printf '%s\n' '# ci-skip-ok:   ' '[ -d x ] || { echo "SKIP: no mirror" >&2; exit 0; }' > "$T/lint/empty-why/test-tool-arch.sh"
printf '%s\n' '[ "$rc" = 0 ] && pass || fail "must exit 0"' 'echo hi  # echo "SKIP: in a comment"' \
    'if ci_is_set; then fail "x"' 'else echo "SKIP: x (no zstd)" >&2; fi' 'ci_is_set || exit 0' > "$T/lint/good.sh"
printf '%s\n' '# ci-skip-ok: a fresh checkout has no mirror' '[ -d x ] || { echo "SKIP: no mirror" >&2; exit 0; }' \
    > "$T/lint/ok/test-tool-arch.sh"
for fx in appended multiline unguarded-py silent node comment-ci trailing-ci unlisted or-exit or-brace-exit \
        printf-skip empty-why/test-tool-arch; do
    [ -n "$(lint "$T/lint/$fx.sh")" ] && pass || fail "lint must flag the '$fx' fixture"
done
grep -q 'appended.sh:.*SKIP: not tied' <<<"$(lint "$T/lint/appended.sh")" && pass \
    || fail "lint must flag the appended bare SKIP line itself"
grep -q 'needs a reason' <<<"$(lint "$T/lint/empty-why/test-tool-arch.sh")" && pass \
    || fail "lint must flag an empty '# ci-skip-ok:' reason"
for fx in good ok/test-tool-arch; do
    [ -z "$(lint "$T/lint/$fx.sh")" ] && pass || fail "lint must accept the '$fx' fixture: $(lint "$T/lint/$fx.sh")"
done

echo "require-cmd: $PASS passed, $FAIL failed ($(for c in "${!seen[@]}"; do printf '%s:%s ' "$c" "${seen[$c]}"; done))"
[ "$FAIL" -eq 0 ]
