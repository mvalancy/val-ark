#!/bin/bash
###############################################################################
# Test: "Ask Val Ark" SERVER endpoints (roadmap Phase 8, slice 1 — the on-box
# assistant; issue #67).
#
# Exercises the live HTTP surface OFFLINE, with NO real model:
#   GET  /api/status/ask   — readiness {ready, runtime, model, reason} (no inference)
#   POST /api/ask          — stream the answer as SSE frames; FAIL-SOFT; gated
#
# The runtime is driven with a STUB `llama-completion` on a fake native-tools tree
# plus a fake assistant .gguf, so the REAL argv-spawn path runs (VALARK_TEST_NO_SPAWN
# is deliberately UNSET here). Invariants asserted:
#   * a question returns the streamed stub answer + a terminal `event: done`
#   * FAIL-SOFT: no model / no binary → 200 with a friendly `event: soft`, never 500
#   * READ-GATE: on a Passworded box a non-admin LAN caller is 401'd (POST + status)
#   * NO SHELL INJECTION: `;`, `$(...)`, backticks in the question reach the stub as
#     LITERAL argv text — no file is created/deleted, no command substitution runs
#   * ADMISSION CAP: over the concurrency cap → 503 {busy:true} (never unbounded)
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

ALL_PIDS=""
T="$(mktemp -d)"
cleanup() { for p in $ALL_PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

# Native-tools platform dir the server resolves (mirrors moderation.sh / server.js).
case "$(uname -s)-$(uname -m)" in
  Darwin-*)                 PLAT=macos-arm64 ;;
  Linux-aarch64|Linux-arm64) PLAT=linux-arm64 ;;
  *)                        PLAT=linux-x86_64 ;;
esac

# --- fixture trees ----------------------------------------------------------------
# (1) tools/ with a stub single-shot llama binary. It echoes the -p PROMPT back as the
#     "answer" (so we can prove the raw question arrived), and stalls on SLEEPME (so we
#     can exercise the concurrency cap). It ignores every other flag.
mkdir -p "$T/tools/$PLAT/llama-cpp"
cat > "$T/tools/$PLAT/llama-cpp/llama-completion" <<'EOF'
#!/bin/bash
prompt=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then prompt="$2"; shift 2; else shift; fi
done
case "$prompt" in *SLEEPME*) sleep 4 ;; esac
printf 'STUBANSWER:%s\n' "$prompt"
EOF
chmod +x "$T/tools/$PLAT/llama-cpp/llama-completion"
# empty tools tree (no binary) for the runtime fail-soft case
mkdir -p "$T/tools-empty/$PLAT/llama-cpp"

# (2) models/ with a fake assistant gguf > 10 MB (the >10M floor is verify.sh's filter)
mkdir -p "$T/models/assistant/qwen2.5-1.5b-instruct"
head -c 11000000 /dev/zero > "$T/models/assistant/qwen2.5-1.5b-instruct/model.gguf"
# empty models tree for the model fail-soft case
mkdir -p "$T/models-empty"

mkdir -p "$T/content/zim"

# --- server boot helper (start in the PARENT, track the PID — never in $() ) ------
# boot <name> <port> <toolsdir> <modelsdir> <statedir> [extra env KEY=VAL ...]
boot() {
  local name="$1" port="$2" tools="$3" models="$4" state="$5"; shift 5
  mkdir -p "$state"
  env VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
      VALARK_WEB_PORT="$port" VALARK_HTTPS_PORT="$((port + 9000))" \
      VALARK_ASK_MAX_CONCURRENT=1 \
      VALARK_TOOLS_DIR="$tools" VALARK_MODELS_DIR="$models" \
      VALARK_STATE_DIR="$state" VALARK_CONTENT_DIR="$T/content" \
      "$@" \
      "$NODE" "$ROOT/scripts/server.js" "$port" >"$T/$name.log" 2>&1 &
  local pid=$!; ALL_PIDS="$ALL_PIDS $pid"
  local up=0 i
  for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && { up=1; break; }; done
  [ "$up" = 1 ] || { fail "$name server did not start on :$port"; return 1; }
  return 0
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }

