#!/bin/bash
###############################################################################
# Test: content moderation SWEEP (roadmap Phase 7 — the loop's enforcement point).
#
# Screens already-stored community uploads with the fail-closed core and QUARANTINES
# anything flagged into a review queue. Invariants:
#   - a clean file is left served + recorded (never re-screened)
#   - a flagged file is moved to quarantine (gone from the store) + queued
#   - FAIL-CLOSED: unparseable/hold verdict → quarantined, never left served
#   - a control-character filename still yields a VALID (parseable) review-queue line
#   - a symlink in the store is quarantined as the LINK, never read through
#   - idempotent: a screened file is skipped next sweep
#   - disabled engine → sweep is a no-op (nothing touched)
#   - default sweep-dirs: only VAL_ARK_UPLOADS is swept, never a DB-backed service store
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

# --- 8. #52 part 1: a control-character byte in a filename must not orphan the item. It is
#        legal in a Unix filename but ILLEGAL raw in a JSON string, so it must be \u00XX-
#        escaped or server.js _readJsonl's JSON.parse throws and silently drops the record
#        (the quarantined file becomes invisible + un-actionable in the review queue).
ctl=$(printf 'evil\x01ctrl.txt')
printf 'BADWORD via a control-char name' > "$STORE/$ctl"
run_sweep >/dev/null; r=$?
[ ! -e "$STORE/$ctl" ] && pass || fail "a control-char flagged file must be quarantined"
# EVERY queue line must be valid JSON — the pre-fix writer left a raw 0x01 that throws here.
"$NODE" -e 'const fs=require("fs");const L=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);let bad=0;for(const l of L){try{JSON.parse(l)}catch(e){bad++}}process.exit(bad?1:0)' "$QUEUE" \
    && pass || fail "every queue line must be valid JSON even for a control-char filename (no orphan)"

# --- 9. #52 part 2: a symlink in a swept store must be quarantined AS THE LINK — never read
#        through (a link to out-of-store / flagged / dir-tree content is a screening bypass:
#        find -type f alone skipped it and the bytes stayed reachable through the store path).
#        Covers link→file, link→dir (whole tree), and a dangling link; the target is untouched.
OUT="$T/outside"; mkdir -p "$OUT"
printf 'BADWORD reachable only through a store symlink' > "$OUT/payload.txt"
ln -s "$OUT/payload.txt" "$STORE/file-link.txt"     # link → out-of-store flagged file
ln -s "$OUT"             "$STORE/dir-link"           # link → out-of-store dir (whole tree)
ln -s "$OUT/missing.txt" "$STORE/dangling-link"      # dangling link
run_sweep >/dev/null; r=$?
[ "$r" = 10 ] && pass || fail "quarantining store symlinks must return rc 10 (got $r)"
[ ! -L "$STORE/file-link.txt" ] && pass || fail "a store symlink→file must be removed from the store (bypass closed)"
[ ! -L "$STORE/dir-link" ]      && pass || fail "a store symlink→dir must be removed from the store"
[ ! -L "$STORE/dangling-link" ] && pass || fail "a dangling store symlink must be removed from the store"
[ -f "$OUT/payload.txt" ] && pass || fail "the symlink TARGET outside the store must be left untouched (link moved, not followed)"
grep -q '"reason":"symlink in store"' "$QUEUE" && pass || fail "a quarantined symlink must be queued with the symlink reason"

# --- 10. #53: DEFAULT sweep-dirs behavior (regression guard for #46, which removed the
#         DB-backed community-store defaults). With VALARK_MODERATION_DIRS UNSET the sweep
#         screens ONLY VAL_ARK_UPLOADS — never a service store (whose files a DB references,
#         so a quarantine MOVE would corrupt it). We plant flagged files at the exact paths
#         #46 deleted; reverting sweep_dirs() to those defaults would quarantine them here.
#         VAL_ARK_CONFIG → an empty file so valark-env.sh ignores the repo .env and our
#         VAL_ARK_DATA (which derives DATA_ROOT and the state tree) is authoritative.
: > "$T/empty.conf"
D2="$T/data2"
UP2="$D2/val-ark/uploads";                 mkdir -p "$UP2"
PASTE_STORE="$D2/val-ark/state/services/paste/data";   mkdir -p "$PASTE_STORE"
MAIL_STORE="$D2/val-ark/state/services/mail/messages"; mkdir -p "$MAIL_STORE"
printf 'BADWORD in the plain uploads area' > "$UP2/upload-bad.txt"
printf 'BADWORD in a DB-backed paste store' > "$PASTE_STORE/paste.txt"
printf 'BADWORD in a DB-backed mail store'  > "$MAIL_STORE/mail.txt"
sweep_defaults() {   # NO explicit dirs / state override; all three unset up front, a caller
                     # re-adds VAL_ARK_UPLOADS via a trailing assignment (which wins over -u).
    env -u VALARK_STATE_DIR -u VALARK_MODERATION_DIRS -u VAL_ARK_UPLOADS \
        VAL_ARK_CONFIG="$T/empty.conf" VAL_ARK_DATA="$D2" VALARK_MODERATION_CMD="$T/stub" "$@" \
        bash "$SWEEP" sweep 2>&1
}

# 10a. VAL_ARK_UPLOADS set → its flagged file IS quarantined (sweep_dirs requires -d, so the
#      dir must exist — it does).
out=$(sweep_defaults VAL_ARK_UPLOADS="$UP2"); r=$?
[ "$r" = 10 ] && pass || fail "default sweep must screen VAL_ARK_UPLOADS and quarantine its flagged file (got rc $r: $out)"
[ ! -f "$UP2/upload-bad.txt" ] && pass || fail "a flagged file in VAL_ARK_UPLOADS must be quarantined"
# 10b. the DB-backed service stores were NOT swept (would corrupt them) → files untouched.
[ -f "$PASTE_STORE/paste.txt" ] && pass || fail "a DB-backed paste store must NOT be swept by default (#46 regression guard)"
[ -f "$MAIL_STORE/mail.txt" ]   && pass || fail "a DB-backed mail store must NOT be swept by default (#46 regression guard)"

# 10c. a MISSING VAL_ARK_UPLOADS path yields no dirs → clean no-op (rc 0) with a discoverable
#      log line, not a bare "scanned 0" or a crash.
out=$(sweep_defaults VAL_ARK_UPLOADS="$D2/no-such-dir"); r=$?
[ "$r" = 0 ] && pass || fail "a nonexistent VAL_ARK_UPLOADS must be a clean no-op (rc 0, got $r: $out)"
echo "$out" | grep -q 'no upload dirs to screen' && pass || fail "a missing sweep dir must log a discoverable message (got: $out)"
# 10d. NOTHING configured (no VAL_ARK_UPLOADS at all) → same discoverable no-op.
out=$(sweep_defaults); r=$?
[ "$r" = 0 ] && pass || fail "no configured sweep dirs must be a clean no-op (rc 0, got $r)"
echo "$out" | grep -q 'no upload dirs to screen' && pass || fail "no configured sweep dirs must log the discoverable message (got: $out)"

echo "mod-sweep: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
