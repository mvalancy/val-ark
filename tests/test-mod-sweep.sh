#!/bin/bash
###############################################################################
# Test: content moderation SWEEP (roadmap Phase 7 — the loop's enforcement point).
#
# Screens already-stored community uploads with the fail-closed core and QUARANTINES
# anything flagged into a review queue. Invariants:
#   - a clean file is left served + recorded (never re-screened)
#   - a flagged file is moved to quarantine (gone from the store) + queued
#   - FAIL-CLOSED: unparseable/hold verdict → quarantined, never left served
#   - idempotent: a screened file is skipped next sweep
#   - disabled engine → sweep is a no-op (nothing touched)
#   - action=flag leaves the original served but still queues a copy for review
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
SWEEP="$ROOT/scripts/lib/mod-sweep.sh"
COMMISSION="$ROOT/scripts/lib/commission.js"
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STORE="$T/store"; mkdir -p "$STORE"

# Stub classifier: content with BADWORD → unsafe; JUNKVERDICT → unparseable prose
# (must fail-closed to hold); SCORE30 → a numeric 0.3 risk score (allow at balanced, hold
# at strict — exercises the admin-sensitivity path); else safe. args are "<kind> <file>".
cat > "$T/stub" <<'EOF'
#!/bin/bash
if grep -q BADWORD "$2" 2>/dev/null; then echo unsafe; exit 0; fi
if grep -q JUNKVERDICT "$2" 2>/dev/null; then echo "the weather is pleasant today"; exit 0; fi
if grep -q SCORE30 "$2" 2>/dev/null; then echo 0.3; exit 0; fi
echo safe
EOF
chmod +x "$T/stub"

run_sweep() {   # extra env may override; STATE + dirs + stub are fixed
    env VALARK_STATE_DIR="$T" VALARK_MODERATION_DIRS="$STORE" VALARK_MODERATION_CMD="$T/stub" "$@" \
        bash "$SWEEP" sweep 2>/dev/null
}
QDIR="$T/moderation/quarantine"; QUEUE="$T/moderation/queue.jsonl"