###############################################################################
# Server A — full runtime (stub binary + fake model). Happy path, injection, cap.
###############################################################################
PA=3990; BA="http://127.0.0.1:$PA"
boot A "$PA" "$T/tools" "$T/models" "$T/stateA" && pass || true

# --- 1. readiness: ready:true, names surfaced, reason ok --------------------------
S="$(curl -s --max-time 6 "$BA/api/status/ask")"
echo "$S" | grep -q '"ready":true'       && pass || fail "status/ask ready:true when binary+model present (got: $S)"
echo "$S" | grep -q '"reason":"ok"'       && pass || fail "status/ask reason ok (got: $S)"
echo "$S" | grep -q 'llama-completion'     && pass || fail "status/ask surfaces the resolved runtime name (got: $S)"
echo "$S" | grep -q 'model.gguf'           && pass || fail "status/ask surfaces the resolved model name (got: $S)"

# --- 2. happy path: a question streams the stub answer + a terminal done ----------
askpost() { curl -s -N --max-time 15 -X POST -H 'Content-Type: application/json' -d "$1" "$BA/api/ask"; }
OUT="$(askpost '{"question":"how do I add a disk?"}')"
echo "$OUT" | grep -q 'STUBANSWER:'        && pass || fail "ask streams the stub answer (got: $OUT)"
echo "$OUT" | grep -q 'event: token'       && pass || fail "ask emits token events"
echo "$OUT" | grep -q 'event: done'        && pass || fail "ask emits a terminal done event"
echo "$OUT" | grep -q 'how do I add a disk' && pass || fail "the question reached the runtime verbatim (got: $OUT)"

# empty question → soft, never a spawn
E="$(askpost '{"question":"   "}')"
echo "$E" | grep -q '"reason":"empty"'     && pass || fail "empty question → soft empty (got: $E)"

# --- 3. NO SHELL INJECTION: metacharacters in the question are inert argv data -----
# Build the body so THIS shell doesn't expand the payload: an unquoted heredoc expands
# only the canary paths ($C*), while \$(...) and \`...\` are written LITERALLY. If the
# server ever built a shell string, the rm/touch/backticks would fire on the box.
C_KEEP="$T/canary_keep";  : > "$C_KEEP"        # must survive (a bare `rm -rf` target)
C_SUB="$T/canary_subst"                         # must NOT appear ($(touch) must not run)
C_TICK="$T/canary_tick"                         # must NOT appear (`touch` must not run)
cat > "$T/inj.json" <<JSON
{"question":"help me now; rm -rf $C_KEEP \$(touch $C_SUB) \`touch $C_TICK\` end"}
JSON
IOUT="$(curl -s -N --max-time 15 -X POST -H 'Content-Type: application/json' --data @"$T/inj.json" "$BA/api/ask")"
echo "$IOUT" | grep -q 'rm -rf'            && pass || fail "injection text must pass through as literal data (got: $IOUT)"
echo "$IOUT" | grep -q 'touch'             && pass || fail "injection substitution text must appear literally, not execute"
[ -e "$C_KEEP" ]                            && pass || fail "SECURITY: bare 'rm -rf' target was deleted — shell executed the question!"
[ ! -e "$C_SUB" ]                           && pass || fail "SECURITY: \$(touch) ran — command substitution executed!"
[ ! -e "$C_TICK" ]                          && pass || fail "SECURITY: backtick touch ran — command substitution executed!"

