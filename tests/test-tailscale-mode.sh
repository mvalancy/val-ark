#!/bin/bash
###############################################################################
# Test: Tailscale userspace-networking detection (issue #311).
#
# In userspace-networking mode tailscaled connects onward from 127.0.0.1, so every
# tailnet peer looks like the box itself (the Admin). scripts/lib/tailscale-mode.sh
# detects it; the loop (step 2g) and the server write state/tailscale.json; the
# server raises a critical notification and the Health detail carries the result.
#
# Everything is stubbed: a fake `tailscale` CLI (VALARK_TAILSCALE_CMD), a fake /proc
# (VALARK_TAILSCALE_PROC) and a fake /sys/class/net (VALARK_TAILSCALE_SYSNET). No
# real tailscale command runs. Every server started here is stopped on exit.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
DET="$ROOT/scripts/lib/tailscale-mode.sh"

T="$(mktemp -d)"; SRV_PID=""
trap 'stop_pids "$SRV_PID"; rm -rf "$T"' EXIT
trap_signals

bash -n "$DET" && pass || fail "tailscale-mode.sh must be valid bash"

# --- fixtures -----------------------------------------------------------------
# fake_proc DIR ARG...  -> DIR/<pid>/cmdline holding ARG... NUL-separated (plus an
# unrelated process so the scan has something to skip).
fake_proc() {
    local d="$1"; shift
    mkdir -p "$d/1" "$d/4242"
    printf '/sbin/init\0splash\0' > "$d/1/cmdline"
    [ "$#" -gt 0 ] && printf '%s\0' "$@" > "$d/4242/cmdline"
    return 0
}
# fake_net DIR IFACE...  -> DIR/<iface> entries
fake_net() { local d="$1"; shift; mkdir -p "$d"; local i; for i in "$@"; do mkdir -p "$d/$i"; done; }
# stub CLI that answers `status --json` with a given TUN flag (or fails)
mk_stub() {  # $1=path $2=true|false|fail
    case "$2" in
        fail) printf '#!/bin/bash\necho "failed to connect to local tailscaled" >&2; exit 1\n' > "$1" ;;
        *) cat > "$1" <<EOF
#!/bin/bash
# Read-only stub: only "status --json" is answered; anything else is refused.
[ "\$1" = status ] && [ "\$2" = --json ] || { echo "stub: refused \$*" >&2; exit 2; }
printf '{\n  "Version": "1.0.0-stub",\n  "TUN": $2,\n  "BackendState": "Running"\n}\n'
EOF
        ;;
    esac
    chmod +x "$1"
}
mk_stub "$T/ts-kernel" true
mk_stub "$T/ts-user" false
mk_stub "$T/ts-fail" fail

fake_proc "$T/p-none"
fake_proc "$T/p-kernel" /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock
fake_proc "$T/p-user"   /usr/sbin/tailscaled --tun=userspace-networking --socks5-server=localhost:1055
fake_proc "$T/p-split"  tailscaled -tun userspace-networking
fake_proc "$T/p-custom" /usr/sbin/tailscaled --tun=ts9
fake_proc "$T/p-child"  /usr/sbin/tailscaled be-child ssh --tun=userspace-networking
fake_net "$T/n-ts" lo eth0 tailscale0
fake_net "$T/n-plain" lo eth0
fake_net "$T/n-custom" lo eth0 ts9

# det CMD PROC NET -> state
det() {
    VALARK_TAILSCALE_CMD="$1" VALARK_TAILSCALE_PROC="$2" VALARK_TAILSCALE_SYSNET="$3" bash "$DET" check 2>/dev/null
}
state_of() { grep -oE '"state":"[a-z]+"' | cut -d'"' -f4; }
expect() {  # $1=label $2=want $3=json
    local got; got="$(printf '%s' "$3" | state_of)"
    [ "$got" = "$2" ] && pass || fail "$1: want state=$2, got '$got' ($3)"
}

