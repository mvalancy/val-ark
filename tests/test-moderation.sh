#!/bin/bash
###############################################################################
# Test: on-device moderation decision core (roadmap Phase 7) — FAIL-CLOSED.
#
# The whole point is that content is HELD (never silently allowed) whenever the
# classifier can't give a usable verdict — the common bare-box/CI case with no
# model. Exercises the pure decide() unit, magic-byte sniff, the stub runner, and
# the no-model fail-closed path. No real model required.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/scripts/lib/moderation.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# rc helper: run moderation.sh, capture decision + exit code
dec() { bash "$MOD" "$@" 2>/dev/null; }
rc()  { bash "$MOD" "$@" >/dev/null 2>&1; echo $?; }

# --- 1. pure decide() unit: verdicts + score thresholds + fail-closed ---------
[ "$(dec decide safe balanced)"   = "allow" ] && pass || fail "safe → allow"
[ "$(dec decide unsafe balanced)" = "block" ] && pass || fail "unsafe → block (balanced)"
[ "$(dec decide unsafe lenient)"  = "hold"  ] && pass || fail "unsafe → hold (lenient)"
# unusable signals MUST hold, never allow (guards score||0→clean, NaN, out-of-range)
for bad in "" garbage NaN -0.5 2 "1.0.0" "; rm -rf /"; do
    [ "$(dec decide "$bad" balanced)" = "hold" ] && pass || fail "unusable signal '$bad' must → hold (got $(dec decide "$bad" balanced))"
done
# numeric thresholds: strict is stricter than lenient at the same score
[ "$(dec decide 0.6 strict)"  = "block" ] && pass || fail "0.6 strict → block"
[ "$(dec decide 0.6 lenient)" = "allow" ] && pass || fail "0.6 lenient → allow"
[ "$(dec decide 0.6 balanced)" = "hold" ] && pass || fail "0.6 balanced → hold"

# --- 2. magic-byte sniff ignores the extension --------------------------------
printf '\xff\xd8\xff\xe0JFIF' > "$T/a.txt"          # JPEG bytes, .txt name
[ "$(dec sniff "$T/a.txt")" = "image" ] && pass || fail "JPEG magic bytes → image (ignore .txt ext)"
printf '<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>' > "$T/b.png"  # SVG, .png name
[ "$(dec sniff "$T/b.png")" = "document" ] && pass || fail "SVG → document (script-bearing, not skipped)"
printf 'just some plain text' > "$T/c.bin"
[ "$(dec sniff "$T/c.bin")" = "text" ] && pass || fail "plain text → text"

# --- 3. FAIL-CLOSED with NO model/binary present (the common case) -----------
# Force an empty tools tree (VALARK_TOOLS_DIR is honoured by valark-env, and the runner
# resolves the llama binary there FIRST) so no classifier resolves → must HOLD (exit 2).
printf 'hello world' > "$T/txt"
printf '\x89PNG\r\n\x1a\n....' > "$T/img"
mkdir -p "$T/empty"
env VALARK_TOOLS_DIR="$T/empty" VALARK_MODELS_DIR="$T/empty" \
    bash "$MOD" check "$T/txt" --kind text >"$T/o1" 2>/dev/null; r1=$?
env VALARK_TOOLS_DIR="$T/empty" VALARK_MODELS_DIR="$T/empty" \
    bash "$MOD" check "$T/img" --kind image >"$T/o2" 2>/dev/null; r2=$?
[ "$r1" = 2 ] && grep -q '"decision":"hold"' "$T/o1" && pass || fail "no-model text check must HOLD (rc=$r1, $(cat "$T/o1"))"
[ "$r2" = 2 ] && grep -q '"decision":"hold"' "$T/o2" && pass || fail "no-model image check must HOLD (rc=$r2)"
# CRITICAL: it must NEVER allow (exit 0) with no classifier
[ "$r1" != 0 ] && [ "$r2" != 0 ] && pass || fail "no-model check must NEVER allow"

# --- 4. stub runner (VALARK_MODERATION_CMD): verdict → decision + exit code ---
cat > "$T/stub_unsafe" <<'EOF'
#!/bin/bash
echo unsafe
EOF
cat > "$T/stub_safe" <<'EOF'
#!/bin/bash
echo safe
EOF
cat > "$T/stub_junk" <<'EOF'
#!/bin/bash
echo "??? not a verdict"
EOF
cat > "$T/stub_hang" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$T"/stub_*
[ "$(VALARK_MODERATION_CMD="$T/stub_safe"   rc check "$T/txt" --kind text)" = 0 ] && pass || fail "stub safe → allow (exit 0)"
[ "$(VALARK_MODERATION_CMD="$T/stub_unsafe" rc check "$T/txt" --kind text)" = 1 ] && pass || fail "stub unsafe → block (exit 1)"
[ "$(VALARK_MODERATION_CMD="$T/stub_junk"   rc check "$T/txt" --kind text)" = 2 ] && pass || fail "stub junk → hold (exit 2)"
r=$(VALARK_MODERATION_TIMEOUT=1 VALARK_MODERATION_CMD="$T/stub_hang" rc check "$T/txt" --kind text)
[ "$r" = 2 ] && pass || fail "stub that hangs past timeout → hold (got $r)"

# --- 4b. PROSE fail-open guard (adversarial-review finding): a VLM answering in a
#        sentence must NOT downgrade an unsafe verdict to allow. "not safe for work"
#        contains the substring "safe" but is UNSAFE — must block, never allow.
cat > "$T/stub_prose_unsafe" <<'EOF'
#!/bin/bash
echo "This image is not safe for work."
EOF
cat > "$T/stub_prose_ambiguous" <<'EOF'
#!/bin/bash
echo "The picture shows a landscape at sunset with mountains."
EOF
chmod +x "$T"/stub_prose_*
r=$(VALARK_MODERATION_CMD="$T/stub_prose_unsafe" rc check "$T/img" --kind image)
[ "$r" = 1 ] && pass || fail "'not safe for work' prose must BLOCK, never allow (got exit $r)"
[ "$(VALARK_MODERATION_CMD="$T/stub_prose_unsafe" rc check "$T/img" --kind image)" != 0 ] && pass || fail "unsafe prose must NEVER allow (exit 0)"
r=$(VALARK_MODERATION_CMD="$T/stub_prose_ambiguous" rc check "$T/img" --kind image)
[ "$r" = 2 ] && pass || fail "ambiguous prose (no safe/unsafe verdict) must HOLD (got exit $r)"

# --- 4c. dangling flag as final arg must NOT hang, and must hold (adversarial finding)
r=$(timeout 5 bash "$MOD" check "$T/txt" --kind >/dev/null 2>&1; echo $?)
[ "$r" = 2 ] && pass || fail "dangling --kind must hold without hanging (got $r; 124=timeout/hang)"
r=$(timeout 5 bash "$MOD" check "$T/txt" --sensitivity >/dev/null 2>&1; echo $?)
[ "$r" = 2 ] && pass || fail "dangling --sensitivity must hold without hanging (got $r)"

# --- 5. over-size cap → hold (never OOM/allow) --------------------------------
head -c 1024 /dev/zero > "$T/big"
r=$(VALARK_MODERATION_MAX_BYTES=100 VALARK_MODERATION_CMD="$T/stub_safe" rc check "$T/big" --kind text)
[ "$r" = 2 ] && pass || fail "over-cap file must hold (got $r)"

echo "moderation: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
