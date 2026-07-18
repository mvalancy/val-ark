#!/bin/bash
###############################################################################
# Test: test-urls.sh retry/disposition logic (issue #48) — fully stubbed.
#
# Sources tests/test-urls.sh (its live checks are guarded behind a
# direct-execution check) and overrides curl/sleep with shell functions, so
# NO network requests are made. Asserts:
#   * sustained rate-limit (429/403/000) => WARN under CI, FAIL locally
#   * definitive dead URL (404)          => FAIL everywhere, no retries
#   * probe_once sends NO ranged-GET fallback after a definitive HEAD 429/403
#   * the GET fallback still fires for HEAD-unsupported answers (405, 000)
#   * no wasted sleep after the final attempt (3 sleeps for 4 attempts)
###############################################################################

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TPASS=0
TFAIL=0

STUB_LOG="$(mktemp)" || exit 1
ERR_FILE="$(mktemp)" || exit 1
trap 'rm -f "$STUB_LOG" "$ERR_FILE"' EXIT

# run_scenario <ci|local> <head-status> <get-status>
#   stdout: "PASS=<n> FAIL=<n> WARN=<n>" after one check_url call
#   stderr: whatever check_url printed
#   $STUB_LOG: one line per stubbed call — HEAD / GET / SLEEP <n>
run_scenario() {
    local mode="$1" head_status="$2" get_status="$3"
    : > "$STUB_LOG"
    (
        if [ "$mode" = "ci" ]; then export CI=true; else unset CI GITHUB_ACTIONS; fi
        # shellcheck source=tests/test-urls.sh
        source "${TEST_DIR}/test-urls.sh"
        STUB_HEAD="$head_status"; STUB_GET="$get_status"
        curl() {
            local a is_head=0
            for a in "$@"; do [ "$a" = "-IL" ] && is_head=1; done
            if [ "$is_head" = 1 ]; then
                echo "HEAD" >> "$STUB_LOG"; printf '%s' "$STUB_HEAD"
            else
                echo "GET" >> "$STUB_LOG"; printf '%s' "$STUB_GET"
            fi
        }
        sleep() { echo "SLEEP $1" >> "$STUB_LOG"; }
        check_url "https://mirror.example/asset" "stub"
        echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
    )
}

expect_eq() {  # <desc> <actual> <wanted>
    if [ "$2" = "$3" ]; then TPASS=$((TPASS + 1))
    else echo "FAIL: $1 — got '$2', want '$3'" >&2; TFAIL=$((TFAIL + 1)); fi
}
expect_contains() {  # <desc> <haystack> <needle>
    case "$2" in *"$3"*) TPASS=$((TPASS + 1)) ;;
        *) echo "FAIL: $1 — '$3' not in '$2'" >&2; TFAIL=$((TFAIL + 1)) ;; esac
}
count() { grep -c "^$1" "$STUB_LOG" 2>/dev/null || true; }

# 1. Sustained 429 under CI: WARN not FAIL; 4 HEADs, zero GET amplification,
#    3 sleeps (none after the final attempt).
out=$(run_scenario ci 429 429 2>"$ERR_FILE")
expect_eq "CI sustained 429 counters" "$out" "PASS=0 FAIL=0 WARN=1"
expect_contains "CI sustained 429 message" "$(cat "$ERR_FILE")" "WARN (sustained 429)"
expect_eq "CI sustained 429 HEAD probes" "$(count HEAD)" "4"
expect_eq "CI sustained 429 GET fallbacks (no amplification)" "$(count GET)" "0"
expect_eq "CI sustained 429 sleeps (no final wasted sleep)" "$(count 'SLEEP ')" "3"

# 2. Sustained 403 under CI: same WARN treatment, no GET amplification.
out=$(run_scenario ci 403 403 2>"$ERR_FILE")
expect_eq "CI sustained 403 counters" "$out" "PASS=0 FAIL=0 WARN=1"
expect_eq "CI sustained 403 GET fallbacks (no amplification)" "$(count GET)" "0"

# 3. Sustained 429 locally (no CI env): still a hard FAIL.
out=$(run_scenario local 429 429 2>"$ERR_FILE")
expect_eq "local sustained 429 counters" "$out" "PASS=0 FAIL=1 WARN=0"
expect_contains "local sustained 429 message" "$(cat "$ERR_FILE")" "FAIL (429)"

# 4. Sustained 000 locally: unreachable host still FAILs; GET fallback allowed.
out=$(run_scenario local 000 000 2>"$ERR_FILE")
expect_eq "local sustained 000 counters" "$out" "PASS=0 FAIL=1 WARN=0"
expect_eq "local sustained 000 GET fallbacks" "$(count GET)" "4"

# 5. Definitive 404: hard FAIL even under CI, single attempt (no retries).
out=$(run_scenario ci 404 404 2>"$ERR_FILE")
expect_eq "CI 404 counters" "$out" "PASS=0 FAIL=1 WARN=0"
expect_contains "CI 404 message" "$(cat "$ERR_FILE")" "FAIL (404)"
expect_eq "CI 404 attempts (no retry of definitive status)" "$(count HEAD)" "1"
out=$(run_scenario local 404 404 2>"$ERR_FILE")
expect_eq "local 404 counters" "$out" "PASS=0 FAIL=1 WARN=0"

# 6. Healthy 200 via HEAD: pass, single request.
out=$(run_scenario local 200 200 2>"$ERR_FILE")
expect_eq "200 counters" "$out" "PASS=1 FAIL=0 WARN=0"
expect_eq "200 requests" "$(count HEAD)" "1"
expect_eq "200 GET fallbacks" "$(count GET)" "0"

# 7. HEAD-unsupported host (405) with working ranged GET: fallback still fires.
out=$(run_scenario local 405 200 2>"$ERR_FILE")
expect_eq "405->GET counters" "$out" "PASS=1 FAIL=0 WARN=0"
expect_eq "405->GET fallback fired" "$(count GET)" "1"

echo "urls-logic: ${TPASS} passed, ${TFAIL} failed"
[ "$TFAIL" -eq 0 ] && exit 0 || exit 1
