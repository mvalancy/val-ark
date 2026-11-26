#!/bin/bash
###############################################################################
# Val Ark - 24/7 self-healing + verification loop.
#
# One cycle (run by `/loop`, cron, or systemd) does, in order:
#   1. ensure the data disk is writable (self-heal NTFS/ro reverts)
#   2. repair the repo<->disk symlink layout (2b-2d web server, public port, community
#      services, 2e self-mirror of Val Ark's own source, 2f direct-connect link DHCP,
#      2g Tailscale userspace-networking check, 2h <name>.local over mDNS)
#   3. refresh the live catalog  -> ZIM/content links self-heal (no stale dates)
#   4. link check + repair        -> tool/installer URLs, web-ui assets, symlinks
#   5. integrity verify           -> requeue corrupt/short downloads (5b re-fill pinned requests,
#      5c weekly refresh of mirrored tools, 5d weekly dev-stack mirror: apps before models, #347)
#   6. top-up fill (bounded)      -> keep filling per the curation priority model
#   7. functional verification    -> tools run, kiwix serves, fleet reachable
#      (7b UI smoke, 7c content-moderation sweep)
#   8. health report + coordination drop (8b self-heal snapshot)
#   The step list in docs/LIBRARIAN.md "The 24/7 loop" is the full, current reference.
#
# Every FULL cycle is serialised on loop.lock (fd 8): the installed cron `once`
# ticks, the admin one-click repair (server.js spawns `loop.sh once`), and a
# supervisory `loop.sh run` never overlap — two concurrent cycles would flap the
# web server (ensure_web_server's fuser -k) and double-run tool_refresh onto the
# same .part files. Only the librarian fill is separately safe to run alongside
# (its own fill flock guards double-downloading). Never aborts on a single failure.
#
# Usage:
#   loop.sh once          run a single maintenance cycle (cron / /loop)
#   loop.sh run [SECS]    run forever, sleeping SECS between cycles (default 1800)
###############################################################################
set -o pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_DIR}/lib/valark-env.sh"

LIBRARIAN="${_DIR}/librarian.sh"
VERIFY="${_DIR}/verify.sh"
LOOP_LOG="${LOG_DIR}/loop_$(date +%Y%m%d).log"
LINKREPORT="${STATE_DIR}/linkcheck.txt"
COORD_DIR="${STATE_DIR}/coordination"   # fleet-reachable notes drop (toaster etc.)
FILL_SECONDS="${LOOP_FILL_SECONDS:-1800}"

RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
if [ -t 1 ] && [ "${FORCE_COLOR:-}" != "0" ]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'; fi
log(){ local m="[$(date '+%F %T')] $*"; echo -e "$m"; mkdir -p "$LOG_DIR" 2>/dev/null; echo "$m" >> "$LOOP_LOG" 2>/dev/null; }
step(){ log "${CYAN}== $* ==${NC}"; }

# Self-heal telemetry: what THIS cycle actually repaired. The Health page reads
# health.json (latest snapshot) + heal-events.jsonl (the timestamped feed of real
# repairs). heal_event records a fix as it happens; write_health serialises both.
HEALTH_JSON="${STATE_DIR}/selfheal.json"   # self-heal snapshot (distinct from librarian's health.json)
HEAL_EVENTS_LOG="${STATE_DIR}/heal-events.jsonl"
HEAL_EVENTS=()                       # "kind|detail" appended by the fixers this cycle
heal_event(){ HEAL_EVENTS+=("$1|$2"); }
_hj_str(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/}; printf '"%s"' "$s"; }

# --- step 4: link check + repair -------------------------------------------
link_check_repair() {
    : > "$LINKREPORT"
    local dead=0 checked=0
    # (a) literal URLs hard-coded in tool scripts (catches e.g. moved CDN paths).
    # Skip TEMPLATED urls (${var}/$VAR/{}) — those are built at runtime via
    # github_asset_url and can't be checked statically — plus local/placeholder
    # examples in install hints. Only fully-literal external URLs are checkable.
    local urls
    urls=$(grep -rhoE 'https?://[^"'"'"' )]+' "${_DIR}/tools/"*.sh 2>/dev/null \
           | grep -vE '[$<>{}]|127\.0\.0\.1|localhost|your-server|0\.0\.0\.0|example\.(com|org)' \
           | sed 's/[).,]*$//' | sort -u)
    # (b) installer catalog URLs (verifiable direct links)
    local inst
    inst=$(awk -F'|' '/^[0-9]/{print $6}' "${PROJECT_ROOT}/data/installers.tsv" 2>/dev/null)
    # (c) a rotating sample of model URLs
    local models
    models=$(awk -F'|' '/^[0-9]/ && $6!="repo"{print "https://huggingface.co/"$4"/resolve/main/"$5}' \
             "${PROJECT_ROOT}/data/models-extra.tsv" 2>/dev/null | head -8)
    local u code
    for u in $urls $inst $models; do
        checked=$((checked+1))
        code=$(valark_url_ok "$u")
        if [ $? -ne 0 ]; then
            echo "DEAD($code) $u" >> "$LINKREPORT"; dead=$((dead+1))
        fi
    done
    # (d) repair the symlink layout + verify web-ui assets exist
    valark_ensure_layout
    local missing_assets=0
    while IFS= read -r asset; do
        [ -f "${PROJECT_ROOT}/web-ui/${asset}" ] || { echo "MISSING-ASSET ${asset}" >> "$LINKREPORT"; missing_assets=$((missing_assets+1)); }
    done < <(grep -ohE "(logos|screenshots)/[A-Za-z0-9._-]+\.(svg|png|jpg|webp)" "${PROJECT_ROOT}/web-ui/index.html" 2>/dev/null | sort -u)
    if [ "$dead" -eq 0 ] && [ "$missing_assets" -eq 0 ]; then
        log "${GREEN}links OK${NC} ($checked URLs checked, symlinks + web-ui assets fine)"
    else
        log "${YELLOW}link issues${NC}: $dead dead URL(s), $missing_assets missing asset(s) -> $LINKREPORT"
    fi
}

