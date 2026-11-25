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
#   4. Lint, on the real tests and on fixtures that must be caught: every `SKIP:` line needs
#      `ci_is_set` (or a `# ci-skip-ok: <why>` comment) on that line or the one before; a test
#      that runs python3 calls require_python3; a test that resolves node guards it; no silent
#      `command -v X || exit 0`.
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
lint() {   # lint FILE... -> one offender per line
    local f b
    for f in "$@"; do
        b="$(basename "$f")"
        # every SKIP: line is tied to ci_is_set / a ci-skip-ok reason, on that line or the one before
        awk -v b="$b" '
            { ok = ($0 ~ /ci_is_set|# ci-skip-ok:/) || (prev ~ /ci_is_set|# ci-skip-ok:/) }
            $0 !~ /^[ \t]*#/ && /echo[^#]*SKIP:/ && !ok { print b ":" NR ": SKIP: not tied to ci_is_set / # ci-skip-ok:" }
            $0 !~ /^[ \t]*#/ && /command -v [^|]*\|\|[^#]*exit 0/ && !ok { print b ":" NR ": silent command -v ... || exit 0" }
            { prev = $0 }' "$f"
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

# the lint must catch each bad form (fixtures), and accept the good ones
mkdir -p "$T/lint"
{ cat "$ROOT/tests/test-health.sh"; echo 'echo "SKIP: extra (no node)" >&2'; } > "$T/lint/appended.sh"
printf '%s\n' 'if ! command -v python3 >/dev/null 2>&1; then' '    echo "SKIP: python3 not found"' '    exit 0' 'fi' \
    'python3 -c 1' > "$T/lint/multiline.sh"
printf '%s\n' 'ROOT=.' 'python3 - <<EOF' 'print(1)' 'EOF' > "$T/lint/unguarded-py.sh"
printf '%s\n' 'command -v zstd >/dev/null 2>&1 || exit 0' > "$T/lint/silent.sh"
printf '%s\n' 'NODE="$(command -v node)"' '"$NODE" -e 1' > "$T/lint/node.sh"
printf '%s\n' 'if ci_is_set; then fail "x"' 'else echo "SKIP: x (no zstd)" >&2; fi' \
    '# ci-skip-ok: a fresh checkout has no mirror' '[ -d x ] || { echo "SKIP: no mirror" >&2; exit 0; }' > "$T/lint/good.sh"
for fx in appended multiline unguarded-py silent node; do
    [ -n "$(lint "$T/lint/$fx.sh")" ] && pass || fail "lint must flag the '$fx' fixture"
done
grep -q 'appended.sh:.*SKIP: not tied' <<<"$(lint "$T/lint/appended.sh")" && pass \
    || fail "lint must flag the appended bare SKIP line itself"
[ -z "$(lint "$T/lint/good.sh")" ] && pass || fail "lint must accept ci_is_set / ci-skip-ok skips: $(lint "$T/lint/good.sh")"

echo "require-cmd: $PASS passed, $FAIL failed ($(for c in "${!seen[@]}"; do printf '%s:%s ' "$c" "${seen[$c]}"; done))"
[ "$FAIL" -eq 0 ]
