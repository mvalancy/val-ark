#!/bin/bash
###############################################################################
# Test: every community sub-app's WEB port binds 127.0.0.1, whatever VALARK_BIND is (#317).
#
# Owners set VALARK_BIND=0.0.0.0 so mail's IMAP/submission (and native IRC) face the
# LAN. That must not also put MicroBin or NodeBB on the LAN directly, where the proxy's
# upload sandbox, the read-wall and the internet-peer refusal don't apply. MicroBin is
# launched for real against a stub binary that records its environment; NodeBB's config
# is generated (and an old one repaired) with `forum.sh config`, no NodeBB needed.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
. "$ROOT/tests/lib/require-cmd.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
require_python3 "service web-port binds (stub MicroBin + config checks)"

T="$(mktemp -d)"; STUB_PID=""
trap 'stop_pids "$STUB_PID"; rm -rf "$T"' EXIT
trap_signals
# Keep valark-env.sh away from the real data root and the repo's .env.
export VAL_ARK_DATA="$T/data" VAL_ARK_CONFIG="$T/none.env" VALARK_TOOLS_DIR="$T/tools" VALARK_STATE_DIR="$T/state"
mkdir -p "$VAL_ARK_DATA" "$T/state"

# --- paste (MicroBin): a stub binary records MICROBIN_* and serves the proxy path ---------
case "$(uname -s)/$(uname -m)" in
    Linux/aarch64|Linux/arm64) sub=linux-arm64 ;;
    Linux/*) sub=linux-x86_64 ;;
    Darwin/*) sub=macos-arm64 ;;
    *) sub=windows-x64 ;;
esac
bin="$T/tools/$sub/paste/microbin"; [ "$sub" = windows-x64 ] && bin="${bin}.exe"
mkdir -p "$(dirname "$bin")"
cat > "$bin" <<EOF
#!/bin/bash
env | grep '^MICROBIN_' | grep -v PASSWORD > "$T/microbin.env"
mkdir -p "\$MICROBIN_DATA_DIR/app/paste"
exec python3 -I -m http.server --bind "\$MICROBIN_BIND" --directory "\$MICROBIN_DATA_DIR" "\$MICROBIN_PORT"
EOF
chmod +x "$bin"
PP=$(free_port)
VALARK_BIND=0.0.0.0 PASTE_PORT="$PP" timeout 60 bash "$ROOT/scripts/services/paste.sh" start >"$T/paste.out" 2>&1
STUB_PID="$(cat "$T/state/services/paste/paste.pid" 2>/dev/null)"
if [ -s "$T/microbin.env" ]; then
    grep -qx 'MICROBIN_BIND=127.0.0.1' "$T/microbin.env" && pass \
      || fail "MicroBin must bind 127.0.0.1 with VALARK_BIND=0.0.0.0 (got: $(grep BIND "$T/microbin.env"))"
    grep -qx "MICROBIN_PORT=$PP" "$T/microbin.env" && pass || fail "MicroBin must get PASTE_PORT"
else
    fail "stub MicroBin was not launched ($(tail -3 "$T/paste.out"))"
fi
grep -q '0\.0\.0\.0' "$T/paste.out" && fail "paste.sh must not report a 0.0.0.0 web address ($(grep 0.0.0.0 "$T/paste.out"))" || pass
VALARK_BIND=0.0.0.0 PASTE_PORT="$PP" timeout 30 bash "$ROOT/scripts/services/paste.sh" stop >/dev/null 2>&1
stop_pids "$STUB_PID"; STUB_PID=""

# --- forum (NodeBB): the generated config binds loopback; an old config is repaired ------
CFG="$T/state/services/forum/config.json"
bind_of() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("bind_address"))' "$CFG" 2>/dev/null; }
VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
[ "$(bind_of)" = "127.0.0.1" ] && pass || fail "new NodeBB config must bind 127.0.0.1 with VALARK_BIND=0.0.0.0 (got $(bind_of); $(tail -2 "$T/forum.out"))"
grep -q '0\.0\.0\.0' "$CFG" && fail "new NodeBB config must not mention 0.0.0.0" || pass
printf '{\n    "url": "http://localhost/app/forum",\n    "port": 4567,\n    "bind_address": "0.0.0.0",\n    "database": "redis"\n}\n' > "$CFG"
VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
[ "$(bind_of)" = "127.0.0.1" ] && pass || fail "a pre-#317 config with bind_address 0.0.0.0 must be repaired (got $(bind_of))"
python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c["port"]==4567 and c["database"]=="redis" else 1)' "$CFG" \
  && pass || fail "repairing bind_address must keep the rest of the config"
printf '{ "url": "http://localhost/app/forum", "port": 4567 }\n' > "$CFG"
VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
[ "$(bind_of)" = "127.0.0.1" ] && pass || fail "a config without bind_address (NodeBB then binds every interface) must get 127.0.0.1 (got $(bind_of))"

# --- chat (The Lounge) + mail (alps): web UIs are hard-wired to loopback ------------------
grep -q 'bind: "127.0.0.1"' "$ROOT/scripts/services/chat.sh" && ! grep -qE 'bind: "\$\{?(BIND|VALARK_BIND)' "$ROOT/scripts/services/chat.sh" \
  && pass || fail "The Lounge config must bind 127.0.0.1, not VALARK_BIND"
grep -q -- '-addr "127.0.0.1:${ALPS_PORT}"' "$ROOT/scripts/services/mail.sh" && pass || fail "alps must listen on 127.0.0.1"
# An old config whose url points at 0.0.0.0 is repaired too; other keys and the file mode survive,
# and no temp file is left behind (#334).
printf '{\n    "url": "http://0.0.0.0/app/forum",\n    "secret": "keepme",\n    "port": 4567,\n    "bind_address": "0.0.0.0"\n}\n' > "$CFG"; chmod 600 "$CFG"
VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
grep -q '"url": "http://localhost/app/forum"' "$CFG" && pass || fail "an old 0.0.0.0 url must be repaired ($(cat "$CFG"))"
grep -q '"secret": "keepme"' "$CFG" && pass || fail "the repair must keep the other keys"
[ "$(stat -c %a "$CFG")" = "600" ] && pass || fail "the repair must keep the file mode (got $(stat -c %a "$CFG"))"
ls "$CFG".tmp* >/dev/null 2>&1 && fail "no temp file may be left behind" || pass
# A planted world-readable temp file can't loosen the config's mode; IPv6/uppercase "any" urls
# are repaired; and the python path (no node) behaves the same (review of #336).
for path in node python; do
    printf '{ "url": "HTTP://[::]:4567/app/forum", "secret": "keepme", "bind_address": "0.0.0.0" }\n' > "$CFG"; chmod 600 "$CFG"
    install -m 666 /dev/null "$CFG.tmp"
    if [ "$path" = python ]; then
        mkdir -p "$T/nonode"; for b in bash python3 cat head od tr mkdir grep sed dirname basename date ls rm mv chmod stat uname id readlink; do
            p=$(command -v "$b") && ln -sf "$p" "$T/nonode/$b"; done
        PATH="$T/nonode" VALARK_NODE_DIR=/nonexistent VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
    else
        VALARK_BIND=0.0.0.0 bash "$ROOT/scripts/services/forum.sh" config >"$T/forum.out" 2>&1
    fi
    grep -q '"url": "http://localhost/app/forum"' "$CFG" && pass || fail "$path: an IPv6/uppercase any-address url must be repaired ($(cat "$CFG"); $(tail -2 "$T/forum.out"))"
    [ "$(stat -c %a "$CFG")" = "600" ] && pass || fail "$path: a planted 666 temp file must not loosen the config (got $(stat -c %a "$CFG"))"
    rm -f "$CFG.tmp"
done
# No web-UI bind may come from VALARK_BIND in the paste/forum scripts.
grep -nE '(MICROBIN_BIND|bind_address).*VALARK_BIND|^BIND="\$\{VALARK_BIND' "$ROOT/scripts/services/paste.sh" "$ROOT/scripts/services/forum.sh" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -q . && fail "paste/forum web binds must not read VALARK_BIND" || pass

echo "service-binds: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