# --- step 8: coordination (read fleet notes if any) -------------------------
coordination() {
    mkdir -p "$COORD_DIR" 2>/dev/null
    [ -f "${COORD_DIR}/README.txt" ] || cat > "${COORD_DIR}/README.txt" <<'EOF'
Val Ark fleet coordination drop.
Agents running on other mesh nodes can leave notes here; this path lives on the
shared (exported) data disk and the loop reads any *.md / *.txt notes each
cycle. Drop files like:  <node>-ark-tests.md, <node>-notes.txt
state/ is owner-only (valark_lock_private: setup, every loop cycle, site),
so write here as the Ark's own uid.
EOF
    local notes; notes=$(find "$COORD_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) ! -name 'README.txt' 2>/dev/null)
    if [ -n "$notes" ]; then
        log "${CYAN}coordination notes present:${NC}"
        echo "$notes" | while read -r n; do log "  note: $n ($(stat -c%y "$n" 2>/dev/null | cut -d. -f1))"; done
    fi
}

# Keep the Val Ark web UI server (which auto-launches Kiwix) running AND fresh.
# server.js launches kiwix-serve only once at startup, so it neither recovers if
# kiwix dies nor picks up newly-downloaded ZIMs — the loop handles both here.
# Resolve a Node binary in cron-safe order: the portable install that setup.sh
# bootstraps (and start.sh uses), any nvm install, then PATH. Cron's PATH has
# none of these, so never rely on `command -v` alone.
_va_node() {
    local n
    for n in "$HOME/.local/node/bin/node" \
             "$HOME/.nvm/versions/node/v20.20.2/bin/node" \
             "$(command -v node 2>/dev/null)"; do
        [ -n "$n" ] && [ -x "$n" ] && { echo "$n"; return 0; }
    done
    n=$(ls -1d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)
    [ -n "$n" ] && [ -x "$n" ] && echo "$n"
}
_va_start_web() {
    local port="$1" node; node="$(_va_node)"
    [ -n "$node" ] || { log "${RED}node not found${NC}; cannot start web server"; return 1; }
    # 8>&- : this daemon is spawned from inside a run_locked cycle, which holds
    # loop.lock on fd 8. A detached child inherits that fd → it shares the
    # open-file-description holding the flock, so the lock would NEVER release and
    # every later cycle's `flock -n 8` would fail forever (a self-heal loop must
    # never deadlock on its own lock). Close it here. See docs/knowledge/gotchas.md.
    setsid nohup "$node" "${_DIR}/server.js" "$port" >"${LOG_DIR}/server.out" 2>&1 </dev/null 8>&- & disown
}
ensure_web_server() {
    local port="${VALARK_WEB_PORT:-3000}"
    if curl -fsS --max-time 4 "http://127.0.0.1:${port}/api/health" 2>/dev/null | grep -q '"status".*"ok"'; then
        # Web up — is kiwix running and serving roughly all complete ZIMs?
        local ks krun kfiles zc
        ks=$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/status/kiwix" 2>/dev/null)
        krun=$(echo "$ks" | grep -oE '"running":(true|false)' | grep -oE 'true|false')
        kfiles=$(echo "$ks" | grep -oE '"files":[0-9]+' | grep -oE '[0-9]+'); kfiles=${kfiles:-0}
        # Count only SERVABLE ZIMs (server.js skips <1MB) so the gap reflects
        # genuinely-new complete content, not the always-skipped tiny ones.
        zc=$(find "$ZIM_DIR" -maxdepth 1 -name '*.zim' -size +1M 2>/dev/null | wc -l)
        if { [ "$krun" = "false" ] && [ "$zc" -gt 0 ]; } || [ $(( zc - kfiles )) -ge 20 ]; then
            log "${YELLOW}kiwix stale/down${NC} (serving $kfiles of $zc ZIMs) — restarting server to refresh"
            fuser -k "${port}/tcp" 2>/dev/null; fuser -k 8888/tcp 2>/dev/null
            sleep 2   # let the old process actually release the port
            _va_start_web "$port" && { log "${GREEN}restarted${NC} web server on :$port"; heal_event restart "Refreshed the library server (was serving $kfiles of $zc collections)"; }
        else
            log "web up on :$port (kiwix ${krun:-?}, $kfiles ZIMs)"
        fi
        return 0
    fi
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
        log "${YELLOW}:$port held by another app${NC} — set VALARK_WEB_PORT in .env to a free port"; return 1
    fi
    _va_start_web "$port" && { log "${GREEN}started Val Ark web server${NC} on :$port"; heal_event start "Started the web server (it was down)"; }
}

# Standard-port access: when VALARK_WEB_PUBLIC_PORT is set (e.g. 80), keep an
# idempotent iptables NAT redirect public->web port in place. PREROUTING covers
# every real interface (LAN + tailscale/VPN) while leaving loopback alone —
# appliances often pin their own UI to 127.0.0.1:80 — and needs no privileged
# bind or setcap on node. Re-asserted every cycle, so it survives reboots and
# firewall reloads. Best-effort: logs and moves on where iptables/sudo are absent.
ensure_public_port() {
    local pub="${VALARK_WEB_PUBLIC_PORT:-}" web="${VALARK_WEB_PORT:-3000}"
    [ -n "$pub" ] && [ "$pub" != "$web" ] || return 0
    # sbin isn't on PATH in cron/ssh shells on Debian-family systems
    local PATH="/usr/sbin:/sbin:$PATH"
    if ! command -v iptables >/dev/null 2>&1; then
        log "${YELLOW}iptables not found${NC} — cannot map :${pub} -> :${web}"; return 0
    fi
    local SUDO=""
    [ "$(id -u)" = "0" ] || SUDO="sudo -n"
    local ipt ensured="" failed=""
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        if $SUDO "$ipt" -t nat -C PREROUTING -p tcp --dport "$pub" -j REDIRECT --to-ports "$web" 2>/dev/null \
           || $SUDO "$ipt" -t nat -A PREROUTING -p tcp --dport "$pub" -j REDIRECT --to-ports "$web" 2>/dev/null; then
            ensured="${ensured}${ipt} "
        else
            failed="${failed}${ipt} "
        fi
    done
    [ -n "$ensured" ] && log "public port ${GREEN}:${pub} -> :${web}${NC} (${ensured% })"
    [ -n "$failed" ] && log "${YELLOW}could not ensure :${pub} redirect via ${failed% }${NC} (needs passwordless sudo or root)"
    return 0
}

# Keep enabled community services (VALARK_SERVICES in .env, e.g. "chat mail forum
# paste") running. `<id>.sh start` is idempotent (a no-op when already up), so this
# both launches them and respawns any that died. Best-effort and non-fatal.
ensure_services() {
    local svcs="${VALARK_SERVICES:-}"
    [ -n "$svcs" ] || { log "no community services enabled (set VALARK_SERVICES in .env)"; return 0; }
    local id sh
    for id in $svcs; do
        sh="${_DIR}/services/${id}.sh"
        if [ -x "$sh" ] || [ -f "$sh" ]; then
            # 8>&- : we run under the cycle lock (run_locked, fd 8) but the service
            # scripts spawn long-lived detached daemons (ngIRCd/The Lounge/maddy/
            # NodeBB/…). Close fd 8 for the whole service subtree so no daemon inherits
            # loop.lock — a shared fd holds the lock forever and deadlocks every later
            # cycle. Central guard, covers present + future daemons. See gotchas.md.
            if timeout 120 bash "$sh" start >/dev/null 2>&1 8>&-; then
                log "service ${GREEN}up${NC}: ${id}"
            else
                log "${YELLOW}service ${id} not started${NC} (mirror/build it: scripts/tools/${id}.sh)"
            fi
        else
            log "${YELLOW}unknown service '${id}'${NC} (no scripts/services/${id}.sh)"
        fi
    done
}

# Direct-connect laptop support (issue #148): when VALARK_LINK_DHCP=1, serve a
# tiny DHCP + DNS on ONE wired interface, but only while no other DHCP server
# answers on that link. scripts/lib/link-dhcp.sh owns the decision (probe first,
# never fight a router, stop when one appears) and keeps its own watcher up so
# link changes are handled between cycles. Off = a quiet no-op (stops it if it
# was serving). Needs root/passwordless sudo + dnsmasq; fails soft otherwise.
ensure_link_dhcp() {
    local sh="${_DIR}/lib/link-dhcp.sh" out
    # Fast path: off and nothing of ours running (runtime files live on tmpfs).
    if [ "${VALARK_LINK_DHCP:-0}" != "1" ] && [ ! -s "${VALARK_LINK_DHCP_RUN:-/run/valark-link-dhcp}/dnsmasq.pid" ] \
       && [ ! -s "${VALARK_LINK_DHCP_RUN:-/run/valark-link-dhcp}/watch.pid" ]; then
        log "link DHCP off (VALARK_LINK_DHCP=1 serves a direct-connect laptop)"; return 0
    fi
    # 8>&- : the watcher it spawns must not inherit loop.lock (see ensure_services).
    out=$(timeout 120 bash "$sh" ensure 2>&1 8>&-)
    printf '%s\n' "$out" | sed 's/^/    /'
    case "$out" in
        *"started serving"*) heal_event start "Serving DHCP + DNS on the wired port (no other DHCP server on the link)" ;;
        *"stopped serving"*) heal_event stop "Stopped serving DHCP on the wired port ($(printf '%s' "$out" | grep -o 'stopped serving.*' | head -1 | sed 's/^[^:]*: //'))" ;;
    esac
    return 0
}

