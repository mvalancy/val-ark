#!/bin/bash
###############################################################################
# Test: `./start.sh serve` honors VALARK_WEB_PORT (issue #105).
#
# start.sh `serve)` used to pass a HARDCODED default port (3000) as argv to
# server.js, and server.js prefers process.argv[2] over VALARK_WEB_PORT — so
# `./start.sh serve` bound 3000 no matter what VALARK_WEB_PORT said, while the
# bootstrap hand-off printed the .env port as the wizard URL → a dead link.
#
# The fix: `serve` with NO explicit port passes NOTHING to server.js (server.js
# owns the VALARK_WEB_PORT || 3000 fallback); an explicit `serve <port>` still
# wins; and the printed URL is derived the SAME way so it agrees with the bound
# port. This asserts that resolution WITHOUT starting a real server — node is
# stubbed to record the argv it receives + the port server.js WOULD bind
# (argv[2] || VALARK_WEB_PORT || 3000), then exit.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A stub `node` at the exact path start.sh probes first ($HOME/.local/node/bin/node).
# It mirrors server.js PORT resolution and records the outcome, then exits WITHOUT
# starting anything. $1 = server.js path, $2 = optional explicit port.
mkdir -p "$T/home/.local/node/bin"
cat > "$T/home/.local/node/bin/node" <<'STUB'
#!/bin/bash
port="${2:-${VALARK_WEB_PORT:-3000}}"
{
  echo "ARGC=$#"
  echo "PORTARG=${2:-<none>}"
  echo "RESOLVED=$port"
} > "$STUB_OUT"
exit 0
STUB
chmod +x "$T/home/.local/node/bin/node"

# Run the REAL serve dispatch against an isolated SCRIPT_DIR (own .env, own node)
# so the repo's real .env can't leak into the assertion. Copy start.sh verbatim.
cp "$ROOT/start.sh" "$T/start.sh"
mkdir -p "$T/scripts"   # server.js path is passed but the stub never reads it

# run_serve <env-VALARK_WEB_PORT-or-empty> <dotenv-port-or-empty> [explicit-port]
# Echoes the start.sh stdout (the printed URL line); STUB_OUT holds the argv record.
run_serve() {
    local envport="$1" dotenv="$2" explicit="${3:-}"
    : > "$T/out"; rm -f "$T/.env"
    [ -n "$dotenv" ] && printf 'VALARK_WEB_PORT=%s\n' "$dotenv" > "$T/.env"
    STUB_OUT="$T/stub" HOME="$T/home" \
      env ${envport:+VALARK_WEB_PORT="$envport"} \
      bash "$T/start.sh" serve ${explicit:+"$explicit"} > "$T/out" 2>&1
}
recorded() { sed -n "s/^$1=//p" "$T/stub"; }
printed_port() { sed -n 's#.*http://localhost:\([0-9][0-9]*\).*#\1#p' "$T/out" | head -1; }

# --- 1. VALARK_WEB_PORT set (env), NO port arg → server binds that port ----------
run_serve 3995 "" ""
[ "$(recorded RESOLVED)" = 3995 ] && pass || fail "env VALARK_WEB_PORT=3995 + bare serve must resolve 3995 (got $(recorded RESOLVED))"
[ "$(recorded PORTARG)" = "<none>" ] && pass || fail "bare serve must pass NO port arg to server.js (got $(recorded PORTARG))"
[ "$(printed_port)" = 3995 ] && pass || fail "printed URL must show 3995, matching the bound port (got $(printed_port))"

# --- 2. Explicit `serve 8080` still wins, even with VALARK_WEB_PORT set ----------
run_serve 3995 "" 8080
[ "$(recorded RESOLVED)" = 8080 ] && pass || fail "explicit 'serve 8080' must resolve 8080 (got $(recorded RESOLVED))"
[ "$(recorded PORTARG)" = 8080 ] && pass || fail "explicit 'serve 8080' must pass 8080 as argv (got $(recorded PORTARG))"
[ "$(printed_port)" = 8080 ] && pass || fail "printed URL must show 8080 (got $(printed_port))"

# --- 3. Nothing set, bare serve → default 3000 ----------------------------------
run_serve "" "" ""
[ "$(recorded RESOLVED)" = 3000 ] && pass || fail "bare serve with nothing set must resolve 3000 (got $(recorded RESOLVED))"
[ "$(recorded PORTARG)" = "<none>" ] && pass || fail "bare serve (default) must still pass NO port arg (got $(recorded PORTARG))"
[ "$(printed_port)" = 3000 ] && pass || fail "printed URL must show 3000 (got $(printed_port))"

# --- 4. VALARK_WEB_PORT only in .env (no env var), bare serve -------------------
# start.sh must NOT clobber it (passes no port), and the printed URL must show the
# .env port so it agrees with what server.js (which reads .env itself) will bind.
run_serve "" 4321 ""
[ "$(recorded PORTARG)" = "<none>" ] && pass || fail ".env-only port: bare serve must pass NO port arg so server.js reads .env (got $(recorded PORTARG))"
[ "$(printed_port)" = 4321 ] && pass || fail ".env-only port: printed URL must show the .env port 4321 (got $(printed_port))"

echo "serve-port: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
