#!/bin/bash
###############################################################################
# Test: verify.sh's tiny-LLM inference check exercises the curated assistant
# models, not only models/llm (issue #68).
#
# The Phase-8 setup-assistant chat models are curated to models/assistant
# (data/models-extra.tsv). Before the fix, verify.sh step 3 searched ONLY
# models/llm, so a footprint-capped / mid-fill box that holds only an assistant
# gguf reported SKIP every loop cycle and never caught a corrupt assistant
# model. This drives verify.sh against fake model trees (a stub llama-cli that
# just exits 0, sparse >10M ggufs) and asserts the model-search logic:
#   A) assistant-only tree  -> inference check RUNS against the assistant gguf
#   B) assistant + llm tree  -> still picks the SMALLEST overall (llm, not
#                               "assistant first")
#   C) bare box (no gguf)    -> SKIP, never a hard FAIL (fail-soft)
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# A stub llama-cli that "infers" successfully (exit 0), placed under every
# platform tools dir so native_tools_dir() finds it regardless of host arch.
TLS="$T/tools"
for plat in linux-x86_64 linux-arm64 macos-arm64 windows-x64; do
    mkdir -p "$TLS/$plat/llama-cpp"
    cat > "$TLS/$plat/llama-cpp/llama-cli" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TLS/$plat/llama-cpp/llama-cli"
done

# gguf helper: sparse file of N MiB (apparent size only; content is irrelevant —
# the stub llama-cli ignores it). Kept >10M so verify.sh's -size +10M filter hits.
mkgguf() { mkdir -p "$(dirname "$1")"; truncate -s "$2" "$1"; }

run_verify() { # $1=models_dir  $2=state_dir  -> prints verify.sh stdout
    VAL_ARK_DATA="$T" VALARK_MODELS_DIR="$1" VALARK_TOOLS_DIR="$TLS" \
    VALARK_STATE_DIR="$2" VALARK_CONTENT_DIR="$T/content" \
    VALARK_WEB_PORT=1 FORCE_COLOR=0 \
        timeout 90 bash "$ROOT/scripts/verify.sh" local 2>/dev/null
}

# --- Case A: assistant-only tree — the inference check must RUN (the fix) ------
MDL_A="$T/models-a"
mkgguf "$MDL_A/assistant/qwen2.5-1.5b-instruct/assistant-only-A1.gguf" 15M
OUT_A="$(run_verify "$MDL_A" "$T/state-a")"
if echo "$OUT_A" | grep -q 'llama.cpp inference works (assistant-only-A1.gguf)'; then pass
else fail "assistant-only tree must exercise the assistant gguf (got: $(echo "$OUT_A" | grep -i inference))"; fi
# and it must NOT fall through to the SKIP branch
if echo "$OUT_A" | grep -q 'not available for inference check'; then
    fail "assistant-only tree must not SKIP the inference check"; else pass; fi
# verify.json is written and attributes the check to the 'models' component
if grep -q '"comp": "models"' "$T/state-a/verify.json" 2>/dev/null; then pass
else fail "verify.json must record the inference check under the models component"; fi

# --- Case B: assistant + llm — smallest-overall-first (not "assistant first") --
MDL_B="$T/models-b"
mkgguf "$MDL_B/llm/qwen2.5-0.5b/llm-small-B1.gguf" 11M          # smaller
mkgguf "$MDL_B/assistant/qwen2.5-1.5b-instruct/assistant-big-B2.gguf" 20M  # larger
OUT_B="$(run_verify "$MDL_B" "$T/state-b")"
if echo "$OUT_B" | grep -q 'llama.cpp inference works (llm-small-B1.gguf)'; then pass
else fail "with both present the SMALLEST gguf must be picked (got: $(echo "$OUT_B" | grep -i inference))"; fi

# --- Case C: bare box (llama-cli present, no gguf) — fail-soft SKIP, not FAIL --
MDL_C="$T/models-c"; mkdir -p "$MDL_C"
OUT_C="$(run_verify "$MDL_C" "$T/state-c")"
if echo "$OUT_C" | grep -q 'not available for inference check'; then pass
else fail "no-gguf box must SKIP the inference check (got: $(echo "$OUT_C" | grep -i inference))"; fi
if echo "$OUT_C" | grep -qi 'inference failed'; then
    fail "no-gguf box must never hard-FAIL the inference check"; else pass; fi

echo "verify-models: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
