#!/bin/bash
###############################################################################
# Test: on-device moderation decision core (roadmap Phase 7) — FAIL-CLOSED.
#
# The whole point is that content is HELD (never silently allowed) whenever the
# classifier can't give a usable verdict — the common bare-box/CI case with no
# model. Exercises the pure decide() unit, magic-byte sniff, the stub runner, the
# no-model fail-closed path, and the #50 regression (REPL builds that echo the prompt
# — whose own "unsafe" must never flag clean content — plus per-binary flag choice).
# No real model required.
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

# --- 4d. REPL prompt-echo regression (#50): a llama build that echoes the prompt puts
#        the prompt's OWN "unsafe" into stdout, and unsafe-wins parsing flagged 100% of
#        clean content as blocked. Only text after the final "Answer only:" sentinel
#        line is the model's verdict — the echo itself must never decide.
cat > "$T/stub_echo_safe" <<'EOF'
#!/bin/bash
printf '> Task: classify the following user content as safe or unsafe.\nContent: The weather is lovely today and I baked some bread.\nAnswer only: safe or unsafe.\nsafe\n'
EOF
cat > "$T/stub_echo_unsafe" <<'EOF'
#!/bin/bash
printf '> Task: classify the following user content as safe or unsafe.\nContent: some nasty stuff\nAnswer only: safe or unsafe.\nunsafe\n'
EOF
cat > "$T/stub_echo_noanswer" <<'EOF'
#!/bin/bash
printf '> Task: classify the following user content as safe or unsafe.\nContent: x\nAnswer only: safe or unsafe.\n'
EOF
chmod +x "$T"/stub_echo_*
r=$(VALARK_MODERATION_CMD="$T/stub_echo_safe" rc check "$T/txt" --kind text)
[ "$r" = 0 ] && pass || fail "echoed prompt + 'safe' answer must ALLOW — the echo's own 'unsafe' must not flag clean content (#50, got exit $r)"
r=$(VALARK_MODERATION_CMD="$T/stub_echo_unsafe" rc check "$T/txt" --kind text)
[ "$r" = 1 ] && pass || fail "echoed prompt + 'unsafe' answer must still BLOCK (got exit $r)"
r=$(VALARK_MODERATION_CMD="$T/stub_echo_noanswer" rc check "$T/txt" --kind text)
[ "$r" = 2 ] && pass || fail "echoed prompt with NO answer after the sentinel must HOLD, never allow (got exit $r)"

# --- 4e. binary selection + flags (#50): emulate the mirrored b7824 build. Its
#        llama-cli is a REPL (rejects -no-cnv, echoes the prompt); the single-shot
#        behavior ships as llama-completion; llama-mtmd-cli REJECTS -st/-no-cnv
#        outright. The runner must pick llama-completion, suppress the prompt echo,
#        use conversation mode (chat template), and pass mtmd only flags it accepts.
FT="$T/ftools"; FM="$T/fmodels"
mkdir -p "$FM/safety" "$FM/vlm"
truncate -s 11M "$FM/safety/fake-guard.gguf"
truncate -s 11M "$FM/vlm/fake-vlm.gguf"
: > "$FM/vlm/fake-mmproj.gguf"
cat > "$T/fake-llama-completion" <<'EOF'
#!/bin/bash
[ -n "${MODTEST_ARGLOG:-}" ] && printf '%s\n' "$*" > "$MODTEST_ARGLOG"
echo safe
EOF
cat > "$T/fake-llama-cli" <<'EOF'
#!/bin/bash
# REPL build: echoes the prompt (with its "unsafe") and never answers cleanly.
echo "> Task: classify the following user content as safe or unsafe. Answer only: safe or unsafe."
EOF
cat > "$T/fake-llama-mtmd-cli" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in -st|-no-cnv) echo "error: invalid argument: $a" >&2; exit 1 ;; esac; done
echo safe
EOF
for p in linux-arm64 linux-x86_64 macos-arm64; do        # native tree per host arch
    mkdir -p "$FT/$p/llama-cpp"
    cp "$T/fake-llama-completion" "$FT/$p/llama-cpp/llama-completion"
    cp "$T/fake-llama-cli"        "$FT/$p/llama-cpp/llama-cli"
    cp "$T/fake-llama-mtmd-cli"   "$FT/$p/llama-cpp/llama-mtmd-cli"
    chmod +x "$FT/$p/llama-cpp/"*
done
r=$(env VALARK_TOOLS_DIR="$FT" VALARK_MODELS_DIR="$FM" MODTEST_ARGLOG="$T/arglog" \
    bash "$MOD" check "$T/txt" --kind text >/dev/null 2>&1; echo $?)
[ "$r" = 0 ] && pass || fail "runner must prefer single-shot llama-completion over the REPL llama-cli (#50, got rc $r)"
grep -q -- '--no-display-prompt' "$T/arglog" 2>/dev/null && pass || fail "text invocation must pass --no-display-prompt (prompt echo carries 'unsafe')"
grep -qE '(^| )-cnv( |$)' "$T/arglog" 2>/dev/null && ! grep -qE '(^| )-no-cnv( |$)' "$T/arglog" 2>/dev/null \
    && pass || fail "text invocation must use conversation mode (-cnv, guard chat template) and never -no-cnv (raw completion continues the prompt)"
r=$(env VALARK_TOOLS_DIR="$FT" VALARK_MODELS_DIR="$FM" \
    bash "$MOD" check "$T/img" --kind image >/dev/null 2>&1; echo $?)
[ "$r" = 0 ] && pass || fail "image invocation must not pass -st/-no-cnv (llama-mtmd-cli rejects them → every image was held, #50; got rc $r)"
# a modern mirror shipping ONLY llama-completion must still count as text-ready
FT2="$T/ftools2"
for p in linux-arm64 linux-x86_64 macos-arm64; do
    mkdir -p "$FT2/$p/llama-cpp"
    cp "$T/fake-llama-completion" "$FT2/$p/llama-cpp/llama-completion"
    chmod +x "$FT2/$p/llama-cpp/llama-completion"
done
out=$(env VALARK_TOOLS_DIR="$FT2" VALARK_MODELS_DIR="$FM" bash "$MOD" ready 2>/dev/null)
printf '%s' "$out" | grep -q '"text":true' && pass || fail "mod_ready must probe llama-completion too (got: $out)"

# --- 5. over-size cap → hold (never OOM/allow) --------------------------------
head -c 1024 /dev/zero > "$T/big"
r=$(VALARK_MODERATION_MAX_BYTES=100 VALARK_MODERATION_CMD="$T/stub_safe" rc check "$T/big" --kind text)
[ "$r" = 2 ] && pass || fail "over-cap file must hold (got $r)"

echo "moderation: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
