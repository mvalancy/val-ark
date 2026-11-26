#!/bin/bash
###############################################################################
# Test: Gitea as a Val Ark app (#346). All offline, temp dirs only.
#
#  1. scripts/tools/gitea.sh against a stub dl.gitea.com (python http.server on a free
#     port, GITEA_DL_BASE): the latest version comes from version.json (the pin when it
#     can't be read), each platform fetches its own upstream file name and lands at
#     tools/<platform>/gitea/gitea[.exe] with .version + INSTALL.txt, a re-run is a no-op,
#     a new release replaces the old one, and a checksum mismatch or a missing platform
#     is a logged ERROR with the bad file removed.
#  2. scripts/services/gitea.sh: app.ini binds 127.0.0.1 whatever VALARK_BIND says,
#     ROOT_URL carries /app/gitea/, registration is off, SQLite, offline, mode 600, the
#     secrets survive a rewrite, and a hostile VALARK_GITEA_ROOT_URL can't add ini lines.
#     A stub binary checks start (127.0.0.1, --config) and adduser (first = --admin).
#  3. server.js sandboxes Gitea's user content (raw, media, attachments, release
#     downloads, archives, packages, LFS, avatars) and not its own pages; strips the
#     /app/gitea prefix, passes the browser's Host through and sets X-Forwarded-Proto.
#  4. verify.sh's verify_gitea: PASS on a binary that answers --version, FAIL otherwise.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
. "$ROOT/tests/lib/require-cmd.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
require_python3 "gitea (stub download server + stub upstream)"
require_cmd curl "gitea (stub downloads)"
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || missing_cmd node "gitea sandbox routes"

T="$(mktemp -d)"; DL_PID=""; SRV_PID=""; STUB_PID=""
cleanup() {
    local svc; svc="$(cat "$T/state/services/gitea/gitea.pid" 2>/dev/null)"
    stop_pids "$DL_PID" "$SRV_PID" "$STUB_PID" "$svc"
    rm -rf "${T:?}"
}
trap cleanup EXIT
trap_signals
# Keep valark-env.sh away from the real data root and the repo's .env.
export VAL_ARK_DATA="$T/data" VAL_ARK_CONFIG="$T/none.env" VALARK_TOOLS_DIR="$T/tools" \
       VALARK_STATE_DIR="$T/state" FORCE_COLOR=0 VALARK_DL_RETRIES=1 VALARK_DL_RETRY_DELAY=0
mkdir -p "$VAL_ARK_DATA" "$T/state"
SH="$ROOT/scripts/tools/gitea.sh"
bash -n "$SH" && pass || fail "scripts/tools/gitea.sh must parse"
bash -n "$ROOT/scripts/services/gitea.sh" && pass || fail "scripts/services/gitea.sh must parse"

# --- 1. the mirror script -------------------------------------------------------------
DL="$T/dl"
mk_release() {   # mk_release VERSION -> every platform file + its .sha256
    local v="$1" f
    mkdir -p "$DL/$v"
    for f in linux-amd64 linux-arm64 darwin-arm64 windows-amd64.exe linux-riscv64 darwin-amd64; do
        printf 'gitea %s %s binary\n' "$v" "$f" > "$DL/$v/gitea-$v-$f"
        ( cd "$DL/$v" && sha256sum "gitea-$v-$f" > "gitea-$v-$f.sha256" )
    done
}
mk_release 28.9.0
printf '{"latest":{"version":"28.9.0"}}\n' > "$DL/version.json"
DLP=$(free_port)
python3 -I -m http.server --bind 127.0.0.1 --directory "$DL" "$DLP" >"$T/dl.log" 2>&1 &
DL_PID=$!
for i in $(seq 1 20); do curl -sf -o /dev/null "http://127.0.0.1:$DLP/version.json" && break; sleep 0.25; done
export GITEA_DL_BASE="http://127.0.0.1:$DLP"
run_tool() { VALARK_STRICT_EXIT=1 bash "$SH" >"$T/tool.out" 2>&1; }

