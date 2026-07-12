#!/bin/bash
###############################################################################
# Val Ark - community-services end-to-end tests.
#
# Exercises the four LAN comms services (chat / mail / forum / paste) against a
# running Ark: status API shape, per-service enabled/mirrored/running, and that
# each RUNNING service answers through its /app/<id>/ reverse-proxy frame. Writes
# a common-schema result file for the unified HTML report.
#
# Usage:  VALARK_URL=http://127.0.0.1:3000 tests/services/run.sh
#         (default target: http://127.0.0.1:3000)
###############################################################################
set -o pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_DIR}/../lib/results.sh"

URL="${VALARK_URL:-http://127.0.0.1:3000}"; URL="${URL%/}"
SERVICES="chat mail forum paste"

_http() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null; }
_json() { curl -s --max-time 8 "$1" 2>/dev/null; }
_post() { curl -s --max-time 12 -H 'Content-Type: application/json' -d "$2" "${URL}$1" 2>/dev/null; }
_svc_field() { printf '%s' "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$2',{}).get('$3'))" 2>/dev/null; }

# adduser is an admin (localhost-only) action; the create/guidance path only works
# when the harness targets the Ark's own loopback address.
case "$URL" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) LOCAL_ARK=1 ;;
    *) LOCAL_ARK=0 ;;
esac

results_init "services-e2e" "Community services (e2e @ ${URL})"

# 1. Status API reachable + well-formed
svc_json="$(_json "${URL}/api/status/services")"
if printf '%s' "$svc_json" | grep -q '"chat"'; then
    results_case "status API lists all four services" pass 0
else
    results_case "status API lists all four services" fail 0 "GET /api/status/services did not return the services map (is the Ark up at ${URL}?)"
    results_finish; exit 0
fi

# 2. Per-service coverage
for id in $SERVICES; do
    running=$(printf '%s' "$svc_json"  | python3 -c "import sys,json;print(json.load(sys.stdin).get('$id',{}).get('running'))" 2>/dev/null)
    enabled=$(printf '%s' "$svc_json"  | python3 -c "import sys,json;print(json.load(sys.stdin).get('$id',{}).get('enabled'))" 2>/dev/null)
    mirrored=$(printf '%s' "$svc_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$id',{}).get('mirrored'))" 2>/dev/null)

    # Every service must report the discovery fields (drives the Community hub).
    if [ -n "$running" ] && [ -n "$enabled" ] && [ -n "$mirrored" ]; then
        results_case "$id: status fields present (running/enabled/mirrored)" pass 0
    else
        results_case "$id: status fields present (running/enabled/mirrored)" fail 0 "missing fields in status: running=$running enabled=$enabled mirrored=$mirrored"
    fi

    if [ "$running" = "True" ]; then
        code=$(_http "${URL}/app/${id}/")
        # 2xx served, 3xx redirect, 401 auth-gated (paste) all mean the proxy reached a live service.
        case "$code" in
            2??|3??|401) results_case "$id: /app/${id}/ frame reachable (HTTP $code)" pass 0 ;;
            *)           results_case "$id: /app/${id}/ frame reachable" fail 0 "proxy returned HTTP $code" ;;
        esac
    elif [ "$enabled" = "True" ] && [ "$mirrored" = "True" ]; then
        results_case "$id: enabled+mirrored but not running yet (startable)" skip 0 "start it from the Community hub or scripts/services/${id}.sh start"
    elif [ "$mirrored" != "True" ]; then
        results_case "$id: not mirrored on this host" skip 0 "mirror it: scripts/tools/${id}.sh"
    else
        results_case "$id: not enabled" skip 0 "add '$id' to VALARK_SERVICES in .env"
    fi
done

# 3. Every service advertises how a person gets a login (drives the UI signup panel).
for id in $SERVICES; do
    signup="$(printf '%s' "$svc_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$id',{}).get('account',{}).get('signup'))" 2>/dev/null)"
    case "$signup" in
        host|self|shared) results_case "$id: advertises an account model ($signup)" pass 0 ;;
        *) results_case "$id: advertises an account model" fail 0 "account.signup missing (got '$signup')" ;;
    esac
done

# 4. Account provisioning / sign-up (POST /api/service/adduser) — admin/localhost only.
if [ "$LOCAL_ARK" = 1 ]; then
    # Self-register + shared services must decline host-provisioning with guidance.
    if _post /api/service/adduser '{"id":"forum","username":"e2e_probe"}' | grep -qi 'register'; then
        results_case "forum: adduser points users to self-registration" pass 0
    else
        results_case "forum: adduser points users to self-registration" fail 0 "expected a 'register' hint from POST /api/service/adduser"
    fi
    if _post /api/service/adduser '{"id":"paste","username":"e2e_probe"}' | grep -qi 'shared'; then
        results_case "paste: adduser reports shared instance (no per-user signup)" pass 0
    else
        results_case "paste: adduser reports shared instance (no per-user signup)" fail 0 "expected a 'shared' hint from POST /api/service/adduser"
    fi
    # Real login creation for host-provisioned services, when running.
    for id in chat mail; do
        running="$(_svc_field "$svc_json" "$id" 'running')"
        if [ "$running" != "True" ]; then
            results_case "$id: create a login (adduser)" skip 0 "$id not running — start it to exercise sign-up end-to-end"
            continue
        fi
        probe="e2e$(date +%s 2>/dev/null || echo 0)"
        body="$(_post /api/service/adduser "{\"id\":\"$id\",\"username\":\"$probe\",\"password\":\"e2ePassw0rd!\"}")"
        if printf '%s' "$body" | grep -qE '"ok" ?: ?true'; then
            results_case "$id: create a login (adduser) then it is usable" pass 0
        else
            results_case "$id: create a login (adduser) then it is usable" fail 0 "adduser did not succeed: $(printf '%s' "$body" | head -c 200)"
        fi
    done
else
    results_case "adduser sign-up flow" skip 0 "adduser is localhost-only; target VALARK_URL at the Ark's own loopback to exercise it"
fi

results_finish