# Periodic tool refresh — keep the mirrored apps at their LATEST upstream
# versions. Tool scripts resolve versions live (github_latest_tag etc.) and
# skip anything already current, so an up-to-date pass is cheap; when upstream
# shipped a release, only the changed artifacts download. Weekly by default
# (VALARK_TOOL_REFRESH_DAYS, 0 = disabled); a failed/partial pass retries in a
# day (downloads are idempotent + resumable, so retries just fill gaps).
# Runs BEFORE the top-up fill (step 5c, #347): apps come before more models. It is
# skipped (and retried next cycle) under the STOP flag or with less than 1 GiB of
# budget left (the reserve / VALARK_MAX_GB), since the tool scripts size nothing.
APPS_MIN_BUDGET=1073741824
# True (0) when every phase-0 essentials row that fits is on disk: `librarian.sh essentials-done`
# exits 0. Exit 1 (some still planned) or 2 (no catalog to judge by) holds the app mirrors back;
# an essentials list that cannot be judged fails closed, the fill below makes progress either way.
essentials_held() {
    local rc=0
    FORCE_COLOR=0 bash "$LIBRARIAN" essentials-done >/dev/null 2>&1 || rc=$?
    return "$rc"
}
tool_refresh() {
    local days="${VALARK_TOOL_REFRESH_DAYS:-7}"
    [ "$days" = "0" ] && { log "tool refresh disabled"; return 0; }
    [ -f "${STATE_DIR}/STOP" ] && { log "tool refresh skipped: STOP flag present"; return 0; }
    local marker="${STATE_DIR}/tool-refresh.next" now due budget
    now=$(date +%s); due=$(cat "$marker" 2>/dev/null || echo 0)
    case "$due" in ''|*[!0-9]*) due=0 ;; esac
    if [ "$now" -lt "$due" ]; then
        log "tool refresh not due yet ($(date -d "@$due" '+%F %H:%M' 2>/dev/null || echo soon))"
        return 0
    fi
    budget=$(valark_budget_bytes 2>/dev/null); budget=${budget:-0}
    # A bounded share like the dev stack: VALARK_TOOLS_PCT percent (default 25; 100 = no share cap) of
    # budget + what the tools tree holds. The tool scripts size nothing, so the cap is a gate: once the
    # tree holds its share, the refresh waits for room.
    local held pct="${VALARK_TOOLS_PCT:-25}"
    case "$pct" in ''|*[!0-9]*) pct=25 ;; esac
    if [ "$pct" -lt 100 ]; then
        held=$(du -sbL "$TOOLS_DIR" 2>/dev/null | cut -f1); held=${held:-0}
        local cap=$(( (budget + held) / 100 * pct - held )); [ "$cap" -lt 0 ] && cap=0
        [ "$cap" -lt "$budget" ] && budget=$cap
    fi
    if [ "$budget" -lt "$APPS_MIN_BUDGET" ]; then
        log "${YELLOW}tool refresh skipped${NC}: $(valark_human "$budget") of budget left (reserve / VALARK_MAX_GB / VALARK_TOOLS_PCT)"
        return 0
    fi
    log "refreshing tool mirror to latest upstream versions (bounded $(( ${VALARK_TOOL_REFRESH_TIMEOUT:-7200} / 60 ))min)"
    if FORCE_COLOR=0 timeout "${VALARK_TOOL_REFRESH_TIMEOUT:-7200}" \
        bash "${_DIR}/download-tools.sh" all >> "${LOG_DIR}/tool-refresh.log" 2>&1; then
        echo $(( now + days * 86400 )) > "$marker"
        log "${GREEN}tool refresh complete${NC} (next in ${days}d)"
    else
        echo $(( now + 86400 )) > "$marker"
        log "${YELLOW}tool refresh incomplete — retrying in 1d (see tool-refresh.log)${NC}"
    fi
}