# --- 1. detector --------------------------------------------------------------
J="$(det none "$T/p-none" "$T/n-plain")";       expect "tailscale absent (no CLI, no daemon)" absent "$J"
echo "$J" | grep -q '"userspace":false' && pass || fail "absent must not report userspace ($J)"
J="$(det "$T/ts-fail" "$T/p-none" "$T/n-plain")"; expect "CLI present but daemon not running" absent "$J"
J="$(det "$T/ts-kernel" "$T/p-kernel" "$T/n-ts")"; expect "kernel TUN (status TUN true + tailscale0)" kernel "$J"
echo "$J" | grep -q '"userspace":false' && pass || fail "kernel mode must not report userspace ($J)"
J="$(det none "$T/p-kernel" "$T/n-ts")";        expect "kernel TUN without the CLI (interface present)" kernel "$J"
J="$(det "$T/ts-user" "$T/p-none" "$T/n-plain")"; expect "status --json TUN:false" userspace "$J"
echo "$J" | grep -q 'no TUN interface' && pass || fail "status evidence must be recorded ($J)"
J="$(det none "$T/p-user" "$T/n-plain")";       expect "--tun=userspace-networking in argv" userspace "$J"
echo "$J" | grep -q '"userspace":true' && echo "$J" | grep -q 'tun=userspace-networking' \
    && pass || fail "cmdline evidence must be recorded ($J)"
J="$(det none "$T/p-split" "$T/n-plain")";      expect "split '-tun userspace-networking' argv" userspace "$J"
J="$(det "$T/ts-fail" "$T/p-kernel" "$T/n-plain")"; expect "daemon running, no tailscale0 interface" userspace "$J"
echo "$J" | grep -q 'no tailscale0 interface' && pass || fail "interface evidence must be recorded ($J)"
J="$(det none "$T/p-custom" "$T/n-custom")";    expect "custom --tun=ts9 present" kernel "$J"
J="$(det none "$T/p-child" "$T/n-plain")";      expect "be-child helper alone is not a daemon" absent "$J"
# The daemon's own word wins over a missing interface name we guessed.
J="$(det "$T/ts-kernel" "$T/p-kernel" "$T/n-plain")"; expect "status TUN true beats a missing tailscale0" kernel "$J"
# Never a non-zero exit for a detection result; valid JSON every time.
VALARK_TAILSCALE_CMD="$T/does-not-exist" VALARK_TAILSCALE_PROC="$T/nope" VALARK_TAILSCALE_SYSNET="$T/nope" \
    bash "$DET" check >"$T/o.json" 2>/dev/null && pass || fail "detector must exit 0 when its sources are missing"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/o.json" && pass || fail "detector must print valid JSON"
# write FILE: atomic, valid JSON on disk.
mkdir -p "$T/w"
VALARK_TAILSCALE_CMD="$T/ts-user" VALARK_TAILSCALE_PROC="$T/p-none" VALARK_TAILSCALE_SYSNET="$T/n-plain" \
    bash "$DET" write "$T/w/state/tailscale.json" >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["state"]=="userspace" and d["userspace"] is True else 1)' \
    "$T/w/state/tailscale.json" && pass || fail "write must leave a valid tailscale.json"
ls "$T/w/state" | grep -q '\.tmp\.' && fail "write must not leave temp files" || pass

# --- 2. loop: step 2g records the state and write_health flags it --------------
cat > "$T/lp.sh" <<'EOF'
set -o pipefail
_DIR="$RT/scripts"; STATE_DIR="$SD"; mkdir -p "$SD"
LINKREPORT="$SD/linkcheck.txt"; HEALTH_JSON="$SD/selfheal.json"; HEAL_EVENTS_LOG="$SD/heal-events.jsonl"
HEAL_EVENTS=(); RED=''; GREEN=''; YELLOW=''; NC=''
log(){ echo "$*"; }
valark_human(){ echo 1G; }; valark_fillable_bytes(){ echo 1; }
_hj_str(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
EOF
awk '/^TAILSCALE_JSON=/,/^TAILSCALE_STATE=""/' "$ROOT/scripts/loop.sh" >> "$T/lp.sh"
awk '/^tailscale_check\(\) \{/,/^\}/' "$ROOT/scripts/loop.sh" >> "$T/lp.sh"
awk '/^write_health\(\) \{/,/^\}/' "$ROOT/scripts/loop.sh" >> "$T/lp.sh"
echo 'tailscale_check; write_health' >> "$T/lp.sh"
LOUT="$(VALARK_TAILSCALE_CMD="$T/ts-user" VALARK_TAILSCALE_PROC="$T/p-none" VALARK_TAILSCALE_SYSNET="$T/n-plain" \
    RT="$ROOT" SD="$T/loop/state" bash "$T/lp.sh" 2>&1)"
echo "$LOUT" | grep -q 'userspace-networking mode' && pass || fail "loop must log the userspace warning ($LOUT)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["tailscale"]=="userspace" and d["overall"]=="attention" else 1)' \
    "$T/loop/state/selfheal.json" && pass || fail "selfheal.json must carry tailscale=userspace and overall=attention"
[ -f "$T/loop/state/tailscale.json" ] && pass || fail "loop step 2g must write state/tailscale.json"
LOUT="$(VALARK_TAILSCALE_CMD=none VALARK_TAILSCALE_PROC="$T/p-none" VALARK_TAILSCALE_SYSNET="$T/n-plain" \
    RT="$ROOT" SD="$T/loop2/state" bash "$T/lp.sh" 2>&1)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["tailscale"]=="absent" and d["overall"]=="good" else 1)' \
    "$T/loop2/state/selfheal.json" && pass || fail "no tailscale must leave overall=good (tailscale=absent)"

# --- 3. server: critical notification + Health detail --------------------------
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
if [ -z "$NODE" ]; then echo "SKIP: no node runtime (server checks)" >&2
else
mkdir -p "$T/content/zim" "$T/models"
start_srv() {  # $1=state dir, rest = extra env assignments
    local sd="$1"; shift
    PORT=$(free_port); B="http://127.0.0.1:$PORT"
    env "$@" VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
      VALARK_STATE_DIR="$sd" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
      "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-$PORT.log" 2>&1 &
    SRV_PID=$!
    local i; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && return 0; done
    return 1
}
has_ts_item() {  # stdin = notifications JSON; exit 0 if the critical item is there
    "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const it=JSON.parse(s).items||[];
        const n=it.find(x=>x.id==="cond-tailscale-userspace");
        process.exit(n&&n.severity==="critical"&&/kernel TUN/.test(n.detail)&&/stop Tailscale/.test(n.detail)?0:1)})'
}