run_tool; rc=$?
[ "$rc" = 0 ] && pass || fail "a clean mirror must exit 0 (rc=$rc; $(tail -3 "$T/tool.out"))"
grep -q 'ERROR' "$T/tool.out" && fail "a clean mirror must log no ERROR ($(grep ERROR "$T/tool.out"))" || pass
for pair in linux-x86_64:linux-amd64:gitea linux-arm64:linux-arm64:gitea \
            macos-arm64:darwin-arm64:gitea windows-x64:windows-amd64.exe:gitea.exe; do
    IFS=: read -r plat up bin <<<"$pair"
    f="$T/tools/$plat/gitea/$bin"
    cmp -s "$f" "$DL/28.9.0/gitea-28.9.0-$up" && pass || fail "$plat must hold gitea-28.9.0-$up as $bin"
    [ -x "$f" ] && pass || fail "$plat/$bin must be executable"
    [ "$(cat "$T/tools/$plat/gitea/.version" 2>/dev/null)" = "28.9.0" ] && pass || fail "$plat must be stamped 28.9.0"
    grep -q "Gitea 28.9.0" "$T/tools/$plat/gitea/INSTALL.txt" 2>/dev/null && pass || fail "$plat must carry an INSTALL.txt hint"
done
grep -q 'GET /version.json' "$T/dl.log" && pass || fail "the version must come from version.json"
for f in linux-riscv64 darwin-amd64; do
    grep -q "gitea-28.9.0-$f" "$T/dl.log" && fail "no Val Ark platform uses $f; it must not be fetched" || pass