# --- step 5d: the developer + security stack, before the model fill (#347) ----
# scripts/lib/release_mirror.py fetch over data/dev-stack.tsv (Gitea's other builds, Caddy,
# Headscale, KeePassXC, compilers, Docker, ...) into DEVSTACK_DIR. Fail-soft and bounded:
#   - on by default; VALARK_DEVSTACK=0 (or VALARK_DEVSTACK_REFRESH_DAYS=0) turns it off;
#   - weekly (VALARK_DEVSTACK_REFRESH_DAYS, default 7); a run cut short by its time bound
#     (VALARK_DEVSTACK_TIMEOUT, default 3600 s) continues next cycle (.parts resume); a run
#     deferred by the disk or one with errors retries in a day;
#   - budget = a bounded SHARE of the librarian's (valark_budget_bytes: the reserve and
#     VALARK_MAX_GB, whose footprint counts DEVSTACK_DIR): VALARK_DEVSTACK_PCT percent
#     (default 25; 100 = the whole budget) of budget + what the tree holds, optionally also
#     capped by VALARK_DEVSTACK_MAX_GB for the whole tree. Never starts before the grid-down
#     essentials are held (the loop gates 5c/5d on `librarian.sh essentials-done`); release_mirror.py also re-checks the reserve and the STOP flag every 256 MiB;
#   - VALARK_DEVSTACK_GROUPS (comma list, e.g. python,toolchains,security) limits the groups;
#   - GITHUB_TOKEN from .env lifts GitHub's 60 calls/hour anonymous limit (~250 per plan).
devstack_mirror() {
    [ "${VALARK_DEVSTACK:-1}" = "0" ] && { log "dev-stack mirror off (VALARK_DEVSTACK=0)"; return 0; }
    local days="${VALARK_DEVSTACK_REFRESH_DAYS:-7}"
    [ "$days" = "0" ] && { log "dev-stack mirror off (VALARK_DEVSTACK_REFRESH_DAYS=0)"; return 0; }
    [ -f "${STATE_DIR}/STOP" ] && { log "dev-stack mirror skipped: STOP flag present"; return 0; }
    command -v python3 >/dev/null 2>&1 || { log "${YELLOW}dev-stack mirror skipped${NC}: python3 not found"; return 0; }
    local marker="${STATE_DIR}/devstack-refresh.next" now due budget held cap
    now=$(date +%s); due=$(cat "$marker" 2>/dev/null || echo 0)
    case "$due" in ''|*[!0-9]*) due=0 ;; esac
    if [ "$now" -lt "$due" ]; then
        log "dev-stack mirror not due yet ($(date -d "@$due" '+%F %H:%M' 2>/dev/null || echo soon))"
        return 0
    fi
    budget=$(valark_budget_bytes 2>/dev/null); budget=${budget:-0}
    held=$(du -sbL "$DEVSTACK_DIR" 2>/dev/null | cut -f1); held=${held:-0}
    # A bounded share, never the whole budget (the stack is ~194 GB): VALARK_DEVSTACK_PCT of what
    # the dev stack could hold in all (budget + what it holds now), default 25; 100 = no share cap.
    local pct="${VALARK_DEVSTACK_PCT:-25}"
    case "$pct" in ''|*[!0-9]*) pct=25 ;; esac
    if [ "$pct" -lt 100 ]; then
        cap=$(( (budget + held) / 100 * pct - held )); [ "$cap" -lt 0 ] && cap=0
        [ "$cap" -lt "$budget" ] && budget=$cap
    fi
    case "${VALARK_DEVSTACK_MAX_GB:-}" in
        ''|*[!0-9]*) ;;
        *) cap=$(( VALARK_DEVSTACK_MAX_GB * 1073741824 - held )); [ "$cap" -lt 0 ] && cap=0
           [ "$cap" -lt "$budget" ] && budget=$cap ;;
    esac
    if [ "$budget" -lt "$APPS_MIN_BUDGET" ]; then
        log "${YELLOW}dev-stack mirror skipped${NC}: $(valark_human "$budget") of budget left (reserve / VALARK_MAX_GB / VALARK_DEVSTACK_PCT / VALARK_DEVSTACK_MAX_GB); retrying in 1d"
        echo $(( now + 86400 )) > "$marker"
        return 0
    fi
    local secs="${VALARK_DEVSTACK_TIMEOUT:-3600}" rc=0 g groups=()
    for g in $(printf '%s' "${VALARK_DEVSTACK_GROUPS:-}" | tr ',' ' '); do groups+=(--group "$g"); done
    [ -n "${GITHUB_TOKEN:-}" ] || log "${YELLOW}GITHUB_TOKEN not set${NC}: GitHub allows 60 anonymous calls/hour, so some dev-stack entries may not resolve (set it in .env)"
    log "mirroring the dev stack to ${DEVSTACK_DIR} (bounded ${secs}s, budget $(valark_human "$budget"))"
    mkdir -p "$DEVSTACK_DIR" "$LOG_DIR" 2>/dev/null
    VALARK_STOP_FLAG="${STATE_DIR}/STOP" timeout "$secs" python3 "${_DIR}/lib/release_mirror.py" fetch \
        --dest "$DEVSTACK_DIR" --budget "$budget" "${groups[@]}" >> "${LOG_DIR}/devstack.log" 2>&1 || rc=$?
    local sumline; sumline=$(grep '^summary: ' "${LOG_DIR}/devstack.log" 2>/dev/null | tail -1)
    [ "$rc" != "0" ] && [ -n "$sumline" ] && log "dev-stack mirror (exit $rc) ${sumline}"   # exit 1 must not hide deferred files (exit 3)
    case "$rc" in
        0)   echo $(( now + days * 86400 )) > "$marker"; log "${GREEN}dev-stack mirror complete${NC} (next in ${days}d)" ;;
        124|137) echo "$now" > "$marker"; log "${YELLOW}dev-stack mirror hit its ${secs}s bound${NC}; it continues next cycle (.parts resume)" ;;
        3)   echo $(( now + 86400 )) > "$marker"; log "${YELLOW}dev-stack mirror deferred${NC} (reserve, budget or STOP); retrying in 1d (see devstack.log)" ;;
        *)   echo $(( now + 86400 )) > "$marker"; log "${YELLOW}dev-stack mirror incomplete (exit $rc)${NC}; retrying in 1d (see devstack.log)" ;;
    esac
    return 0
}

