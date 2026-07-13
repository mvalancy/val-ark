#!/bin/bash
###############################################################################
# Test: moderation SERVER endpoints (roadmap Phase 7 — the web door to the
# fail-closed decision core in scripts/lib/moderation.sh).
#
# Exercises the live HTTP surface with a STUB classifier (VALARK_MODERATION_CMD),
# so no model is needed:
#   GET  /api/status/moderation   — health card (enabled + runner readiness)
#   POST /api/moderation/check     — raw-body screen → {decision}; size-capped; FAIL-CLOSED
#   POST /api/setup/moderation     — admin-only toggle/tune; disabled → check skips
# The security invariants: the check reader is size-capped (over-cap → hold/413, never
# OOM/allow), an empty body holds, the settings write is admin-only, and turning the
# engine OFF makes check return skip (explicitly NOT allow-by-policy).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

SRV_PID=""
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/state" "$T/content/zim" "$T/models"

# A stub classifier standing in for a real model: emits the RAW verdict the parser
# reduces. args are "<kind> <file>". Content with SCORE60 → a 0.60 risk score (exercises
# the sensitivity thresholds); BADWORD → unsafe; else safe.
cat > "$T/stub" <<'EOF'
#!/bin/bash
if grep -q SCORE60 "$2" 2>/dev/null; then echo "0.6"; exit 0; fi
if grep -q BADWORD "$2" 2>/dev/null; then echo unsafe; else echo safe; fi
EOF
chmod +x "$T/stub"

# Admin passcode so the admin-only settings write can be exercised via a session; Use
# Mode stays Open, so the "use" action (check) is reachable from the LAN without a login.
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("modtestpass","admin",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state"

# Pre-plant a leaked scan temp (simulates a process killed mid-check) — the boot sweep
# in onFirstBind must remove it so screened content never lingers at rest.
mkdir -p "$T/state/moderation/scan"; echo "leaked screened content" > "$T/state/moderation/scan/stale.bin"

PORT=3927; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 \
  VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" VALARK_MODERATION_CMD="$T/stub" \
  VALARK_MODERATION_MAX_BYTES=4096 \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" != 1 ]; then fail "server did not start on :$PORT"; echo "moderation-api: ${PASS} passed, ${FAIL} failed"; exit 1; fi
pass
# boot sweep removed the pre-planted leaked temp
[ ! -e "$T/state/moderation/scan/stale.bin" ] && pass || fail "boot sweep must remove leaked scan temps at startup"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }
chk()  { curl -s --max-time 20 -X POST --data-binary "$1" "$B/api/moderation/check"; }   # $1 = body (or @file)

# --- 1. status card: default ON (fail-closed default), stub makes runner ready -----
S="$(curl -s --max-time 6 "$B/api/status/moderation")"
echo "$S" | grep -q '"enabled":true'      && pass || fail "moderation enabled ON by default (got: $S)"
echo "$S" | grep -q '"runnerReady":true'  && pass || fail "stub classifier reports runnerReady:true"
echo "$S" | grep -q '"effective":"screening"' && pass || fail "effective=screening when enabled+ready"

# --- 2. check: clean content → allow; flagged content → block ---------------------
echo "$(chk 'a perfectly nice message')" | grep -q '"decision":"allow"' && pass || fail "clean content → allow"
echo "$(chk 'contains BADWORD here')"    | grep -q '"decision":"block"' && pass || fail "flagged content → block"

# --- 3. check FAIL-CLOSED: empty body holds; over-cap holds (413), never allow -----
echo "$(chk '')" | grep -q '"decision":"hold"' && pass || fail "empty body → hold"
head -c 8000 /dev/zero > "$T/big"                                   # > 4096-byte cap
c=$(code -X POST --data-binary @"$T/big" "$B/api/moderation/check")
[ "$c" = 413 ] && pass || fail "over-cap body → 413 (got $c)"
body=$(curl -s --max-time 8 -X POST --data-binary @"$T/big" "$B/api/moderation/check")
echo "$body" | grep -q '"decision":"hold"' && pass || fail "over-cap body → hold decision (got $body)"
echo "$body" | grep -q '"decision":"allow"' && fail "over-cap MUST NEVER allow" || pass

# --- 4. settings write is ADMIN-ONLY (ADMIN_ONLY_POSTS) ---------------------------
jpost() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' "$@"; }
[ "$(jpost -d '{"enabled":false}' "$B/api/setup/moderation")" = "401" ] && pass || fail "setup/moderation must be 401 without admin"
curl -s -c "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"password":"modtestpass"}' "$B/api/auth/login" >/dev/null
grep -q varksid "$T/cj" && pass || fail "admin login for settings write"

# --- 5. turn OFF → check returns skip (explicitly NOT allow); status reflects off ---
curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"enabled":false}' "$B/api/setup/moderation" | grep -q '"enabled":false' && pass || fail "admin can disable moderation"
echo "$(chk 'contains BADWORD here')" | grep -q '"decision":"skip"' && pass || fail "disabled engine → check returns skip (not allow)"
echo "$(chk 'contains BADWORD here')" | grep -q '"decision":"block"' && fail "disabled engine must NOT block/allow — only skip" || pass
curl -s --max-time 6 "$B/api/status/moderation" | grep -q '"effective":"off"' && pass || fail "status effective=off when disabled"

