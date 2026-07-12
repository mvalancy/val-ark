#!/bin/bash
###############################################################################
# Val Ark - 24/7 self-healing + verification loop.
#
# One cycle (run by `/loop`, cron, or systemd) does, in order:
#   1. ensure the data disk is writable (self-heal NTFS/ro reverts)
#   2. repair the repo<->disk symlink layout
#   3. refresh the live catalog  -> ZIM/content links self-heal (no stale dates)
#   4. link check + repair        -> tool/installer URLs, web-ui assets, symlinks
#   5. integrity verify           -> requeue corrupt/short downloads
#   6. top-up fill (bounded)      -> keep filling per the curation priority model
#   7. functional verification    -> tools run, kiwix serves, fleet reachable
#   8. health report + coordination drop
#
# Designed to be SAFE to run repeatedly and concurrently with a standalone fill
# (the fill flock prevents double-downloading). Never aborts the cycle on a
# single failure.
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
    setsid nohup "$node" "${_DIR}/server.js" "$port" >"${LOG_DIR}/server.out" 2>&1 </dev/null & disown
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
            _va_start_web "$port" && log "${GREEN}restarted${NC} web server on :$port"
        else
            log "web up on :$port (kiwix ${krun:-?}, $kfiles ZIMs)"
        fi
        return 0
    fi
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
        log "${YELLOW}:$port held by another app${NC} — set VALARK_WEB_PORT in .env to a free port"; return 1
    fi
    _va_start_web "$port" && log "${GREEN}started Val Ark web server${NC} on :$port"
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
            if timeout 120 bash "$sh" start >/dev/null 2>&1; then
                log "service ${GREEN}up${NC}: ${id}"
            else
                log "${YELLOW}service ${id} not started${NC} (mirror/build it: scripts/tools/${id}.sh)"
            fi
        else
            log "${YELLOW}unknown service '${id}'${NC} (no scripts/services/${id}.sh)"
        fi
    done
}

# Periodic tool refresh — keep the mirrored apps at their LATEST upstream
# versions. Tool scripts resolve versions live (github_latest_tag etc.) and
# skip anything already current, so an up-to-date pass is cheap; when upstream
# shipped a release, only the changed artifacts download. Weekly by default
# (VALARK_TOOL_REFRESH_DAYS, 0 = disabled); a failed/partial pass retries in a
# day (downloads are idempotent + resumable, so retries just fill gaps).
tool_refresh() {
    local days="${VALARK_TOOL_REFRESH_DAYS:-7}"
    [ "$days" = "0" ] && { log "tool refresh disabled"; return 0; }
    local marker="${STATE_DIR}/tool-refresh.next" now due
    now=$(date +%s); due=$(cat "$marker" 2>/dev/null || echo 0)
    if [ "$now" -lt "$due" ]; then
        log "tool refresh not due yet ($(date -d "@$due" '+%F %H:%M' 2>/dev/null || echo soon))"
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

    step "3. refresh live catalog (heals stale content links)"
    bash "$LIBRARIAN" refresh >/dev/null 2>&1 && log "catalog refreshed" || log "${YELLOW}catalog refresh failed (cache retained)${NC}"

    step "4. link check + repair"; link_check_repair

    step "5. integrity verify"; bash "$LIBRARIAN" verify 2>&1 | tail -1 | sed 's/^/    /'

    step "5b. re-fill pinned requests (user-requested items win before generic fill)"
    FORCE_COLOR=0 bash "$LIBRARIAN" pins --refill 2>&1 | tail -1 | sed 's/^/    /'

    step "6. top-up fill (<=${FILL_SECONDS}s; skipped if a fill is already running)"
    FORCE_COLOR=0 bash "$LIBRARIAN" fill --time "$FILL_SECONDS" 2>&1 | tail -1 | sed 's/^/    /'

    step "6b. tool refresh (weekly; keeps mirrored apps at latest upstream)"; tool_refresh

    step "7. functional verification"; FORCE_COLOR="${FORCE_COLOR:-1}" bash "$VERIFY" all 2>&1 | sed 's/^/    /'

    step "7b. UI smoke (dynamic controls + back-to-ark nav)"; ui_smoke

    step "8. report + coordination"; bash "$LIBRARIAN" maintain >/dev/null 2>&1; coordination
    log "${GREEN}cycle complete${NC} | fillable $(valark_human "$(valark_fillable_bytes)") | health: ${STATE_DIR}/health.json"
}

# Cron management — durable 24/7 driver that survives reboots/sessions.
CRON_TAG="val-ark-loop"
cron_install() {
    local every="${1:-30}"   # minutes
    mkdir -p "$LOG_DIR" 2>/dev/null
    # No outer flock here: loop.sh 'once' self-guards via run_locked (fd 8 on
    # loop.lock). An outer flock on the same file would dead-lock the inner one.
    local line="*/${every} * * * * cd ${PROJECT_ROOT} && bash ${_DIR}/loop.sh once >> ${LOG_DIR}/loop_cron.log 2>&1 # ${CRON_TAG}"
    # @reboot: bring the Ark back immediately after a reboot instead of waiting up
    # to ${every} min for the next periodic tick. The sleep gives the data disk
    # (FUSE/NTFS via fstab) time to mount before the cycle's writability check.
    local reboot_line="@reboot sleep 90 && cd ${PROJECT_ROOT} && bash ${_DIR}/loop.sh once >> ${LOG_DIR}/loop_cron.log 2>&1 # ${CRON_TAG}"
    (crontab -l 2>/dev/null | grep -v "${CRON_TAG}"; echo "$reboot_line"; echo "$line") | crontab -
    log "installed cron: @reboot + every ${every} min (tag ${CRON_TAG})"
    crontab -l 2>/dev/null | grep "${CRON_TAG}"
}
cron_uninstall() {
    crontab -l 2>/dev/null | grep -v "${CRON_TAG}" | crontab -
    log "removed ${CRON_TAG} cron entries"
}

# Single-cycle lock so overlapping cron ticks never stack.
run_locked() {
    exec 8>"${STATE_DIR}/loop.lock"
    if ! flock -n 8; then log "another loop cycle is running; skipping"; exit 0; fi
    "$@"
}

case "${1:-once}" in
    once) mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null; run_locked loop_once ;;
    run)
        interval="${2:-1800}"
        log "loop: starting continuous run (interval ${interval}s). Touch ${STATE_DIR}/STOP to halt."
        while true; do
            [ -f "${STATE_DIR}/STOP" ] && { log "STOP flag present; exiting loop"; break; }
            loop_once
            log "sleeping ${interval}s"; sleep "$interval"
        done ;;
    install)   cron_install "${2:-30}" ;;
    uninstall) cron_uninstall ;;
    *) echo "usage: loop.sh {once|run [interval_seconds]|install [minutes]|uninstall}"; exit 1 ;;
esac