# Dynamic UI smoke — exercise the web UI's controls and the "back to the ark"
# header against the LIVE server (so the embedded library frame is covered too).
# Best-effort: skipped cleanly if Playwright deps aren't installed.
ui_smoke() {
    local port="${VALARK_WEB_PORT:-3000}"
    local pw="${PROJECT_ROOT}/tests/screenshots/node_modules/.bin/playwright"
    [ -x "$pw" ] || { log "ui smoke skipped (playwright not installed: cd tests/screenshots && npm install)"; return 0; }
    local node nodedir; node="$(_va_node)"; [ -n "$node" ] || { log "ui smoke skipped (node not found)"; return 0; }
    nodedir="$(dirname "$node")"
    local out
    out=$(cd "${PROJECT_ROOT}/tests/screenshots" && \
        PATH="${nodedir}:$PATH" VALARK_TEST_URL="http://127.0.0.1:${port}" \
        timeout 180 "$pw" test specs/ui-exercise.spec.ts -g "back-to-ark|offline library|storage breakdown" --reporter=line 2>&1 | tail -4)
    if echo "$out" | grep -qE '[0-9]+ passed' && ! echo "$out" | grep -qE '[0-9]+ failed'; then
        log "${GREEN}ui smoke OK${NC}: $(echo "$out" | grep -oE '[0-9]+ passed' | head -1)"
    else
        log "${YELLOW}ui smoke issues${NC}: $(echo "$out" | tr '\n' ' ' | tail -c 220)"
    fi
}

# --- step 2g: is Tailscale in userspace-networking mode? (#311) ---------------
# With no TUN interface, tailscaled connects onward from 127.0.0.1, so every tailnet
# peer looks like the box's own console (the Admin). Detection is read-only and
# fail-soft (scripts/lib/tailscale-mode.sh); the result lands in state/tailscale.json,
# which server.js reads for the Health page + a critical notification.
TAILSCALE_JSON="${STATE_DIR}/tailscale.json"
TAILSCALE_STATE=""
tailscale_check() {
    local out to=()
    command -v timeout >/dev/null 2>&1 && to=(timeout 30)   # no timeout(1) on stock macOS
    out=$("${to[@]}" bash "${_DIR}/lib/tailscale-mode.sh" write "$TAILSCALE_JSON" 2>/dev/null)
    TAILSCALE_STATE=$(printf '%s' "$out" | grep -oE '"state":"[a-z]+"' | head -1 | cut -d'"' -f4)
    case "$TAILSCALE_STATE" in
        userspace) log "${RED}Tailscale is in userspace-networking mode${NC}: every tailnet peer reaches the web server as 127.0.0.1 (the Admin). Run tailscaled with a kernel TUN, or stop it on this box." ;;
        kernel) log "tailscale: kernel interface (ok)" ;;
        absent) log "tailscale: not running" ;;
        *) TAILSCALE_STATE=unknown; log "${YELLOW}tailscale: mode unknown${NC}" ;;
    esac
}