# --- 6. re-enable persists (leave sensitivity at the admin default 'balanced') -----
curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"enabled":true}' "$B/api/setup/moderation" >/dev/null
curl -s --max-time 6 "$B/api/status/moderation" | grep -q '"enabled":true' && pass || fail "re-enable persists"
echo "$(chk 'a perfectly nice message')" | grep -q '"decision":"allow"' && pass || fail "re-enabled engine screens again"

# --- 7. adversarial-review HIGH fix: a caller CANNOT weaken TYPE. ?kind=text on image
#        bytes must be IGNORED — magic-byte sniff decides, so response kind stays "image"
#        (else image content routes to the text classifier and bypasses image screening).
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRniceimage' > "$T/png"
rp=$(curl -s --max-time 20 -X POST --data-binary @"$T/png" "$B/api/moderation/check?kind=text")
echo "$rp" | grep -q '"kind":"image"' && pass || fail "?kind=text must NOT override magic-byte image typing (got $rp)"

# --- 8. adversarial-review MEDIUM fix: a caller CANNOT loosen SENSITIVITY.
#        A 0.60 score is HOLD under the admin's balanced policy; ?sensitivity=lenient
#        (which would ALLOW) must be ignored → still hold, never allow.
echo "$(curl -s --max-time 20 -X POST --data-binary 'SCORE60 content' "$B/api/moderation/check?sensitivity=lenient")" | grep -q '"decision":"hold"' && pass || fail "?sensitivity=lenient must be ignored (0.60 stays hold under admin balanced)"
echo "$(curl -s --max-time 20 -X POST --data-binary 'SCORE60 content' "$B/api/moderation/check?sensitivity=lenient")" | grep -q '"decision":"allow"' && fail "caller must NOT be able to loosen policy to allow" || pass

# --- 8b. review QUEUE + review actions (the Safety card's held-content feed) -----------
# Seed a quarantined item + its queue line (the sweep does this in production).
mkdir -p "$T/state/moderation/quarantine"
echo "held content bytes" > "$T/state/moderation/quarantine/1700000000_ab12_store_bad.txt"
printf '{"ts":1700000000,"path":"%s","decision":"block","reason":"flagged unsafe","quarantine":"%s"}\n' \
    "$T/store/bad.txt" "$T/state/moderation/quarantine/1700000000_ab12_store_bad.txt" > "$T/state/moderation/queue.jsonl"
# queue is ADMIN-ONLY: refused without a session, returned with one
[ "$(code "$B/api/moderation/queue")" = "401" ] && pass || fail "queue must be admin-only (401 without session)"
qj=$(curl -s -b "$T/cj" --max-time 6 "$B/api/moderation/queue")
echo "$qj" | grep -q '"id":"1700000000_ab12_store_bad.txt"' && pass || fail "admin queue must list the held item (got $qj)"
echo "$qj" | grep -q '"decision":"block"' && pass || fail "queue item must carry its decision"
# review is ADMIN-ONLY
[ "$(jpost -d '{"id":"1700000000_ab12_store_bad.txt","action":"remove"}' "$B/api/moderation/review")" = "401" ] && pass || fail "review must be admin-only (401 without session)"
# path-traversal id is rejected (no escape from the quarantine dir)
echo "$(curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"id":"../../../etc/passwd","action":"remove"}' "$B/api/moderation/review")" | grep -q '"error"' && pass || fail "traversal id must be rejected"
[ -f /etc/passwd ] && pass || fail "sanity: /etc/passwd untouched"   # (never at risk; the id never reaches an fs op)
# admin remove → ok, file deleted, queue now empty
curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"id":"1700000000_ab12_store_bad.txt","action":"remove"}' "$B/api/moderation/review" | grep -q '"ok":true' && pass || fail "admin remove must succeed"
[ ! -f "$T/state/moderation/quarantine/1700000000_ab12_store_bad.txt" ] && pass || fail "remove must delete the quarantined file"
curl -s -b "$T/cj" --max-time 6 "$B/api/moderation/queue" | grep -q '"count":0' && pass || fail "reviewed item must leave the pending queue (count 0)"

# --- 9. adversarial-review MEDIUM fix: quarantine CONFINEMENT. A symlinked scan dir
#        (planted by a same-uid process / NFS-mesh peer) must NOT redirect the write
#        outside <state> — the staged bytes must never land in the symlink target.
#        Needs its own server (the symlink would break the happy-path checks above).
kill "$SRV_PID" 2>/dev/null; SRV_PID=""
mkdir -p "$T/state2/moderation" "$T/external"
ln -s "$T/external" "$T/state2/moderation/scan"        # scan → outside <state>
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("modtestpass","admin",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state2"
PORT2=3928; B2="http://127.0.0.1:$PORT2"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 \
  VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT2" VALARK_MODERATION_CMD="$T/stub" \
  VALARK_STATE_DIR="$T/state2" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT2" >"$T/srv2.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B2/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || fail "confinement test server did not start"
r=$(curl -s --max-time 12 -X POST --data-binary 'BADWORD content into a symlinked scan' "$B2/api/moderation/check")
echo "$r" | grep -q '"decision":"hold"' && pass || fail "symlinked scan dir must → hold (got $r)"
[ -z "$(ls -A "$T/external" 2>/dev/null)" ] && pass || fail "attacker-controlled symlink target must stay EMPTY (no escaped write)"

echo "moderation-api: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