# 3a. the loop's state file says userspace -> critical item + health detail
mkdir -p "$T/s-user"
printf '{"ts":"2026-11-01T00:00:00Z","state":"userspace","userspace":true,"running":true,"evidence":["tailscaled was started with --tun=userspace-networking"]}\n' \
    > "$T/s-user/tailscale.json"
if start_srv "$T/s-user"; then
    pass
    curl -s --max-time 6 "$B/api/status/notifications" | has_ts_item && pass \
        || fail "a userspace tailscale.json must raise the critical cond-tailscale-userspace notification"
    curl -s --max-time 6 "$B/api/status/health" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        const t=JSON.parse(s).tailscale; process.exit(t&&t.userspace===true&&t.state==="userspace"?0:1)})' \
        && pass || fail "/api/status/health must carry tailscale.userspace=true"
    # Test servers spawn no detector without a stub CLI: the seeded file is untouched.
    grep -q '"state":"userspace"' "$T/s-user/tailscale.json" && pass || fail "server must not run the real detector under VALARK_TEST_NO_SPAWN"
else fail "server (userspace seed) did not start"; fi
stop_pids "$SRV_PID"; SRV_PID=""

# 3b. kernel mode -> no item
mkdir -p "$T/s-kern"
printf '{"ts":"2026-11-01T00:00:00Z","state":"kernel","userspace":false,"running":true,"evidence":[]}\n' > "$T/s-kern/tailscale.json"
if start_srv "$T/s-kern"; then
    curl -s --max-time 6 "$B/api/status/notifications" | has_ts_item && fail "kernel mode must not raise the tailscale notification" || pass
else fail "server (kernel seed) did not start"; fi
stop_pids "$SRV_PID"; SRV_PID=""

# 3c. no state file (tailscale absent / never checked) -> no item, no error
mkdir -p "$T/s-none"
if start_srv "$T/s-none"; then
    N="$(curl -s --max-time 6 "$B/api/status/notifications")"
    echo "$N" | has_ts_item && fail "no tailscale.json must not raise the notification" || pass
    echo "$N" | grep -q '"items"' && pass || fail "notifications must stay well-formed with no tailscale.json ($N)"
else fail "server (no state) did not start"; fi
stop_pids "$SRV_PID"; SRV_PID=""

# 3d. the server detects on its own at startup (stub CLI handed in)
mkdir -p "$T/s-self"
if start_srv "$T/s-self" VALARK_TAILSCALE_CMD="$T/ts-user" VALARK_TAILSCALE_PROC="$T/p-none" VALARK_TAILSCALE_SYSNET="$T/n-plain"; then
    ok=0; for i in $(seq 1 20); do
        curl -s --max-time 6 "$B/api/status/notifications" | has_ts_item && { ok=1; break; }; sleep 0.5
    done
    [ "$ok" = 1 ] && pass || fail "server must run the detector at startup and raise the notification"
    grep -q 'userspace-networking mode' "$T/srv-$PORT.log" && pass || fail "server must log the userspace warning"
else fail "server (self-detect) did not start"; fi
stop_pids "$SRV_PID"; SRV_PID=""
fi

echo "tailscale-mode: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