# --- step 2h: publish <name>.local over mDNS when the box can (#306) ----------
# lib/mdns.sh: native (hostname = name), or ONE kept-up `avahi-publish -a -R` child, or
# "unavailable" with a reason (no avahi, daemon stopped, ...) in state/mdns.json, which
# server.js reads to show the LAN IP instead. Never installs anything.
# 8>&- : the publisher it spawns must not inherit loop.lock (see ensure_services).
ensure_mdns() {
    local out st reason to=()
    command -v timeout >/dev/null 2>&1 && to=(timeout 30)
    out=$("${to[@]}" bash "${_DIR}/lib/mdns.sh" ensure "$STATE_DIR" 2>/dev/null 8>&-)
    st=$(printf '%s' "$out" | grep -oE '"state":"[a-z]+"' | head -1 | cut -d'"' -f4)
    reason=$(printf '%s' "$out" | grep -oE '"reason":"[^"]*"' | head -1 | cut -d'"' -f4)
    case "$st" in
        published|native) log "mdns: $(printf '%s' "$out" | grep -oE '"host":"[^"]*"' | cut -d'"' -f4) ($st)" ;;
        *) log "${YELLOW}mdns: .local unavailable${NC} (${reason:-unknown}); the web UI shows the LAN IP instead" ;;
    esac
}

# --- step 8b: write the self-heal snapshot the Health page reads --------------
# selfheal.json = latest cycle summary (space, verify tallies, link/asset counts,
# what was repaired this cycle). heal-events.jsonl = the append-only, capped feed
# of genuine repairs (a "restart" or "start" this cycle), newest last.
write_health() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    local dead=0 miss=0
    if [ -f "$LINKREPORT" ]; then
        dead=$(grep -c '^DEAD' "$LINKREPORT" 2>/dev/null); dead=${dead:-0}
        miss=$(grep -c '^MISSING-ASSET' "$LINKREPORT" 2>/dev/null); miss=${miss:-0}
    fi
    local vp=0 vf=0 vs=0
    if [ -f "${STATE_DIR}/verify.json" ]; then
        vp=$(grep -oE '"pass"[[:space:]]*:[[:space:]]*[0-9]+' "${STATE_DIR}/verify.json" | grep -oE '[0-9]+$' | head -1); vp=${vp:-0}
        vf=$(grep -oE '"fail"[[:space:]]*:[[:space:]]*[0-9]+' "${STATE_DIR}/verify.json" | grep -oE '[0-9]+$' | head -1); vf=${vf:-0}
        vs=$(grep -oE '"skip"[[:space:]]*:[[:space:]]*[0-9]+' "${STATE_DIR}/verify.json" | grep -oE '[0-9]+$' | head -1); vs=${vs:-0}
    fi
    # overall reflects the BOX's own health (unresolved after this cycle). Dead
    # upstream links are an internet transient the catalog re-resolves, not a box
    # fault, so they don't flip overall — the UI frames them as "recovering".
    local overall="good"
    { [ "$vf" -gt 0 ] || [ "$miss" -gt 0 ] || [ "$TAILSCALE_STATE" = userspace ]; } && overall="attention"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local reps="" e kind detail first=1
    for e in "${HEAL_EVENTS[@]}"; do
        kind="${e%%|*}"; detail="${e#*|}"
        [ "$first" = 1 ] && first=0 || reps="${reps},"
        reps="${reps}"$'\n'"    { \"kind\": $(_hj_str "$kind"), \"detail\": $(_hj_str "$detail") }"
        printf '{"ts":"%s","kind":%s,"detail":%s}\n' "$ts" "$(_hj_str "$kind")" "$(_hj_str "$detail")" >> "$HEAL_EVENTS_LOG"
    done
    if [ -f "$HEAL_EVENTS_LOG" ] && [ "$(wc -l < "$HEAL_EVENTS_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -n 200 "$HEAL_EVENTS_LOG" > "${HEAL_EVENTS_LOG}.tmp" && mv -f "${HEAL_EVENTS_LOG}.tmp" "$HEAL_EVENTS_LOG"
    fi
    local tmp="${HEALTH_JSON}.tmp"
    {
        printf '{ "ts": "%s", "overall": "%s",\n' "$ts" "$overall"
        printf '  "deadLinks": %d, "missingAssets": %d,\n' "$dead" "$miss"
        printf '  "fillable": %s,\n' "$(_hj_str "$(valark_human "$(valark_fillable_bytes 2>/dev/null)" 2>/dev/null)")"
        printf '  "verify": { "pass": %d, "fail": %d, "skip": %d },\n' "$vp" "$vf" "$vs"
        printf '  "tailscale": %s,\n' "$(_hj_str "${TAILSCALE_STATE:-unknown}")"
        printf '  "repairs": [%s\n  ] }\n' "$reps"
    } > "$tmp" && mv -f "$tmp" "$HEALTH_JSON"
    log "health written: ${HEALTH_JSON} (overall=$overall, ${#HEAL_EVENTS[@]} repair(s) this cycle)"
}

