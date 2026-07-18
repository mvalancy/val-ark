#!/bin/bash
###############################################################################
# Test: server.js bounds concurrent expensive work (issue #62).
#
# The per-IP rate limiter paces admission RATE but does not bound simultaneous
# in-flight work. This exercises the three concurrency caps added for #62, live
# over HTTP against an isolated server (offline, no external mirrors):
#
#   1. POST /api/moderation/check — cap on concurrent checks (each buffers up to
#      MOD_CHECK_MAX in RAM + spawns a classifier child). Over budget → 503 with
#      a FAIL-CLOSED {decision:'hold'} + Retry-After (never an implicit allow).
#      Also: a declared over-cap Content-Length is rejected 413 before buffering.
#   2. GET /api/archive/<dir> — cap on concurrent tar+gzip streams (CPU-bound,
#      unthrottled amplification). Over budget → 503 + Retry-After. Single-file /
#      first request still works.
#   3. GET /api/downloads/stream — per-IP SSE cap on top of the global pool cap,
#      so one peer can't exhaust the progress stream for everyone. Over budget →
#      503; within budget still serves the init event.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

SRV_PID=""; BG_PIDS=()
# Archive tars are served from ROOT/<top> (gitignored). Create a temp tree there;
# track whether we created ROOT/content so cleanup removes only what we made.
ADIR="__srvlimits_$$__"; MADE_CONTENT=0
[ -e "$ROOT/content" ] || MADE_CONTENT=1
cleanup() {
    for p in "${BG_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$ROOT/content/$ADIR" 2>/dev/null
    [ "$MADE_CONTENT" = 1 ] && rmdir "$ROOT/content" 2>/dev/null
    rm -rf "$T" 2>/dev/null
}
trap cleanup EXIT
T="$(mktemp -d)"
mkdir -p "$T/state" "$T/content/zim" "$T/models"

# A stub classifier (VALARK_MODERATION_CMD) called as "<kind> <file>": content that
# contains SLOW sleeps (holding the moderation slot in flight); everything else is safe.
cat > "$T/stub" <<'EOF'
#!/bin/bash
grep -q SLOW "$2" 2>/dev/null && sleep 3
echo safe
EOF
chmod +x "$T/stub"

# Incompressible bytes, sized comfortably ABOVE the kernel's max TCP send+recv buffering
# (~42 MiB combined on loopback here) so a slow reader can't let the whole tarball drain
# into buffers — tar+gzip stays in flight (and gzip is still crunching) while we probe.
mkdir -p "$ROOT/content/$ADIR"
head -c 80000000 /dev/urandom > "$ROOT/content/$ADIR/blob.bin"

PORT=3700; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 \
  VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" VALARK_MODERATION_CMD="$T/stub" \
  VALARK_MODERATION_MAX_BYTES=4096 VALARK_MODERATION_MAX_CONCURRENT=1 \
  VALARK_MAX_ARCHIVE_TAR=1 VALARK_MAX_SSE_PER_IP=2 \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" != 1 ]; then fail "server did not start on :$PORT"; echo "server-limits: ${PASS} passed, ${FAIL} failed"; exit 1; fi
pass

# --- 1. moderation-check concurrency budget (cap=1) --------------------------------
# Positive: a normal check still screens (stub → safe → allow).
echo "$(curl -s --max-time 8 -X POST --data-binary 'a nice clean message' "$B/api/moderation/check")" \
    | grep -q '"decision":"allow"' && pass || fail "a normal moderation check must still screen (allow)"

# Hold one slot open with a slow classifier, then a 2nd concurrent check must be refused.
curl -s -o /dev/null --max-time 20 -X POST --data-binary 'SLOW keep the slot busy' "$B/api/moderation/check" &
BG_PIDS+=($!)
sleep 1   # let the slow check get admitted + reach the sleeping classifier
R="$(curl -s -i --max-time 6 -X POST --data-binary 'over the concurrency cap' "$B/api/moderation/check")"
echo "$R" | grep -qE '^HTTP/[0-9.]+ 503' && pass || fail "over-concurrency moderation check must 503 (got: $(echo "$R" | head -1))"
echo "$R" | grep -qi '^Retry-After:'      && pass || fail "moderation 503 must carry Retry-After"
echo "$R" | grep -q '"decision":"hold"'   && pass || fail "over-concurrency check must FAIL-CLOSED to hold"
echo "$R" | grep -q '"decision":"allow"'  && fail "over-concurrency check must NEVER allow" || pass

# A declared over-cap Content-Length is rejected before buffering (early 413 hold).
head -c 8000 /dev/zero > "$T/big"     # > 4096-byte cap; curl sets Content-Length
BR="$(curl -s -i --max-time 8 -X POST --data-binary @"$T/big" "$B/api/moderation/check")"
echo "$BR" | grep -qE '^HTTP/[0-9.]+ 413' && pass || fail "declared over-cap body must 413 (got: $(echo "$BR" | head -1))"
echo "$BR" | grep -q '"decision":"hold"'   && pass || fail "over-cap body must hold (never allow)"

# --- 2. archive tar concurrency cap (cap=1) ---------------------------------------
# Positive: the first directory download tarballs fine (gzip magic 1f 8b).
HC="$(curl -s -o "$T/out.tgz" -w '%{http_code}' --max-time 30 "$B/api/archive/content/$ADIR")"
MAGIC="$(od -An -N2 -tx1 "$T/out.tgz" 2>/dev/null | tr -d ' \n')"
if [ "$HC" = 200 ] && [ "$MAGIC" = "1f8b" ]; then pass
else fail "first archive-dir download must return a 200 gzip tarball (code=$HC magic=$MAGIC)"; fi

# Hold one tar slot with a slow reader, then a 2nd concurrent tar must be refused.
curl -s -o /dev/null --limit-rate 20k --max-time 30 "$B/api/archive/content/$ADIR" &
BG_PIDS+=($!)
sleep 1.5  # let the slow download spawn tar and occupy the only slot
AR="$(curl -s -i --max-time 6 "$B/api/archive/content/$ADIR")"
echo "$AR" | grep -qE '^HTTP/[0-9.]+ 503' && pass || fail "over-cap concurrent tar must 503 (got: $(echo "$AR" | head -1))"
echo "$AR" | grep -qi '^Retry-After:'      && pass || fail "archive 503 must carry Retry-After"
echo "$AR" | grep -qi 'concurrent archive'  && pass || fail "archive 503 must explain the cap"

# --- 3. per-IP SSE cap (cap=2) ----------------------------------------------------
# Positive: a single stream still serves the init event.
echo "$(curl -sN --max-time 2 "$B/api/downloads/stream")" | grep -q '"connected":true' \
    && pass || fail "SSE stream must serve the init event within the per-IP cap"
# Open 2 streams (the whole per-IP budget) and hold them, then a 3rd must be refused.
curl -sN --max-time 8 "$B/api/downloads/stream" >/dev/null & BG_PIDS+=($!)
curl -sN --max-time 8 "$B/api/downloads/stream" >/dev/null & BG_PIDS+=($!)
sleep 1   # let both connections register in the per-IP tally
SR="$(curl -s -i --max-time 3 "$B/api/downloads/stream")"
echo "$SR" | grep -qE '^HTTP/[0-9.]+ 503' && pass || fail "SSE over the per-IP cap must 503 (got: $(echo "$SR" | head -1))"
echo "$SR" | grep -qi 'from this client'    && pass || fail "per-IP SSE 503 must name the per-client cap"

echo "server-limits: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
