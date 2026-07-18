#!/bin/bash
###############################################################################
# Test: realpath containment of served paths (issue #101).
#
# server.js isPathSafe() is LEXICAL, so a symlink planted INSIDE a served tree
# (tools/models/content/sources) that points OUTSIDE ROOT passes it — and both
# serveArchive (fs.stat) and the /api/packages enumeration (statSync) FOLLOW the
# link, streaming / shallow-sizing the out-of-tree target. The fix adds realpath
# containment. This exercises it LIVE, offline:
#
#   A) serveArchive — planting an in-tree symlink to a secret OUTSIDE ROOT:
#        * GET the symlink directly            → 404, and the secret is NOT streamed
#        * a real in-tree file                 → 200 (legit serving unbroken)
#        * a WITHIN-tree relative symlink      → 200 (legit within-root links kept)
#   B) /api/packages — an escaping symlink in the tools/ + content/ trees is NOT
#      enumerated (no size leak), while the legit siblings still are.
#
# Serving reads from ROOT/<top> (not env-overridable) so its fixtures go under the
# real repo tree (gitignored, cleaned up); enumeration honors VALARK_*_DIR so its
# fixtures live in an isolated mktemp mirror. One server exercises both.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"          # isolated enumeration mirror + secret target (OUTSIDE ROOT)
SECRET="$T/outside"       # the out-of-tree directory an attacker symlinks to
SRV_PID=""
# serveArchive fixtures must sit under the REAL ROOT/content (gitignored). Track
# whether we created ROOT/content so cleanup removes only what we made.
ADIR="__contain_$$__"; MADE_CONTENT=0
[ -e "$ROOT/content" ] || MADE_CONTENT=1
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$ROOT/content/$ADIR" 2>/dev/null
    [ "$MADE_CONTENT" = 1 ] && rmdir "$ROOT/content" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

# --- Secret target OUTSIDE ROOT ----------------------------------------------
mkdir -p "$SECRET"
printf 'TOPSECRET-CONTENTS\n' > "$SECRET/secret.txt"
head -c 4096 /dev/zero       > "$SECRET/secret.zim"

# --- A) serveArchive fixtures under the REAL ROOT/content/$ADIR ---------------
mkdir -p "$ROOT/content/$ADIR"
printf 'LEGIT-INTREE\n' > "$ROOT/content/$ADIR/legit.txt"     # real in-tree file → served
ln -s "$SECRET/secret.txt" "$ROOT/content/$ADIR/evil"          # escapes ROOT → must 404
ln -s "legit.txt"          "$ROOT/content/$ADIR/inlink"        # stays in-tree → still served

# --- B) enumeration fixtures in an ISOLATED mirror (VALARK_*_DIR) -------------
mkdir -p "$T/tools/linux-x86_64/helix" "$T/content/zim" "$T/models" "$T/sources"
head -c 4096 /dev/zero > "$T/tools/linux-x86_64/helix/hx"      # legit app → listed
ln -s "$SECRET" "$T/tools/linux-x86_64/evil"                   # escaping dir symlink → NOT listed
head -c 8192 /dev/zero > "$T/content/zim/real.zim"            # legit zim → listed
ln -s "$SECRET/secret.zim" "$T/content/zim/evil.zim"          # escaping zim symlink → NOT listed

# --- Start ONE server: real ROOT/content for serving, temp mirror for listing --
PORT=3961; B="http://127.0.0.1:$PORT"
env VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
  VALARK_WEB_PORT="$PORT" VALARK_HTTPS_PORT="$((PORT + 9000))" VALARK_STATE_DIR="$T/state" \
  VALARK_TOOLS_DIR="$T/tools" VALARK_SOURCES_DIR="$T/sources" \
  VALARK_MODELS_DIR="$T/models" VALARK_CONTENT_DIR="$T/content" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 30); do sleep 0.4; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || { fail "server did not start on :$PORT"; echo "path-containment: ${PASS} passed, ${FAIL} failed"; exit 1; }

# --- A) serveArchive containment ----------------------------------------------
# Legit in-tree file still serves.
LC="$(curl -s -o "$T/legit.out" -w '%{http_code}' --max-time 6 "$B/api/archive/content/$ADIR/legit.txt")"
{ [ "$LC" = 200 ] && grep -q LEGIT-INTREE "$T/legit.out"; } && pass \
    || fail "a real in-tree file must still serve 200 (code=$LC)"

# The escaping symlink must 404 AND must not stream the secret.
EC="$(curl -s -o "$T/evil.out" -w '%{http_code}' --max-time 6 "$B/api/archive/content/$ADIR/evil")"
[ "$EC" = 404 ] && pass || fail "an in-tree symlink escaping ROOT must 404 (got $EC)"
grep -q TOPSECRET "$T/evil.out" && fail "the out-of-tree secret must NEVER be streamed" || pass

# A legitimate WITHIN-tree symlink must STILL serve (fix must not over-block).
IC="$(curl -s -o "$T/inlink.out" -w '%{http_code}' --max-time 6 "$B/api/archive/content/$ADIR/inlink")"
{ [ "$IC" = 200 ] && grep -q LEGIT-INTREE "$T/inlink.out"; } && pass \
    || fail "a within-root symlink must still serve 200 (code=$IC)"

# --- B) /api/packages enumeration containment ---------------------------------
PK="$(curl -s --max-time 6 "$B/api/packages")"
echo "$PK" | "$NODE" -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s), P=j.packages||[];
    const has = n => P.some(p => p.name === n || String(p.id).includes(":"+n));
    const checks = {
      helixListed:  has("helix"),                 // legit app present
      realZimListed: has("real.zim"),             // legit zim present
      noEvilTool:   !P.some(p => p.name==="evil"),        // escaping tool skipped
      noEvilZim:    !P.some(p => p.name==="evil.zim"),    // escaping zim skipped
      noSecretName: !P.some(p => /secret/i.test(String(p.name))),
    };
    const bad = Object.entries(checks).filter(([,v])=>!v).map(([k])=>k);
    if (bad.length) { console.error("failing checks: "+bad.join(",")); process.exit(1); }
    process.exit(0);
  });' && pass || fail "enumeration must list legit siblings but SKIP escaping in-tree symlinks"

# The manifest must not leak the out-of-tree secret path.
echo "$PK" | grep -qE "$SECRET|$T|/outside/" && fail "manifest must not leak the out-of-tree target path" || pass

echo "path-containment: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