loop_once() {
    step "cycle start"
    step "1. ensure data disk writable"
    if valark_ensure_writable; then log "${GREEN}writable${NC}: $DATA_ROOT"; else log "${RED}NOT writable${NC}: $DATA_ROOT (manual remount may be needed)"; fi

    step "2. repair layout"; valark_ensure_layout && log "layout ok"

    step "2b. ensure web server + kiwix running"; ensure_web_server

    step "2c. ensure standard-port access (VALARK_WEB_PUBLIC_PORT)"; ensure_public_port

    step "2d. ensure enabled community services running"; ensure_services

    step "2e. self-mirror (offline: serve our own code for LAN bootstrap)"
    FORCE_COLOR=0 bash "${_DIR}/mirror-self.sh" 2>&1 | tail -1 | sed 's/^/    /'

    step "2f. link DHCP + DNS for a direct-connect laptop (VALARK_LINK_DHCP)"; ensure_link_dhcp

    step "2g. tailscale mode (userspace networking makes tailnet peers look like the Admin, #311)"; tailscale_check

    step "2h. publish <name>.local over mDNS (when avahi runs, #306)"; ensure_mdns

    step "3. refresh live catalog (heals stale content links)"
    bash "$LIBRARIAN" refresh >/dev/null 2>&1 && log "catalog refreshed" || log "${YELLOW}catalog refresh failed (cache retained)${NC}"

    step "4. link check + repair"; link_check_repair

    step "5. integrity verify"; bash "$LIBRARIAN" verify 2>&1 | tail -1 | sed 's/^/    /'

    step "5b. re-fill pinned requests (user-requested items win before generic fill)"
    FORCE_COLOR=0 bash "$LIBRARIAN" pins --refill 2>&1 | tail -1 | sed 's/^/    /'

    # Apps before more models (#347): the unplanned app mirrors run before the top-up fill,
    # whose planner then takes apps, then library, then models.
    # ...but only once the planner's phase-0 grid-down essentials that fit are held: on a small
    # disk the app mirrors (the dev stack is ~194 GB) would otherwise fill it before the essentials.
    if essentials_held; then
        step "5c. tool refresh (weekly; keeps mirrored apps at latest upstream)"; tool_refresh

        step "5d. dev-stack mirror (weekly; data/dev-stack.tsv, VALARK_DEVSTACK)"; devstack_mirror
    else
        step "5c/5d. tool refresh + dev-stack mirror: waiting for the grid-down essentials"
        log "${YELLOW}tool refresh and dev-stack mirror held back${NC}: the essentials (librarian.sh essentials-done) are not all held yet; the fill below takes them first"
    fi

    step "6. top-up fill (<=${FILL_SECONDS}s; skipped if a fill is already running)"
    FORCE_COLOR=0 bash "$LIBRARIAN" fill --time "$FILL_SECONDS" 2>&1 | tail -1 | sed 's/^/    /'

    step "7. functional verification"; FORCE_COLOR="${FORCE_COLOR:-1}" bash "$VERIFY" all 2>&1 | sed 's/^/    /'

    step "7b. UI smoke (dynamic controls + back-to-ark nav)"; ui_smoke

    step "7c. content moderation sweep (screen community uploads; quarantine flagged)"
    _ms_out=$(FORCE_COLOR=0 bash "${_DIR}/lib/mod-sweep.sh" sweep 2>&1); _ms_rc=$?
    printf '%s\n' "$_ms_out" | tail -1 | sed 's/^/    /'
    if [ "$_ms_rc" = 10 ]; then
        _ms_n=$(printf '%s' "$_ms_out" | grep -oE 'quarantined [0-9]+' | grep -oE '[0-9]+$')
        heal_event quarantine "Moderation quarantined ${_ms_n:-1} flagged upload(s) for review"
    elif [ "$_ms_rc" = 11 ]; then
        # A flagged file could NOT be moved out of the store (still served) — surface it as
        # a genuine problem the admin must act on, not a silent enforcement gap.
        _ms_e=$(printf '%s' "$_ms_out" | grep -oE 'errors [0-9]+' | grep -oE '[0-9]+$')
        heal_event moderation-error "Moderation could not quarantine ${_ms_e:-1} flagged upload(s) — still served; check permissions"
    fi

    step "8. report + coordination"; bash "$LIBRARIAN" maintain >/dev/null 2>&1; coordination
    step "8b. self-heal snapshot (health.json + heal-events feed)"; write_health
    log "${GREEN}cycle complete${NC} | fillable $(valark_human "$(valark_fillable_bytes)") | self-heal: ${STATE_DIR}/selfheal.json"
}

# Cron management — durable 24/7 driver that survives reboots/sessions.
CRON_TAG="val-ark-loop"
# The user's current crontab, or empty when they have none. `crontab -l` exits non-zero
# both for "no crontab for <user>" (fine: start empty) and for real failures (cron
# unreachable, permission denied, ...). Piping a failed read into `crontab -` would
# REPLACE the user's whole crontab with just our lines, so any other failure stops here.
_cron_read() {
    local out err rc
    err=$(mktemp 2>/dev/null || echo "${STATE_DIR}/.crontab.err.$$")
    out=$(LC_ALL=C crontab -l 2>"$err"); rc=$?   # C locale: "no crontab" in English
    if [ "$rc" -ne 0 ]; then
        if grep -qi 'no crontab' "$err" 2>/dev/null; then out=""
        else
            log "${RED}crontab -l failed${NC} ($(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')); leaving the crontab untouched" >&2
            rm -f "$err"; return 1
        fi
    fi
    rm -f "$err"
    printf '%s' "$out"
}
cron_install() {
    local every="${1:-30}"   # minutes
    case "$every" in ''|*[!0-9]*) log "${RED}install: minutes must be a number${NC}"; return 64 ;; esac
    command -v crontab >/dev/null 2>&1 || { log "${RED}crontab not found${NC}: run 'loop.sh run' under a service manager instead"; return 1; }
    # cron turns an unescaped '%' into a newline (the rest becomes stdin), so a path
    # with one would run a broken command. Refuse rather than escape.
    local p
    for p in "$PROJECT_ROOT" "$_DIR" "$LOG_DIR"; do
        case "$p" in *%*) log "${RED}install refused${NC}: cron treats '%' as a newline and this path has one: $p (move Val Ark, or run 'loop.sh run' under a service manager)"; return 1 ;; esac
    done
    mkdir -p "$LOG_DIR" 2>/dev/null
    local cur
    cur=$(_cron_read) || return 1
    # No outer flock here: loop.sh 'once' self-guards via run_locked (fd 8 on
    # loop.lock). An outer flock on the same file would dead-lock the inner one.
    # Paths are quoted: a repo or data dir with a space must not split the command.
    local line="*/${every} * * * * cd \"${PROJECT_ROOT}\" && bash \"${_DIR}/loop.sh\" once >> \"${LOG_DIR}/loop_cron.log\" 2>&1 # ${CRON_TAG}"
    # @reboot: bring the Ark back immediately after a reboot instead of waiting up
    # to ${every} min for the next periodic tick. The sleep gives the data disk
    # (FUSE/NTFS via fstab) time to mount before the cycle's writability check.
    local reboot_line="@reboot sleep 90 && cd \"${PROJECT_ROOT}\" && bash \"${_DIR}/loop.sh\" once >> \"${LOG_DIR}/loop_cron.log\" 2>&1 # ${CRON_TAG}"
    { [ -n "$cur" ] && printf '%s\n' "$cur" | grep -v "${CRON_TAG}"; echo "$reboot_line"; echo "$line"; } | crontab - || {
        log "${RED}crontab install failed${NC}"; return 1; }
    log "installed cron: @reboot + every ${every} min (tag ${CRON_TAG})"
    crontab -l 2>/dev/null | grep "${CRON_TAG}"
    return 0
}
cron_uninstall() {
    local cur
    cur=$(_cron_read) || return 1
    [ -n "$cur" ] || { log "no crontab; nothing to remove"; return 0; }
    { printf '%s\n' "$cur" | grep -v "${CRON_TAG}"; true; } | crontab - || { log "${RED}crontab update failed${NC}"; return 1; }
    log "removed ${CRON_TAG} cron entries"
}

