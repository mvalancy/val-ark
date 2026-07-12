#!/bin/bash
###############################################################################
# Val Ark - fresh-VM provisioner (runs INSIDE a clean Ubuntu VM).
#
# Simulates a brand-new user standing up Val Ark on a fresh machine: unpack the
# source, run setup, start the web server, and smoke-test the UI + API — surfacing
# the setup gaps a first-timer would hit (missing deps, no node, bad paths).
#
# Expects the source at /tmp/val-ark-src.tar.gz (multipass-transferred by run.sh).
# Emits machine-readable step lines the host harness parses into the report:
#     STEP|<name>|pass|fail|skip|<ms>|<detail>
###############################################################################
set -o pipefail
SRC_TGZ="${1:-/tmp/val-ark-src.tar.gz}"
DIR="$HOME/val-ark"

step() { # step <name> <status> <ms> [detail]
    printf 'STEP|%s|%s|%s|%s\n' "$1" "$2" "${3:-0}" "${4:-}"
}
run_step() { # run_step <name> <cmd...>
    local name="$1"; shift
    local s e out rc
    s=$(date +%s%3N 2>/dev/null || echo 0)
    out="$("$@" 2>&1)"; rc=$?
    e=$(date +%s%3N 2>/dev/null || echo 0)
    if [ "$rc" -eq 0 ]; then step "$name" pass "$((e-s))"
    else step "$name" fail "$((e-s))" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"; fi
    return "$rc"
}

echo "### provision on $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME") / $(uname -m)"

# 1. Unpack the source (the "download from the LAN Ark" result)
if [ -f "$SRC_TGZ" ]; then
    rm -rf "$DIR"; mkdir -p "$DIR"
    run_step "unpack source" tar -xzf "$SRC_TGZ" -C "$DIR" --strip-components=1
else
    step "unpack source" fail 0 "source tarball missing at $SRC_TGZ"; exit 0
fi
cd "$DIR" || { step "cd into checkout" fail 0 "no $DIR"; exit 0; }

# 2. Run setup (the real first-time step; headless via VALARK_YES so it completes
#    unattended — installs deps + a Node runtime like a scripted/cloud-init user).
s=$(date +%s%3N 2>/dev/null || echo 0)
setup_out="$(VALARK_YES=1 timeout 600 bash scripts/setup.sh </dev/null 2>&1)"; setup_rc=$?
e=$(date +%s%3N 2>/dev/null || echo 0)
if [ "$setup_rc" -eq 0 ]; then step "scripts/setup.sh" pass "$((e-s))"
else step "scripts/setup.sh" fail "$((e-s))" "exit $setup_rc: $(printf '%s' "$setup_out" | grep -iE 'error|fail|not found' | tail -2 | tr '\n' ' ' | cut -c1-200)"; fi

# 3. Is a node runtime available after setup? (offline boxes rely on the mirror;
#    a fresh VM likely has none — this records whether setup provisions one.)
NODE=""
for c in "$DIR"/tools/linux-*/node/bin/node "$HOME/.local/node/bin/node" "$(command -v node 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { NODE="$c"; break; }
done
if [ -n "$NODE" ]; then
    step "node runtime available" pass 0 "$("$NODE" --version 2>/dev/null)"
else
    step "node runtime available" fail 0 "no node after setup — install nodejs or mirror tools/<plat>/node"
    # Provision one so the remaining web smoke tests can still run (records the gap above).
    sudo apt-get install -y nodejs >/dev/null 2>&1 && NODE="$(command -v node 2>/dev/null)"
fi

# 4. Minimal config + start the web server, smoke-test API + UI
if [ -n "$NODE" ]; then
    grep -q '^VAL_ARK_DATA=' .env 2>/dev/null || echo "VAL_ARK_DATA=$HOME/val-ark-data" >> .env
    mkdir -p "$HOME/val-ark-data" logs
    VALARK_DISABLE_KIWIX=1 setsid nohup "$NODE" scripts/server.js 3000 >logs/vm-server.out 2>&1 </dev/null &
    ok=0
    for i in $(seq 1 20); do
        sleep 1
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3000/api/health 2>/dev/null)
        [ "$code" = "200" ] && { ok=1; break; }
    done
    if [ "$ok" = 1 ]; then
        step "web server starts + /api/health ok" pass 0
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:3000/ 2>/dev/null)
        [ "$code" = "200" ] && step "web UI served (GET /)" pass 0 "HTTP $code" || step "web UI served (GET /)" fail 0 "HTTP $code"
        body=$(curl -s --max-time 4 http://127.0.0.1:3000/ 2>/dev/null | grep -o 'Val Ark' | head -1)
        [ -n "$body" ] && step "web UI renders Val Ark shell" pass 0 || step "web UI renders Val Ark shell" fail 0 "index did not contain 'Val Ark'"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:3000/bootstrap.sh 2>/dev/null)
        [ "$code" = "200" ] && step "self-replication: /bootstrap.sh served" pass 0 || step "self-replication: /bootstrap.sh served" fail 0 "HTTP $code"
    else
        step "web server starts + /api/health ok" fail 0 "server did not answer :3000 (see logs/vm-server.out)"
    fi
else
    step "web server starts + /api/health ok" skip 0 "no node runtime"
fi

echo "### provision done"
