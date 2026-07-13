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
# (must fail-closed to hold); else safe. args are "<kind> <file>".
cat > "$T/stub" <<'EOF'
#!/bin/bash
if grep -q BADWORD "$2" 2>/dev/null; then echo unsafe; exit 0; fi
if grep -q JUNKVERDICT "$2" 2>/dev/null; then echo "the weather is pleasant today"; exit 0; fi
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
grep -qF "$STORE/clean.txt" "$T/moderation/screened.tsv" && pass || fail "clean file must be recorded as screened"

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
# re-enable + set action=flag for the next case
VALARK_STATE_DIR="$T" "$NODE" -e 'require(process.argv[1]).setModeration(process.env.VALARK_STATE_DIR,{enabled:true,action:"flag"})' "$COMMISSION"

# --- 5. action=flag leaves the original served but still queues a copy ----------------
echo "flag me but keep BADWORD visible" > "$STORE/flagme.txt"
qn_before=$(grep -c '"action":"flag"' "$QUEUE" 2>/dev/null); qn_before=${qn_before:-0}
run_sweep >/dev/null
qn_after=$(grep -c '"action":"flag"' "$QUEUE" 2>/dev/null); qn_after=${qn_after:-0}
[ -f "$STORE/flagme.txt" ] && pass || fail "action=flag must leave the original served"
[ "$qn_after" -gt "$qn_before" ] && pass || fail "action=flag must still queue the item for review"
ls "$QDIR"/*flagme.txt >/dev/null 2>&1 && pass || fail "action=flag must keep a review copy in quarantine"

echo "mod-sweep: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
