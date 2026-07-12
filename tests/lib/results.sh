#!/bin/bash
###############################################################################
# Val Ark - shared test-result helper (bash suites).
#
# Source this, then:
#   results_init "<suite-id>" "<Human Title>"
#   results_case "<case name>" pass|fail|skip [ms] [detail]
#   results_run  "<case name>" <command...>     # runs cmd, records pass/fail + duration
#   results_finish                              # writes tests/results/<suite-id>.json
#
# Emits the common schema consumed by tests/report/generate.mjs, so every suite —
# bash, services, VM — shows up in the one offline HTML dashboard.
###############################################################################
_R_DIR="${VALARK_RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
_R_ID=""; _R_TITLE=""; _R_PASS=0; _R_FAIL=0; _R_SKIP=0; _R_MS=0; _R_CASES=""

_r_json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"; }

results_init() {
    _R_ID="$1"; _R_TITLE="${2:-$1}"; _R_PASS=0; _R_FAIL=0; _R_SKIP=0; _R_MS=0; _R_CASES=""
    mkdir -p "$_R_DIR" 2>/dev/null
}

# results_case <name> pass|fail|skip [durationMs] [detail]
results_case() {
    local name="$1" st="$2" ms="${3:-0}" detail="${4:-}"
    local status
    case "$st" in pass|passed|ok) status=passed; _R_PASS=$((_R_PASS+1));;
                  fail|failed) status=failed; _R_FAIL=$((_R_FAIL+1));;
                  *) status=skipped; _R_SKIP=$((_R_SKIP+1));; esac
    _R_MS=$((_R_MS + ms))
    local obj
    obj="{\"name\":$(_r_json_escape "$name"),\"status\":\"$status\",\"durationMs\":${ms:-0},\"detail\":$(_r_json_escape "$detail")}"
    _R_CASES="${_R_CASES:+$_R_CASES,}$obj"
    # Live echo so a human watching the terminal sees progress too.
    case "$status" in passed) echo "  [PASS] $name";; failed) echo "  [FAIL] $name${detail:+ — $detail}";; *) echo "  [SKIP] $name${detail:+ — $detail}";; esac
}

# results_run <name> <command...> : run, time it, record pass/fail (stderr tail as detail on fail)
results_run() {
    local name="$1"; shift
    local start end ms out rc
    start=$(date +%s%3N 2>/dev/null || echo 0)
    out="$("$@" 2>&1)"; rc=$?
    end=$(date +%s%3N 2>/dev/null || echo 0)
    ms=$(( end > start ? end - start : 0 ))
    if [ "$rc" -eq 0 ]; then results_case "$name" pass "$ms"
    else results_case "$name" fail "$ms" "$(printf '%s' "$out" | tail -3)"; fi
    return "$rc"
}

results_finish() {
    [ -n "$_R_ID" ] || return 0
    local f="${_R_DIR}/${_R_ID}.json"
    {
        printf '{"suite":%s,"title":%s,"generated":%s,' \
            "$(_r_json_escape "$_R_ID")" "$(_r_json_escape "$_R_TITLE")" "$(_r_json_escape "${REPORT_STAMP:-}")"
        printf '"summary":{"passed":%d,"failed":%d,"skipped":%d,"durationMs":%d},' "$_R_PASS" "$_R_FAIL" "$_R_SKIP" "$_R_MS"
        printf '"cases":[%s]}' "$_R_CASES"
    } > "$f"
    echo "  -> ${_R_TITLE}: ${_R_PASS} passed, ${_R_FAIL} failed, ${_R_SKIP} skipped ($f)"
    return "$_R_FAIL"
}