done
ls "$T"/tools/*/gitea/*.part >/dev/null 2>&1 && fail "no .part file may be left behind" || pass

# Re-run: nothing re-downloaded.
: > "$T/dl.log"
run_tool
grep -q 'GET /28.9.0/gitea-28.9.0-linux-amd64 ' "$T/dl.log" && fail "a re-run must not download a current binary again" || pass
grep -q 'Already exists: gitea linux-x86_64' "$T/tool.out" && pass || fail "a re-run must report the binary as present"
grep -q 'Created install instructions' "$T/tool.out" && fail "a re-run must not rewrite an unchanged INSTALL.txt" || pass

# A new release replaces the old one in place.
mk_release 28.10.0
printf '{"latest":{"version":"28.10.0"}}\n' > "$DL/version.json"
run_tool
cmp -s "$T/tools/linux-arm64/gitea/gitea" "$DL/28.10.0/gitea-28.10.0-linux-arm64" \
  && [ "$(cat "$T/tools/linux-arm64/gitea/.version")" = "28.10.0" ] && pass || fail "a new release must replace the mirrored one"

# Checksum mismatch on one platform, another missing upstream: ERRORs, bad file removed,
# the rest still mirrored (a partial run, exit 0 under strict mode).
mk_release 28.11.0
printf 'tampered\n' > "$DL/28.11.0/gitea-28.11.0-linux-arm64"
rm -f "$DL/28.11.0/gitea-28.11.0-windows-amd64.exe" "$DL/28.11.0/gitea-28.11.0-windows-amd64.exe.sha256"
printf '{"latest":{"version":"28.11.0"}}\n' > "$DL/version.json"
run_tool; rc=$?
grep -q 'ERROR.*gitea linux-arm64: sha256 mismatch' "$T/tool.out" && pass || fail "a checksum mismatch must be a logged ERROR ($(grep -i 'arm64' "$T/tool.out" | tail -2))"
[ -e "$T/tools/linux-arm64/gitea/gitea" ] && fail "a binary that fails its checksum must be removed" || pass
grep -q 'ERROR.*gitea windows-x64' "$T/tool.out" && pass || fail "a platform missing upstream must be a logged ERROR"
cmp -s "$T/tools/linux-x86_64/gitea/gitea" "$DL/28.11.0/gitea-28.11.0-linux-amd64" && pass || fail "the good platforms must still be mirrored"
grep -q 'complete' "$T/tool.out" && fail "a partial mirror must not claim complete" || pass
[ "$rc" = 0 ] && grep -q 'PARTIAL' "$T/tool.out" && pass || fail "a partial mirror must exit 0 and say PARTIAL (rc=$rc)"

# Nothing reachable at all: strict mode exits 1.
GITEA_DL_BASE="http://127.0.0.1:$(free_port)" VALARK_TOOLS_DIR="$T/tools-empty" VALARK_STRICT_EXIT=1 \
    bash "$SH" >"$T/tool-none.out" 2>&1 && fail "a run that mirrors nothing must exit non-zero" || pass
# version.json unreadable -> the pin.
v=$(GITEA_DL_BASE="http://127.0.0.1:$(free_port)" bash -c 'source "$1"; gitea_latest_version' _ "$SH" 2>/dev/null)
pin=$(sed -n 's/^PINNED_VERSION="\(.*\)"/\1/p' "$SH")
[ -n "$v" ] && [ "$v" = "$pin" ] && pass || fail "an unreadable version.json must fall back to the pin ($v vs $pin)"
stop_pids "$DL_PID"; DL_PID=""

# --- 2. the service: app.ini ------------------------------------------------------------
SVC="$ROOT/scripts/services/gitea.sh"
INI="$T/state/services/gitea/custom/conf/app.ini"
ini() {   # ini SECTION KEY -> value ('' = the top-level section)
    awk -v s="$1" -v k="$2" '
        /^\[/ { cur = substr($0, 2, length($0) - 2); next }
        cur == s && $1 == k { sub(/^[^=]*=[ ]*/, ""); print; exit }' "$INI"
}
WP=$(free_port)   # only the ROOT_URL fallback's port; nothing listens on it
VALARK_BIND=0.0.0.0 VALARK_WEB_PORT="$WP" bash "$SVC" config >"$T/cfg.out" 2>&1
[ -f "$INI" ] || fail "gitea.sh config must write app.ini ($(cat "$T/cfg.out"))"
[ "$(ini server HTTP_ADDR)" = "127.0.0.1" ] && pass || fail "HTTP_ADDR must be 127.0.0.1 with VALARK_BIND=0.0.0.0 (got $(ini server HTTP_ADDR))"
grep -q '0\.0\.0\.0' "$INI" && fail "app.ini must not mention 0.0.0.0" || pass
[ "$(ini server HTTP_PORT)" = "3300" ] && pass || fail "the default port must be 3300 (server.js APP_SERVICES)"
grep -q "gitea: { port: envPort('VALARK_GITEA_PORT', 3300)" "$ROOT/scripts/server.js" && pass || fail "server.js must proxy the same port key + default"
DEF_RE="^http://(localhost|10\.[0-9.]+|192\.168\.[0-9.]+|172\.[0-9.]+):$WP/app/gitea/\$"
ini server ROOT_URL | grep -qE "$DEF_RE" && pass || fail "the default ROOT_URL is the box's LAN address + /app/gitea/ (got $(ini server ROOT_URL))"
[ "$(stat -c %a "$T/state/services/gitea")" = "700" ] && pass || fail "the data dir (gitea.db: password hashes) must be mode 700 (got $(stat -c %a "$T/state/services/gitea"))"
chmod 755 "$T/state/services/gitea"; bash "$SVC" config >/dev/null 2>&1
[ "$(stat -c %a "$T/state/services/gitea")" = "700" ] && pass || fail "a loosened data dir must be tightened back to 700 on the next start"
[ "$(ini service ENABLE_REVERSE_PROXY_AUTHENTICATION)" = "false" ] && [ "$(ini service ENABLE_REVERSE_PROXY_AUTO_REGISTRATION)" = "false" ] \
  && [ "$(ini security REVERSE_PROXY_TRUSTED_PROXIES)" = "127.0.0.0/8,::1/128" ] && pass || fail "header auth must be off and only loopback trusted as a proxy"