# --- 4. ADMISSION CAP: over the concurrency cap (=1) → 503 busy, never unbounded ---
curl -s -N --max-time 12 -X POST -H 'Content-Type: application/json' -d '{"question":"SLEEPME please wait"}' "$BA/api/ask" >/dev/null &
SLOWPID=$!; ALL_PIDS="$ALL_PIDS $SLOWPID"
sleep 1                                          # first ask has spawned the stub (in-flight=1)
curl -s -o "$T/busy.out" -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"question":"quick one"}' "$BA/api/ask" > "$T/busy.code"
[ "$(cat "$T/busy.code")" = 503 ]           && pass || fail "second concurrent ask over cap → 503 (got $(cat "$T/busy.code"))"
grep -q '"busy":true' "$T/busy.out"         && pass || fail "over-cap response says busy (got: $(cat "$T/busy.out"))"
wait "$SLOWPID" 2>/dev/null

###############################################################################
# Server B — binary present, NO model → FAIL-SOFT reason:model (200, not 500).
###############################################################################
PB=3991; BB="http://127.0.0.1:$PB"
boot B "$PB" "$T/tools" "$T/models-empty" "$T/stateB" && pass || true
echo "$(curl -s --max-time 6 "$BB/api/status/ask")" | grep -q '"reason":"model"' && pass || fail "no-model → status reason model"
c=$(code -X POST -H 'Content-Type: application/json' -d '{"question":"hi"}' "$BB/api/ask")
[ "$c" = 200 ]                              && pass || fail "no-model ask must be 200 (fail-soft), got $c"
MB="$(curl -s -N --max-time 8 -X POST -H 'Content-Type: application/json' -d '{"question":"hi"}' "$BB/api/ask")"
echo "$MB" | grep -q '"reason":"model"'     && pass || fail "no-model ask streams soft reason model (got: $MB)"
echo "$MB" | grep -qi 'Models tab'          && pass || fail "no-model soft message points at the Models tab"
echo "$MB" | grep -q 'STUBANSWER'           && fail "no-model must NOT run any model" || pass

###############################################################################
# Server C — no binary at all → FAIL-SOFT reason:runtime (200, not 500).
###############################################################################
PC=3992; BC="http://127.0.0.1:$PC"
boot C "$PC" "$T/tools-empty" "$T/models" "$T/stateC" && pass || true
echo "$(curl -s --max-time 6 "$BC/api/status/ask")" | grep -q '"reason":"runtime"' && pass || fail "no-binary → status reason runtime"
c=$(code -X POST -H 'Content-Type: application/json' -d '{"question":"hi"}' "$BC/api/ask")
[ "$c" = 200 ]                              && pass || fail "no-binary ask must be 200 (fail-soft), got $c"
RC="$(curl -s -N --max-time 8 -X POST -H 'Content-Type: application/json' -d '{"question":"hi"}' "$BC/api/ask")"
echo "$RC" | grep -q '"reason":"runtime"'   && pass || fail "no-binary ask streams soft reason runtime (got: $RC)"

###############################################################################
# Server D — Passworded + remote client → READ-GATE 401 (POST + status).
###############################################################################
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("askpass12","admin",d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/stateD"
PD=3993; BD="http://127.0.0.1:$PD"
boot D "$PD" "$T/tools" "$T/models" "$T/stateD" VALARK_TEST_FORCE_REMOTE=1 && pass || true
[ "$(code -X POST -H 'Content-Type: application/json' -d '{"question":"hi"}' "$BD/api/ask")" = 401 ] \
    && pass || fail "POST /api/ask must be 401 for a non-admin on a Passworded box"
[ "$(code "$BD/api/status/ask")" = 401 ] \
    && pass || fail "GET /api/status/ask must be 401 (read-gated) on a Passworded box"
# an admin session gets through the gate (proves 401 above is the gate, not a broken route)
curl -s -c "$T/cjD" -X POST -H 'Content-Type: application/json' -d '{"password":"askpass12"}' "$BD/api/auth/login" >/dev/null
[ "$(code -b "$T/cjD" "$BD/api/status/ask")" = 200 ] \
    && pass || fail "signed-in admin can read /api/status/ask on a Passworded box"

echo "ask-api: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