# --- 1. clean stays, flagged is quarantined + queued (default action=block) ----------
echo "a perfectly nice message" > "$STORE/clean.txt"
echo "this contains BADWORD material" > "$STORE/bad.txt"
run_sweep >/dev/null; r=$?
[ "$r" = 10 ] && pass || fail "sweep with a flagged file must return rc 10 (got $r)"
[ -f "$STORE/clean.txt" ] && pass || fail "clean file must stay in the store"
[ ! -f "$STORE/bad.txt" ] && pass || fail "flagged file must be REMOVED from the store"
ls "$QDIR"/*bad.txt >/dev/null 2>&1 && pass || fail "flagged file must land in quarantine"
[ -f "$QUEUE" ] && grep -q '"decision":"block"' "$QUEUE" && pass || fail "flagged file must be recorded in the review queue"
[ -s "$T/moderation/screened.db" ] && pass || fail "resolved files must be recorded in the screened marker"

# --- 2. idempotent: nothing new → scanned 0, rc 0, no extra quarantine ----------------
before=$(ls "$QDIR" | wc -l)
out=$(run_sweep); r=$?
[ "$r" = 0 ] && pass || fail "re-sweep with no new files must return rc 0 (got $r)"
echo "$out" | grep -q 'scanned 0' && pass || fail "re-sweep must skip already-screened files (got: $out)"
[ "$(ls "$QDIR" | wc -l)" = "$before" ] && pass || fail "re-sweep must not re-quarantine"

# --- 3. FAIL-CLOSED: an unparseable verdict must quarantine (never leave served) ------
echo "please review this JUNKVERDICT upload" > "$STORE/ambiguous.txt"
run_sweep >/dev/null
[ ! -f "$STORE/ambiguous.txt" ] && pass || fail "unparseable-verdict file must be quarantined (fail-closed), not left served"
grep -q '"decision":"hold"' "$QUEUE" && pass || fail "unparseable verdict must be queued as hold"

# --- 4. disabled engine → sweep is a no-op --------------------------------------------
VALARK_STATE_DIR="$T" "$NODE" -e 'require(process.argv[1]).setModeration(process.env.VALARK_STATE_DIR,{enabled:false})' "$COMMISSION"
echo "another BADWORD post while disabled" > "$STORE/bad2.txt"
out=$(run_sweep);
echo "$out" | grep -q 'disabled' && pass || fail "disabled engine must skip the sweep (got: $out)"
[ -f "$STORE/bad2.txt" ] && pass || fail "disabled engine must not touch stored files"
rm -f "$STORE/bad2.txt"
VALARK_STATE_DIR="$T" "$NODE" -e 'require(process.argv[1]).setModeration(process.env.VALARK_STATE_DIR,{enabled:true})' "$COMMISSION"

# --- 5. adversarial-review HIGH fix: a FAILED quarantine move must NOT mark the file
#        screened — it is still served, so it must be retried, and the sweep must report
#        a hard error (rc 11). Force the failure by making the quarantine dir unwritable.
#        (Skip when running as root, which bypasses the permission.)
if [ "$(id -u)" != 0 ]; then
    echo "unmovable BADWORD content" > "$STORE/stuck.txt"
    chmod 500 "$QDIR"                                  # deny the mv into quarantine
    out=$(run_sweep); r=$?
    chmod 700 "$QDIR"
    [ "$r" = 11 ] && pass || fail "a failed quarantine move must return rc 11 (got $r: $out)"
    [ -f "$STORE/stuck.txt" ] && pass || fail "a file that could not be quarantined must stay put (not vanish silently)"
    # It must NOT be marked screened — the NEXT sweep (now writable) must retry + quarantine it.
    run_sweep >/dev/null
    [ ! -f "$STORE/stuck.txt" ] && pass || fail "an un-quarantinable file must be RETRIED once the move can succeed (fail-open guard)"
    ls "$QDIR"/*stuck.txt >/dev/null 2>&1 && pass || fail "the retried file must finally land in quarantine"
else
    pass; pass; pass; pass    # root bypasses the permission gate; keep the count stable
fi

# --- 6. odd filename (spaces) is handled + fully removed on flag ----------------------
printf 'BADWORD in a spaced name' > "$STORE/a spaced file.txt"
run_sweep >/dev/null
[ ! -f "$STORE/a spaced file.txt" ] && pass || fail "a spaced flagged filename must be quarantined"

# --- 7. #51: the sweep must screen at the ADMIN's configured sensitivity, not a hardcoded
#        'balanced'. A 0.3 risk score is ALLOW under balanced but HOLD under strict; the
#        loop's enforcement point must honor strict (parity with the web endpoint), and
#        TIGHTENING the policy must re-screen a file a weaker policy previously allowed.
set_sens() {   # $1 = strict|balanced|lenient
    VALARK_STATE_DIR="$T" "$NODE" -e \
        'require(process.argv[1]).setModeration(process.env.VALARK_STATE_DIR,{sensitivity:process.argv[2]})' \
        "$COMMISSION" "$1" >/dev/null 2>&1
}

# 7a. balanced policy: score 0.3 → allow → the file stays served (recorded allow).
set_sens balanced
echo "borderline SCORE30 upload" > "$STORE/border.txt"
run_sweep >/dev/null; r=$?
[ -f "$STORE/border.txt" ] && pass || fail "score-0.3 file must be ALLOWED (left served) under balanced policy"

# 7b. admin tightens to strict → the previously-allowed file must be RE-SCREENED (marker
#     folds in sensitivity) and now HELD → quarantined, per admin intent.
set_sens strict
run_sweep >/dev/null; r=$?
[ "$r" = 10 ] && pass || fail "tightening to strict must re-screen + quarantine the score-0.3 file (got rc $r)"
[ ! -f "$STORE/border.txt" ] && pass || fail "score-0.3 file must be quarantined under strict policy (honor admin sensitivity)"
ls "$QDIR"/*border.txt >/dev/null 2>&1 && pass || fail "the strict-quarantined score file must land in quarantine"
grep border.txt "$QUEUE" | grep -q '"decision":"hold"' && pass || fail "score-0.3 under strict must be queued as hold"

# restore default policy for any future case
set_sens balanced

echo "mod-sweep: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
