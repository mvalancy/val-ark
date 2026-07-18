#!/bin/bash
###############################################################################
# Test: librarian download resume integrity (#54).
#
# The librarian prefers aria2 (8-connection, SEGMENTED .part) and falls back to
# single-stream `curl -C -`. Mixing resumers corrupts: an aria2 .part is not a
# linear prefix, so curl "resuming" it blesses a hole-filled file as complete.
# Invariants proven here (all downloads stubbed — nothing touches the network):
#   a) curl NEVER resumes a .part that aria2 wrote (.aria2 control file marker)
#   b) a transient failure KEEPS .part + .aria2 (big downloads resume, not restart)
#   c) success stays size-verified + atomically renamed + manifest-recorded
#   d) a size-short-after-"complete" (mismatched) .part is CLEARED, never wedges
#   e) curl-only box: stale aria2 partial is discarded (fresh start), curl's own
#      linear .part still resumes
#   f) verify age-GCs abandoned partials (VALARK_PARTIAL_MAX_AGE_DAYS)
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- sandbox: private data root + empty config (never the host's .env) --------
export VAL_ARK_DATA="$T/data"; mkdir -p "$VAL_ARK_DATA"
export VAL_ARK_CONFIG="$T/empty.env"; : > "$VAL_ARK_CONFIG"

# --- controlled PATH: stubs + just the coreutils the code under test needs ----
# aria2c presence/absence is controlled by (un)linking $BIN/aria2c — the code's
# `command -v aria2c` only ever sees this dir.
BIN="$T/bin"; mkdir -p "$BIN"
for c in bash sh mkdir dirname basename stat rm mv cp date grep cut find touch \
         wc head cat sed awk sort uniq numfmt flock python3; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$BIN/$c"
done

# Stub aria2c: mimics the modes that matter. Parses -d/-o like the real argv.
#   fail_partial : mid-file failure — full-length prealloc'd (holey) .part + .aria2
#   success      : full file, control file removed, exit 0
#   success_short: claims success but the file is short (catalog mismatch)
#   fail_clean   : fails without writing anything
cat > "$BIN/aria2c" <<'EOF'
#!/bin/bash
dir=""; out=""
while [ $# -gt 0 ]; do case "$1" in
    -d) dir="$2"; shift 2;; -o) out="$2"; shift 2;; *) shift;; esac; done
[ -n "${ARIA2_CALLED:-}" ] && echo x >> "$ARIA2_CALLED"
case "${ARIA2_MODE:-fail_clean}" in
    fail_partial)
        head -c "${ARIA2_PART_BYTES:-1000}" /dev/zero > "$dir/$out"
        : > "$dir/$out.aria2"
        exit 1 ;;
    success)
        head -c "${ARIA2_FULL_BYTES:-1000}" /dev/zero > "$dir/$out"
        rm -f "$dir/$out.aria2"
        exit 0 ;;
    success_short)
        head -c "${ARIA2_FULL_BYTES:-100}" /dev/zero > "$dir/$out"
        rm -f "$dir/$out.aria2"
        exit 0 ;;
    fail_clean) exit 1 ;;
esac
EOF
chmod +x "$BIN/aria2c"

# Stub curl: records every invocation; honors -C - semantics (appends up to
# CURL_FULL_BYTES; a file already >= that length is "already complete": exit 0
# with zero bytes transferred — exactly how a holey aria2 part gets blessed).
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "${CURL_CALLED:-}" ] && echo x >> "$CURL_CALLED"
case "${CURL_MODE:-success}" in
    success)
        total="${CURL_FULL_BYTES:-1000}"
        cur=0; [ -f "$out" ] && cur=$(stat -c%s "$out")
        [ "$cur" -lt "$total" ] && head -c $(( total - cur )) /dev/zero >> "$out"
        exit 0 ;;
    fail_partial)
        head -c "${CURL_PART_BYTES:-200}" /dev/zero >> "$out"
        exit 22 ;;
    fail_clean) exit 7 ;;
esac
EOF
chmod +x "$BIN/curl"

# --- load the code under test (source guard exposes functions only) -----------
. "$ROOT/scripts/librarian.sh"
ensure_state

URL="https://mirror.invalid/test_2026-01.zim"   # .invalid TLD: can never resolve
DEST="$ZIM_DIR/test_2026-01.zim"
TMP="$DEST.part"; CTRL="$DEST.part.aria2"
BYTES=1000                                       # 90% gate = 900

reset_case() {
    rm -f "$DEST" "$TMP" "$CTRL" "$MANIFEST" "$T/aria2.calls" "$T/curl.calls"
    export ARIA2_CALLED="$T/aria2.calls" CURL_CALLED="$T/curl.calls"
}
dl() { PATH="$BIN" download_one zim:test content wikipedia 5 "$BYTES" zim "$URL" "$DEST" ""; }
calls() { [ -f "$1" ] && wc -l < "$1" || echo 0; }