# While our <name>.local is announced (state/mdns.json, as server.js boxAddress() reads it) it wins.
printf '{"ts":"x","name":"Shed Ark","label":"shed-ark","host":"shed-ark.local","state":"published","canPublish":true}\n' > "$T/state/mdns.json"
VALARK_WEB_PORT="$WP" bash "$SVC" config >/dev/null 2>&1
[ "$(ini server ROOT_URL)" = "http://shed-ark.local:$WP/app/gitea/" ] && pass || fail "an announced mDNS name must be the default host (got $(ini server ROOT_URL))"
printf '{"ts":"x","label":"shed-ark","state":"unavailable","reason":"no avahi"}\n' > "$T/state/mdns.json"
VALARK_WEB_PORT="$WP" bash "$SVC" config >/dev/null 2>&1
ini server ROOT_URL | grep -qE "$DEF_RE" && pass || fail "an unannounced name must not be used (got $(ini server ROOT_URL))"
rm -f "$T/state/mdns.json"
[ "$(ini service DISABLE_REGISTRATION)" = "true" ] && pass || fail "registration must be off"
[ "$(ini service SHOW_REGISTRATION_BUTTON)" = "false" ] && pass || fail "the register button must be hidden"
[ "$(ini database DB_TYPE)" = "sqlite3" ] && pass || fail "the database must be SQLite"
[ "$(ini server OFFLINE_MODE)" = "true" ] && [ "$(ini server DISABLE_SSH)" = "true" ] && [ "$(ini mailer ENABLED)" = "false" ] \
  && [ "$(ini cron.update_checker ENABLED)" = "false" ] && [ "$(ini actions ENABLED)" = "false" ] \
  && pass || fail "offline posture: OFFLINE_MODE, no SSH, no mailer, no update checker, no Actions"
[ "$(ini security INSTALL_LOCK)" = "true" ] && pass || fail "INSTALL_LOCK must skip the web installer"
[ "$(ini server PUBLIC_URL_DETECTION)" = "auto" ] && pass || fail "absolute links must follow the browser's Host"
[ "$(stat -c %a "$INI")" = "600" ] && pass || fail "app.ini carries secrets: mode 600 (got $(stat -c %a "$INI"))"
[ "$(stat -c %a "$T/state/services/gitea/secrets.env")" = "600" ] && pass || fail "secrets.env must be mode 600"
key1=$(ini security SECRET_KEY)
VALARK_GITEA_ROOT_URL='https://ark.example:8443/some/path?x=1' bash "$SVC" config >/dev/null 2>&1
[ "$(ini server ROOT_URL)" = "https://ark.example:8443/app/gitea/" ] && [ "$(ini server DOMAIN)" = "ark.example" ] \
  && pass || fail "VALARK_GITEA_ROOT_URL keeps only the origin (got $(ini server ROOT_URL) / $(ini server DOMAIN))"
[ -n "$key1" ] && [ "$(ini security SECRET_KEY)" = "$key1" ] && pass || fail "secrets must survive a rewrite"
VALARK_GITEA_ROOT_URL=$'http://x.example\nHTTP_ADDR = 0.0.0.0' VALARK_WEB_PORT="$WP" bash "$SVC" config >/dev/null 2>&1
grep -c '^HTTP_ADDR' "$INI" | grep -qx 1 && [ "$(ini server HTTP_ADDR)" = "127.0.0.1" ] && pass || fail "a multi-line ROOT_URL must not inject ini keys"
VALARK_GITEA_ROOT_URL='http://x.example bad/' VALARK_WEB_PORT="$WP" bash "$SVC" config >/dev/null 2>&1
ini server ROOT_URL | grep -qE "$DEF_RE" && pass || fail "a malformed root url falls back to the default (got $(ini server ROOT_URL))"
VALARK_GITEA_REQUIRE_SIGNIN=1 bash "$SVC" config >/dev/null 2>&1
[ "$(ini service REQUIRE_SIGNIN_VIEW)" = "true" ] && pass || fail "VALARK_GITEA_REQUIRE_SIGNIN=1 must require sign-in"

