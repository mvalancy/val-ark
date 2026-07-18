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
#   C) findZimFiles() — the kiwix-serve feeder (issue #112, the SAME escape class
#      on the ZIM-serving path). statSync FOLLOWS symlinks, so an in-tree X.zim
#      symlink escaping ROOT would be resolved and handed to kiwix-serve. We
#      unit-invoke the REAL findZimFiles() (extracted + eval'd against a temp ROOT,
#      reusing the REAL realpathWithin) and assert an escaping .zim (and a dangling
#      one) are EXCLUDED, while a legit .zim and a WITHIN-tree relative symlink are
#      INCLUDED — no real kiwix binary / network needed.
#
# Serving reads from ROOT/<top> (not env-overridable) so its fixtures go under the
# real repo tree (gitignored, cleaned up); enumeration honors VALARK_*_DIR so its
# fixtures live in an isolated mktemp mirror. One server exercises both. Section C
# injects its own temp ROOT into the unit harness, so it touches nothing real.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"          # isolated enumeration mirror + secret target (OUTSIDE ROOT)
ZT="$(mktemp -d)"         # isolated findZimFiles() unit tree (Section C; own temp ROOT)
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
    rm -rf "$T" "$ZT"
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

# --- C) findZimFiles() containment — the kiwix-serve feeder (issue #112) -------
# findZimFiles() hardcodes ROOT/content/zim and is not env-overridable, and when
# kiwix is disabled it is never called, so we can't drive it over HTTP. Instead we
# extract the REAL findZimFiles() + realpathWithin() from server.js and eval them
# against an INJECTED temp ROOT — faithful (any removal of the #112 guard fails
# this) and fully offline (no kiwix binary, no network, no ports).
ZR="$ZT/root"; mkdir -p "$ZT/outside" "$ZR/content/zim"
head -c 2097152 /dev/zero > "$ZR/content/zim/real.zim"          # 2MB legit .zim  → included
head -c 2097152 /dev/zero > "$ZT/outside/big.zim"              # 2MB escape target (>1MB: without the fix, evil.zim would pass the size filter)
ln -s real.zim               "$ZR/content/zim/inlink.zim"       # WITHIN-tree relative symlink → still included
ln -s "$ZT/outside/big.zim"  "$ZR/content/zim/evil.zim"        # escapes ROOT → EXCLUDED (skipped, logged)
ln -s nonexistent.zim        "$ZR/content/zim/dangling.zim"     # dangling → EXCLUDED (realpath fails → null)

cat > "$ZT/zim-unit.js" <<'JS'
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const [SERVER, ROOT] = [process.argv[2], process.argv[3]];
const src = fs.readFileSync(SERVER, 'utf8');
// Top-level functions in server.js close with a column-0 `}`; grab source verbatim.
function extract(name) {
  const m = src.match(new RegExp('^function ' + name + '\\b[\\s\\S]*?\\n}', 'm'));
  if (!m) { console.error('EXTRACT_FAIL:' + name); process.exit(2); }
  return m[0];
}
const ZIM_EXPECTED_SIZES = {};
const sandbox = { fs, path, console, ROOT, ZIM_EXPECTED_SIZES, require };
vm.createContext(sandbox);
let out;
try { out = vm.runInContext(extract('realpathWithin') + '\n' + extract('findZimFiles') + '\nfindZimFiles();', sandbox); }
catch (e) { console.error('RUN_FAIL:' + e.message); process.exit(3); }
console.log(JSON.stringify((out || []).map(p => path.basename(p))));
JS

ZOUT="$("$NODE" "$ZT/zim-unit.js" "$ROOT/scripts/server.js" "$ZR" 2>"$ZT/zim.err")"
if [ -z "$ZOUT" ]; then
    fail "findZimFiles() unit harness produced no output ($(cat "$ZT/zim.err" 2>/dev/null))"
else
    # real.zim + the within-tree inlink.zim MUST be served; evil.zim + dangling.zim MUST NOT.
    echo "$ZOUT" | grep -q '"real.zim"'   && pass || fail "findZimFiles must include a legit in-tree .zim (got: $ZOUT)"
    echo "$ZOUT" | grep -q '"inlink.zim"' && pass || fail "findZimFiles must include a WITHIN-tree relative .zim symlink (got: $ZOUT)"
    echo "$ZOUT" | grep -q '"evil.zim"'   && fail "findZimFiles must EXCLUDE a .zim symlink escaping ROOT (got: $ZOUT)" || pass
    echo "$ZOUT" | grep -q '"dangling.zim"' && fail "findZimFiles must EXCLUDE a dangling .zim symlink (got: $ZOUT)" || pass
fi

echo "path-containment: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