# === 1. THE corruption vector: aria2 fails mid-file -> curl must NOT touch it =
reset_case
ARIA2_MODE=fail_partial ARIA2_PART_BYTES=1000 CURL_MODE=success CURL_FULL_BYTES=1000 dl; r=$?
[ "$r" != 0 ] && pass || fail "aria2-failed cycle must report failure, not a curl-blessed corrupt file (rc $r)"
[ "$(calls "$T/curl.calls")" = 0 ] && pass || fail "curl must NEVER be invoked on an aria2-owned .part (control file present)"
[ ! -f "$DEST" ] && pass || fail "no dest may appear from a failed aria2 attempt"
grep -qF "zim:test" "$MANIFEST" 2>/dev/null && fail "a failed download must not be manifest-recorded" || pass

# === 2. ...and the partial + control file SURVIVE for the next cycle (b) ======
[ -f "$TMP" ] && pass || fail "transient failure must KEEP the .part (resume, not restart from byte 0)"
[ -f "$CTRL" ] && pass || fail "transient failure must KEEP the .aria2 control file"

# === 3. next cycle: aria2 resumes its own partial and completes ===============
: > "$T/curl.calls"
ARIA2_MODE=success ARIA2_FULL_BYTES=1000 dl; r=$?
[ "$r" = 0 ] && pass || fail "aria2 resume on its own partial must succeed (rc $r)"
[ -f "$DEST" ] && [ "$(stat -c%s "$DEST")" = 1000 ] && pass || fail "dest must exist at full size after resume"
[ ! -f "$TMP" ] && [ ! -f "$CTRL" ] && pass || fail "success must clean up .part + control file"
grep -qF "zim:test" "$MANIFEST" 2>/dev/null && pass || fail "success must be manifest-recorded"

# === 4. size-short-after-'complete' = mismatch -> CLEARED, no wedge (d) =======
reset_case
ARIA2_MODE=success_short ARIA2_FULL_BYTES=100 dl; r=$?
[ "$r" != 0 ] && pass || fail "a size-short 'complete' download must fail (rc $r)"
[ ! -f "$TMP" ] && [ ! -f "$CTRL" ] && pass || fail "a mismatched .part must be CLEARED (resuming it would wedge retries forever)"
grep -qF "zim:test" "$MANIFEST" 2>/dev/null && fail "a size-short file must not be manifest-recorded" || pass

# === 5. curl-only box: transient curl failure keeps its linear .part (b) ======
rm -f "$BIN/aria2c"                              # no aria2 on this box
reset_case
CURL_MODE=fail_partial CURL_PART_BYTES=200 dl; r=$?
[ "$r" != 0 ] && pass || fail "failed curl download must report failure (rc $r)"
[ -f "$TMP" ] && [ "$(stat -c%s "$TMP")" = 200 ] && pass || fail "curl's own partial must be kept for linear resume"

# === 6. ...and curl resumes its OWN partial to completion (c) ================
: > "$T/curl.calls"
CURL_MODE=success CURL_FULL_BYTES=1000 dl; r=$?
[ "$r" = 0 ] && pass || fail "curl resume of its own .part must succeed (rc $r)"
[ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" = 1000 ] && pass || fail "resumed file must reach full size atomically at dest"

# === 7. curl-only box + leftover ARIA2 partial: discard + fresh start (a) =====
reset_case
printf 'HOLEY%.0s' $(seq 1 200) > "$TMP"         # 1000B fake holey aria2 part
: > "$CTRL"
CURL_MODE=success CURL_FULL_BYTES=1000 dl; r=$?
[ "$r" = 0 ] && pass || fail "curl-only box must recover from a stale aria2 partial (rc $r)"
grep -q HOLEY "$DEST" 2>/dev/null && fail "stale aria2 partial must be DISCARDED, never resumed into dest" || pass
[ ! -f "$CTRL" ] && pass || fail "stale control file must be cleaned up"
[ "$(calls "$T/curl.calls")" -ge 1 ] && pass || fail "curl must re-download fresh after discarding the aria2 partial"

# === 8. verify GC: abandoned partials age out; fresh ones stay (f) ============
reset_case
old_p="$ZIM_DIR/abandoned_2025-01.zim.part"; old_c="$old_p.aria2"
new_p="$ZIM_DIR/active_2026-01.zim.part"
printf 'x' > "$old_p"; : > "$old_c"; printf 'x' > "$new_p"
touch -d "20 days ago" "$old_p" "$old_c"
PATH="$BIN" cmd_verify >/dev/null 2>&1
[ ! -f "$old_p" ] && [ ! -f "$old_c" ] && pass || fail "verify must GC partials older than VALARK_PARTIAL_MAX_AGE_DAYS"
[ -f "$new_p" ] && pass || fail "verify must NOT GC a fresh partial (it is live resume state)"
rm -f "$new_p"

# === 9. GC honors the env knob ================================================
printf 'x' > "$old_p"; touch -d "20 days ago" "$old_p"
VALARK_PARTIAL_MAX_AGE_DAYS=30 PATH="$BIN" cmd_verify >/dev/null 2>&1
[ -f "$old_p" ] && pass || fail "a 20-day partial must survive when VALARK_PARTIAL_MAX_AGE_DAYS=30"

echo "librarian-download: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