# --- 2b. start + adduser with a stub binary ------------------------------------------
case "$(uname -s)/$(uname -m)" in
    Linux/aarch64|Linux/arm64) sub=linux-arm64 ;; Linux/*) sub=linux-x86_64 ;; Darwin/*) sub=macos-arm64 ;; *) sub=windows-x64 ;;
esac
SVC_TOOLS="$T/svc-tools"; BIN="$SVC_TOOLS/$sub/gitea/gitea"; mkdir -p "$(dirname "$BIN")"
cat > "$BIN" <<EOF
#!/bin/bash
echo "\$*" >> "$T/stub-argv.log"
case "\$1" in
  --version) echo "gitea version 9.9.9 built with go1.99"; exit 0 ;;
  migrate) exit 0 ;;
  admin) case " \$* " in *" --random-password "*) echo "generated random password is 'Gen3ratedPw42'" ;; esac
         echo "New user has been successfully created!"; exit 0 ;;
  web)
    ini=""; while [ \$# -gt 0 ]; do [ "\$1" = --config ] && ini="\$2"; shift; done
    addr=\$(awk -F' = ' '\$1=="HTTP_ADDR"{print \$2}' "\$ini"); port=\$(awk -F' = ' '\$1=="HTTP_PORT"{print \$2}' "\$ini")
    mkdir -p "$T/www/api"; echo ok > "$T/www/api/healthz"
    exec python3 -I -m http.server --bind "\$addr" --directory "$T/www" "\$port" ;;
esac
exit 2
EOF
chmod +x "$BIN"
GP=$(free_port)
if command -v git >/dev/null 2>&1; then
    VALARK_TOOLS_DIR="$SVC_TOOLS" VALARK_GITEA_PORT="$GP" VALARK_BIND=0.0.0.0 timeout 60 bash "$SVC" start >"$T/start.out" 2>&1
    grep -q "^web --config $INI --work-path $T/state/services/gitea" "$T/stub-argv.log" 2>/dev/null && pass \
      || fail "start must run 'web --config <app.ini> --work-path <data>' ($(cat "$T/stub-argv.log" 2>/dev/null); $(tail -2 "$T/start.out"))"
    curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:$GP/api/healthz" && pass || fail "the stub must answer on 127.0.0.1:$GP"
    grep -q '0\.0\.0\.0' "$T/start.out" && fail "start must not report a 0.0.0.0 address" || pass
    VALARK_TOOLS_DIR="$SVC_TOOLS" VALARK_GITEA_PORT="$GP" bash "$SVC" status >/dev/null 2>&1 && pass || fail "status must report running"
    VALARK_TOOLS_DIR="$SVC_TOOLS" VALARK_GITEA_PORT="$GP" bash "$SVC" stop >/dev/null 2>&1
    curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$GP/api/healthz" && fail "stop must stop the service" || pass
else
    if ci_is_set; then fail "git is required under CI (gitea.sh start needs it)"; else echo "  SKIP: gitea start (no git)" >&2; fi
fi
: > "$T/stub-argv.log"
VALARK_TOOLS_DIR="$SVC_TOOLS" bash "$SVC" adduser alice 'pw-alice-123' >"$T/add1.out" 2>&1
VALARK_TOOLS_DIR="$SVC_TOOLS" bash "$SVC" adduser bob >"$T/add2.out" 2>&1
c1=$(grep '^admin user create' "$T/stub-argv.log" | sed -n 1p); c2=$(grep '^admin user create' "$T/stub-argv.log" | sed -n 2p)
grep -q '^migrate --config' "$T/stub-argv.log" && pass || fail "adduser must migrate the database first"
case "$c1" in *"--username alice"*"--admin"*) pass ;; *) fail "the first login must be the site admin ($c1)" ;; esac
case "$c1" in *"--must-change-password=false"*) pass ;; *) fail "a login given a password needn't change it ($c1)" ;; esac
case "$c2" in *"--username bob"*) pass ;; *) fail "the second adduser must create bob ($c2)" ;; esac
case "$c2" in *"--admin"*) fail "only the first login is the admin ($c2)" ;; *) pass ;; esac
case "$c2" in *"--must-change-password=true"*) pass ;; *) fail "a generated password must be changed at first sign-in ($c2)" ;; esac
case "$c2" in *"--random-password"*) pass ;; *) fail "Gitea must generate the password (--random-password) ($c2)" ;; esac
case "$c2" in *"--password "*) fail "a generated password must never be on the argv ($c2)" ;; *) pass ;; esac
tail -1 "$T/add2.out" | grep -q "temporary password: Gen3ratedPw42 " && pass || fail "the generated password is printed once ($(tail -1 "$T/add2.out"))"
grep -q 'Gen3ratedPw42' "$T/state/services/gitea/gitea.log" && fail "the generated password must not reach gitea.log" || pass
VALARK_TOOLS_DIR="$SVC_TOOLS" bash "$SVC" adduser 'bad name;rm' >/dev/null 2>&1 && fail "adduser must refuse a bad username" || pass

# --- 3. server.js: Gitea's user content is sandboxed -----------------------------------
cat > "$T/stub.py" <<'PY'
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = b"<!doctype html><script>fetch('/api/maintenance/repair',{method:'POST'})</script>STUB"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Stub-Path", self.path)
        self.send_header("X-Stub-Host", self.headers.get("Host", ""))
        self.send_header("X-Stub-Proto", self.headers.get("X-Forwarded-Proto", ""))
        for h in ("X-Forwarded-For", "X-Real-IP", "X-Forwarded-Host", "X-Forwarded-Server", "Forwarded",
                  "X-WEBAUTH-USER", "X-WEBAUTH-EMAIL", "Remote-User", "X_WEBAUTH_USER"):
            self.send_header("X-Echo-" + h.replace("_", "-u-"), "[%s]" % self.headers.get(h, "-"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
import threading
for port in sys.argv[1:]:
    srv = ThreadingHTTPServer(("127.0.0.1", int(port)), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
threading.Event().wait()
PY
UP=$(free_port); PP=$(free_port)
python3 -I "$T/stub.py" "$UP" "$PP" >"$T/stub.log" 2>&1 &
STUB_PID=$!
mkdir -p "$T/srv/state" "$T/srv/content/zim" "$T/srv/models"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("open",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/srv/state"
PORT=$(free_port); B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/srv/state" VALARK_CONTENT_DIR="$T/srv/content" VALARK_MODELS_DIR="$T/srv/models" \
  VALARK_GITEA_PORT="$UP" PASTE_PORT="$PP" "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do
    sleep 0.5
    curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && curl -sf --max-time 2 "$B/app/gitea/" >/dev/null 2>&1 && { up=1; break; }
done
if [ "$up" != 1 ]; then
    fail "server + stub upstream did not start"; tail -5 "$T/srv.log" "$T/stub.log" >&2
else
    hdrs() { local u="$1"; shift; curl -s -D - -o /dev/null --max-time 6 "$@" "$B$u" | tr -d '\r' | tr 'A-Z' 'a-z'; }
    sandboxed() {
        local h; h="$(hdrs "$1")"
        echo "$h" | head -1 | grep -q ' 200' \
          && echo "$h" | grep -q '^content-security-policy: sandbox allow-scripts allow-forms allow-popups allow-downloads$' \
          && ! echo "$h" | grep -q 'allow-same-origin' && echo "$h" | grep -q '^x-content-type-options: nosniff' \
          && pass || fail "$1 must be served sandboxed + nosniff ($(echo "$h" | grep -E '^(http/|content-security|x-content)' | tr '\n' ' '))"
    }
    not_sandboxed() {
        local h; h="$(hdrs "$1")"
        echo "$h" | head -1 | grep -q ' 200' && ! echo "$h" | grep -q 'sandbox' \
          && pass || fail "$1 is Gitea's own UI and must not be sandboxed ($(echo "$h" | grep -E '^(http/|content-security)' | tr '\n' ' '))"
    }
    for u in /app/gitea/alice/notes/raw/branch/main/evil.html /app/gitea/alice/notes/raw/commit/abc/x.svg \
             /app/gitea/alice/notes/media/branch/main/big.bin /app/gitea/alice/notes/attachments/0b1c-uuid \
             /app/gitea/attachments/0b1c-uuid /app/gitea/alice/notes/releases/download/v1.0/tool.html \
             /app/gitea/alice/notes/archive/main.zip /app/gitea/alice/notes/wiki/raw/Home.md \
             /app/gitea/alice/notes/render/branch/main/x.ipynb \
             /app/gitea/api/v1/repos/alice/notes/raw/evil.html /app/gitea/api/v1/repos/alice/notes/media/x.html \
             /app/gitea/api/packages/alice/generic/pkg/1.0/evil.html /app/gitea/api/packages/alice/npm/pkg/-/pkg-1.0.tgz \
             /app/gitea/alice/notes.git/info/lfs/objects/abc /app/gitea/avatars/abc /app/gitea/repo-avatars/abc \
             /app/gitea/alice/notes/info/lfs/objects/abc /app/gitea/v2/alice/img/blobs/sha256:abc /app/gitea/v2/ \
             /app/gitea/alice/notes/commit/0a1b2c.patch /app/gitea/alice/notes/commit/0a1b2c.diff \
             /app/gitea/alice/notes/pulls/3.patch /app/gitea/alice/notes/pulls/3.diff \
             /app/gitea/alice/notes/compare/main...dev.patch /app/gitea/alice/notes/compare/main...dev.diff \
             /app/gitea/api/v1/repos/alice/notes/git/commits/0a1b2c.diff /app/gitea/api/v1/repos/alice/notes/git/commits/0a1b2c.patch \
             /app/gitea/alice.keys /app/gitea/alice.gpg /app/gitea/ALICE.KEYS \
             /app/gitea/ALICE/notes/RAW/branch/main/x.html /app/gitea/alice/notes/%72aw/branch/main/x.html; do
        sandboxed "$u"
    done
    for u in /app/gitea/ /app/gitea/explore/repos /app/gitea/user/login /app/gitea/alice /app/gitea/alice/notes \
             /app/gitea/alice/notes/src/branch/main/evil.html /app/gitea/alice/notes/issues/1 /app/gitea/alice/notes/releases \
             /app/gitea/assets/css/index.css /app/gitea/assets/js/index.js /app/gitea/api/v1/repos/alice/notes \
             /app/gitea/alice/notes/commit/0a1b2c /app/gitea/alice/notes/pulls/3 /app/gitea/alice/notes/compare/main...dev \
             /app/gitea/alice/notes/pulls/3/files /app/gitea/api/v1/repos/alice/notes/git/commits/0a1b2c; do
        not_sandboxed "$u"
    done
    h="$(hdrs /app/gitea/alice/notes/raw/branch/main/x)"
    echo "$h" | grep -q '^x-stub-path: /alice/notes/raw/branch/main/x$' && pass || fail "the /app/gitea prefix must be stripped ($(echo "$h" | grep x-stub-path))"
    h="$(hdrs /app/gitea/explore -H 'Host: ark.lan:3000' -H 'X-Forwarded-Proto: https')"
    echo "$h" | grep -q '^x-stub-host: ark.lan:3000$' && pass || fail "Gitea must see the browser's Host ($(echo "$h" | grep x-stub-host))"
    echo "$h" | grep -q '^x-stub-proto: http$' && pass || fail "X-Forwarded-Proto must be the listener's scheme, not the client's ($(echo "$h" | grep x-stub-proto))"
    # Identity headers come from the proxy, never the client: every sub-app, not just Gitea.
    forged=(-H 'X-Forwarded-For: 203.0.113.7' -H 'X-Real-IP: 203.0.113.7' -H 'X-Forwarded-Host: x.lan'
            -H 'X-Forwarded-Server: x.lan' -H 'Forwarded: for=203.0.113.7;host=x.lan' -H 'X-WEBAUTH-USER: alice'
            -H 'X-WEBAUTH-EMAIL: alice@x.lan' -H 'Remote-User: alice' -H 'X_WEBAUTH_USER: alice')
    for u in /app/gitea/explore /app/paste/; do
        h="$(hdrs "$u" "${forged[@]}")"
        echo "$h" | grep -q '^x-echo-x-forwarded-for: \[127.0.0.1\]$' && pass \
          || fail "$u: X-Forwarded-For must be the real peer only ($(echo "$h" | grep x-echo-x-forwarded-for))"
        for k in x-real-ip x-forwarded-host x-forwarded-server forwarded x-webauth-user x-webauth-email remote-user x-u-webauth-u-user; do
            echo "$h" | grep -q "^x-echo-$k: \[-\]$" && pass || fail "$u: a client's $k must be stripped ($(echo "$h" | grep "x-echo-$k"))"
        done
    done
    h="$(hdrs /app/paste/ -H 'X-Forwarded-Proto: https')"
    echo "$h" | grep -q '^x-stub-proto: $' && pass || fail "a client's X-Forwarded-Proto must not reach other sub-apps either"
    grep -q 'x\[-_\]webauth' "$ROOT/scripts/server.js" && grep -q 'X_WEBAUTH_USER' "$T/stub.py" && pass || fail "underscore spellings must be covered"
    svc="$(curl -s --max-time 6 "$B/api/status/services")"
    printf '%s' "$svc" | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["gitea"]; sys.exit(0 if d["path"]=="/app/gitea/" and d["account"]["signup"]=="host" else 1)' \
      && pass || fail "/api/status/services must list gitea (host-provisioned logins)"
fi

# --- 4. verify.sh: verify_gitea ---------------------------------------------------------
H="$T/verify-harness.sh"
{
    echo 'PASS=0; FAIL=0; chk() { echo "PASS $*"; }; bad() { echo "FAIL $*"; }'
    awk '/^verify_gitea\(\) \{/,/^\}/' "$ROOT/scripts/verify.sh"
    echo 'verify_gitea "$1"'
} > "$H"
grep -q -- '--version' "$H" && pass || fail "harness must contain the real verify_gitea"
VT="$T/vt"; mkdir -p "$VT/gitea"
out=$(bash "$H" "$VT"); [ -z "$out" ] && pass || fail "no mirrored gitea: no check ($out)"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "gitea version 28.4.0 built with go1.27" && exit 0\nexit 1\n' > "$VT/gitea/gitea"; chmod +x "$VT/gitea/gitea"
out=$(bash "$H" "$VT"); [ "$out" = "PASS tool runs: gitea (28.4.0)" ] && pass || fail "a working gitea must PASS ($out)"
printf '#!/bin/sh\necho "cannot execute binary file: Exec format error" >&2; exit 126\n' > "$VT/gitea/gitea"
out=$(bash "$H" "$VT"); case "$out" in "FAIL tool present but won't run: gitea"*) pass ;; *) fail "a broken gitea must FAIL ($out)" ;; esac
grep -q 'verify_gitea "\$td"' "$ROOT/scripts/verify.sh" && pass || fail "verify_local must call verify_gitea"

echo "gitea: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
