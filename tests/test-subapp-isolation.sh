#!/bin/bash
###############################################################################
# Test: community sub-apps can't act as the Val Ark UI (#317).
#
# /app/<id>/ is same-origin with the UI and localhost counts as Admin, so a user's
# uploaded HTML served through the proxy must not be able to run as that origin, and
# a page under /app/ or /kiwix/ must not be able to call /api/*. Stub upstreams (one
# small Python server per sub-app port) stand in for MicroBin, NodeBB, The Lounge and
# alps; each answers HTML and echoes the path and cookies it was given.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
. "$ROOT/tests/lib/require-cmd.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || missing_cmd node "sub-app isolation"
require_python3 "sub-app isolation (stub upstreams)"

SRV_PID=""; STUB_PID=""
T="$(mktemp -d)"; trap 'stop_pids "$SRV_PID" "$STUB_PID"; rm -rf "$T"' EXIT
trap_signals
mkdir -p "$T/state" "$T/content/zim" "$T/models"

cat > "$T/stub.py" <<'PY'
import sys, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self):
        p = self.path
        body = ("<!doctype html><title>stub</title><script>fetch('/api/maintenance/repair',{method:'POST'})</script>STUB %s" % p).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Stub-Path", p)
        self.send_header("X-Stub-Cookie", self.headers.get("Cookie", ""))
        if "withcsp" in p:
            self.send_header("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; img-src 'self'")
            self.send_header("X-Frame-Options", "DENY")
        if "dispo" in p:
            self.send_header("Content-Disposition", 'inline; filename="x.html"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = answer
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        self.answer()
for port in sys.argv[1:]:
    s = ThreadingHTTPServer(("127.0.0.1", int(port)), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
PY
CHAT_P=$(free_port); MAIL_P=$(free_port); FORUM_P=$(free_port); PASTE_P=$(free_port)
python3 -I "$T/stub.py" "$CHAT_P" "$MAIL_P" "$FORUM_P" "$PASTE_P" >"$T/stub.log" 2>&1 &
STUB_PID=$!

"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("open",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state"
PORT=$(free_port); B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  VALARK_CHAT_WEB_PORT="$CHAT_P" VALARK_MAIL_WEB_PORT="$MAIL_P" VALARK_FORUM_PORT="$FORUM_P" PASTE_PORT="$PASTE_P" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do
    sleep 0.5
    curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 \
      && curl -sf --max-time 2 "$B/app/chat/" >/dev/null 2>&1 && { up=1; break; }
done
if [ "$up" != 1 ]; then
    fail "server + stub upstreams did not start"; tail -5 "$T/srv.log" "$T/stub.log" >&2
    echo "subapp-isolation: ${PASS} passed, ${FAIL} failed"; exit 1
fi
pass

# hdrs URL [curl args] -> lowercased response headers (CR stripped)
hdrs() { local u="$1"; shift; curl -s -D - -o /dev/null --max-time 6 "$@" "$B$u" | tr -d '\r' | tr 'A-Z' 'a-z'; }
sandboxed() {   # URL: the sandbox policy (no allow-same-origin) + nosniff, still served (200)
    local h; h="$(hdrs "$1")"
    echo "$h" | head -1 | grep -q ' 200' || { fail "$1 must still be served (got: $(echo "$h" | head -1))"; return; }
    echo "$h" | grep -q "^content-security-policy: sandbox allow-scripts allow-forms allow-popups allow-downloads$" \
      && ! echo "$h" | grep -q 'allow-same-origin' \
      && echo "$h" | grep -q '^x-content-type-options: nosniff' \
      && pass || fail "$1 must carry the sandbox CSP + nosniff (headers: $(echo "$h" | grep -E '^(content-security|x-content)' | tr '\n' ' '))"
}
not_sandboxed() {   # URL: a normal app page or asset, served without the sandbox
    local h; h="$(hdrs "$1")"
    echo "$h" | head -1 | grep -q ' 200' && ! echo "$h" | grep -q 'sandbox' \
      && pass || fail "$1 must be served normally, no sandbox (headers: $(echo "$h" | head -1) $(echo "$h" | grep '^content-security' | tr '\n' ' '))"
}

# 1. User content: uploads, raw pastes, mail parts get the sandbox.
for u in "/app/paste/file/abc?preview=true" /app/paste/file/abc /app/paste/raw/abc /app/paste/secure_file/abc \
         /app/paste/archive/abc /app/paste/%66ile/abc /app/forum/assets/uploads/files/evil.html \
         /app/forum/uploads/files/evil.html /app/forum/ASSETS/uploads/files/evil.html \
         /app/chat/uploads/0123abcd/evil.html /app/chat/storage/ab/cd.png \
         /app/mail/mailboxes/INBOX/messages/3/raw "/app/mail/mailboxes/INBOX/messages/3/raw?part=1" \
         /app/mail/message/INBOX/3/raw "/app/mail/proxy?src=x" /app/mail/bimi/avatar; do
    sandboxed "$u"
done
# 2. Any sub-app response with Content-Disposition (a file) is sandboxed too.
sandboxed /app/paste/dispo/unknown-route
# 3. Normal app pages and assets keep working: chat client, forum pages + assets, paste UI.
for u in /app/chat/ /app/chat/js/bundle.js /app/forum/ /app/forum/topic/1/hello /app/forum/assets/nodebb.min.js \
         /app/forum/assets/client.css /app/paste/ /app/paste/upload/abc /app/paste/p/abc /app/paste/static/x.css \
         /app/mail/ /app/mail/mailboxes/INBOX; do
    not_sandboxed "$u"
done
# 4. The upstream's own CSP survives minus frame-ancestors (so the frame still works);
#    X-Frame-Options is still dropped; on user content both policies apply.
h="$(hdrs /app/chat/withcsp)"
echo "$h" | grep -q "^content-security-policy: default-src 'self'; img-src 'self'$" && pass || fail "upstream CSP must be kept minus frame-ancestors ($(echo "$h" | grep '^content-security' | tr '\n' ' '))"
echo "$h" | grep -q '^x-frame-options' && fail "X-Frame-Options must still be dropped" || pass
h="$(hdrs /app/chat/uploads/withcsp/x.html)"
[ "$(echo "$h" | grep -c '^content-security-policy:')" = 2 ] \
  && echo "$h" | grep -q "^content-security-policy: default-src 'self'; img-src 'self'$" \
  && echo "$h" | grep -q '^content-security-policy: sandbox ' \
  && pass || fail "user content with an upstream CSP must carry both policies ($(echo "$h" | grep '^content-security' | tr '\n' ' '))"
# 5. Proxy plumbing unchanged: prefix strip per app, session cookie never forwarded.
h="$(hdrs /app/chat/foo)"; echo "$h" | grep -q '^x-stub-path: /foo$' && pass || fail "chat must get the stripped path"
h="$(hdrs /app/forum/foo)"; echo "$h" | grep -q '^x-stub-path: /app/forum/foo$' && pass || fail "forum must keep its base path"
h="$(hdrs /app/paste/file/abc -H 'Cookie: varksid=secret.token; other=1')"
echo "$h" | grep -q '^x-stub-cookie: other=1$' && pass || fail "varksid must not reach the sub-app ($(echo "$h" | grep '^x-stub-cookie'))"

# 6. /api/* refuses calls from a page under /app/ or /kiwix/ (defence in depth). The
#    server sees 127.0.0.1 here, the Admin, so only the new guard stands in the way.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
rpost() { code -X POST -H "Origin: $B" -H 'Content-Type: application/json' -H "Referer: $1" --data '{}' "$B/api/maintenance/repair"; }
for r in "$B/app/paste/file/abc?preview=true" "$B/app/forum/assets/uploads/files/x.html" "$B/kiwix/content/x/A/y" \
         "$B/app" "$B/%61pp/chat/" "$B//app/chat/" "$B/APP/chat/" "$B/./app/mail/"; do
    c=$(rpost "$r"); [ "$c" = "403" ] && pass || fail "POST /api with Referer $r must be 403 (got $c)"
done
c=$(code -X POST -H 'Content-Type: application/json' -H "Referer: $B/app/chat/" --data '{"password":"x"}' "$B/api/auth/login")
[ "$c" = "403" ] && pass || fail "even auth POSTs from a sub-app page must be 403 (got $c)"
for r in "$B/" "$B/#/settings" "$B/application" "$B/apps"; do
    c=$(rpost "$r"); [ "$c" != "403" ] && pass || fail "POST /api with Referer $r (the UI) must be accepted (got $c)"
done
c=$(code -X POST -H 'Content-Type: application/json' --data '{}' "$B/api/maintenance/repair"); [ "$c" != "403" ] && pass || fail "a header-less client must still work (got $c)"
# script reads (fetch/XHR) from a sub-app page are refused; navigations and downloads aren't
c=$(code -H "Referer: $B/app/forum/topic/1" -H 'Sec-Fetch-Dest: empty' "$B/api/status/disk"); [ "$c" = "403" ] && pass || fail "fetch() of /api from a sub-app page must be 403 (got $c)"
c=$(code -H "Referer: $B/app/forum/topic/1" -H 'Sec-Fetch-Dest: document' "$B/api/status/disk"); [ "$c" = "200" ] && pass || fail "a link from a sub-app page to /api must still navigate (got $c)"
c=$(code -H "Referer: $B/" -H 'Sec-Fetch-Dest: empty' "$B/api/status/disk"); [ "$c" = "200" ] && pass || fail "the UI's own fetch() must be accepted (got $c)"
# a POST to the sub-app itself (chat login, forum reply, paste upload) still goes through
c=$(code -X POST -H "Origin: $B" -H "Referer: $B/app/paste/" --data 'x=1' "$B/app/paste/upload"); [ "$c" = "200" ] && pass || fail "a POST inside the sub-app must still reach it (got $c)"

# 7. The session cookie stays HttpOnly + SameSite and site-wide (the read-wall needs it on /app/).
ck="$(curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/json' --data '{"password":"testpass"}' "$B/api/auth/login" | tr -d '\r' | grep -i '^set-cookie: varksid=')"
echo "$ck" | grep -qi 'HttpOnly' && echo "$ck" | grep -qi 'SameSite=Lax' && echo "$ck" | grep -qi 'Path=/;' \
  && pass || fail "session cookie must be HttpOnly; SameSite=Lax; Path=/ ($ck)"

echo "subapp-isolation: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