# Single-cycle lock (fd 8 on loop.lock), non-blocking, so overlapping cycles never
# stack. Busy-mode is $1: "exit" (a cron/one-off `once` — end the process cleanly)
# or "skip" (a forever `loop.sh run` iteration — RETURN non-zero so the while-loop
# keeps going; a stuck cycle must never deadlock the driver). flock -n means whoever
# already holds the lock wins and every other caller yields without waiting.
run_locked() {
    local on_busy="exit"
    case "$1" in exit|skip) on_busy="$1"; shift ;; esac
    exec 8>"${STATE_DIR}/loop.lock"
    if ! flock -n 8; then
        log "another loop cycle is running; skipping"
        [ "$on_busy" = "skip" ] && return 1
        exit 0
    fi
    "$@"
}

# Data-disk mount guard (issue #58). When Val Ark lives on a SEPARATE disk, refuse to
# build/fill the tree on the ROOT fs if that disk is not mounted yet (a late/failed
# fstab mount at @reboot). Bounded retry-wait for a still-enumerating disk, then SKIP
# so the next cron tick converges once the mount appears. On failure we deliberately
# use echo + a ROOT-fs breadcrumb, NOT log() — log() mkdirs LOG_DIR, which lives on the
# missing disk and would itself start a stray tree there. Returns 0=mounted, 1=skip.
DATA_WAIT_FLAG="${VALARK_MOUNT_WAIT_FLAG:-${PROJECT_ROOT}/.valark-mount-wait}"   # health breadcrumb on the ROOT fs
data_disk_guard() {
    valark_data_mounted && { rm -f "$DATA_WAIT_FLAG" 2>/dev/null; return 0; }
    local tries="${VALARK_MOUNT_WAIT_TRIES:-6}" secs="${VALARK_MOUNT_WAIT_SECS:-10}" i=0
    while [ "$i" -lt "$tries" ]; do
        sleep "$secs"
        valark_data_mounted && { rm -f "$DATA_WAIT_FLAG" 2>/dev/null; log "${GREEN}data disk mounted${NC}: $DATA_ROOT (resumed after wait)"; return 0; }
        i=$((i + 1))
    done
    printf '{"ts":"%s","overall":"attention","reason":"data disk not mounted at %s — cycle skipped, will retry"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DATA_ROOT" > "$DATA_WAIT_FLAG" 2>/dev/null || true
    echo "${YELLOW}[$(date '+%F %T')] data disk not mounted${NC} at $DATA_ROOT — skipping cycle to avoid rebuilding state/content on the root fs. It converges on the next tick once the disk mounts. (If you deliberately switched to single-disk mode, remove ${VALARK_DATA_MARKER}.)" >&2
    return 1
}

# Sourced (tests/test-loop-apps-first.sh drives loop_once with stubs): define, never dispatch.
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0

case "${1:-once}" in
    once)
        # Guard BEFORE any mkdir: an unmounted, user-writable mountpoint passes the
        # writability probe, so the plain mkdir would seed the tree on the wrong disk.
        data_disk_guard || exit 0
        mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null; run_locked exit loop_once ;;
    run)
        interval="${2:-1800}"
        echo "loop: starting continuous run (interval ${interval}s). Touch ${STATE_DIR}/STOP to halt."
        while true; do
            [ -f "${STATE_DIR}/STOP" ] && { echo "STOP flag present; exiting loop"; break; }
            # Skip the whole iteration if the data disk isn't mounted (same reasoning
            # as `once`); the mkdir + lock only happen once the disk is confirmed.
            if data_disk_guard; then
                mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
                # Take the SAME loop.lock as the cron `once` tick, non-blocking: if a
                # cron tick (or a still-running prior iteration) holds it, skip THIS
                # iteration rather than stack a second concurrent loop_once. run_locked
                # returns here (never exits), so the forever loop survives contention.
                run_locked skip loop_once || true
                exec 8>&-   # release the lock so a cron `once` tick can work during our sleep
            fi
            echo "sleeping ${interval}s"; sleep "$interval"
        done ;;
    install)   cron_install "${2:-30}" ;;
    uninstall) cron_uninstall ;;
    *) echo "usage: loop.sh {once|run [interval_seconds]|install [minutes]|uninstall}"; exit 1 ;;
esac
