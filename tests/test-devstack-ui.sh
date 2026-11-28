#!/bin/bash
###############################################################################
# Test: the developer stack in the live web UI (#397).
#
# Offline: a fixture dev-stack tree in a temp dir (VALARK_DEVSTACK_DIR), the real
# data/dev-stack.tsv + data/dev-stack-guides/ + data/dev-stack-checks.tsv, and a
# throwaway server.js.
#   1. scripts/lib/devstack.js: platform inference, version order, catalog keys (the
#      same as release_mirror.py guide_key), the shipped guides and check rows.
#   2. GET /api/devstack: every catalog row joined with the tree (versions newest first,
#      files + sizes + platforms + download URLs, sidecars hidden, "not mirrored",
#      index + pypi-top layouts, symlinks never followed); storage counts the tree.
#   3. GET /api/devstack/guide: only catalog keys answer (allowlist); unknown refs and
#      traversal attempts are 404; "see:" guides resolve.
#   4. /api/archive/dev-stack/...: file download, Range, HEAD, containment.
#   5. The read wall (401 unauthed in Passworded mode, 200 with a session) and the
#      public-peer 403 cover the listing, the guide and the downloads.
#   6. verify.sh verify_devstack: PASS / FAIL / SKIP per project from stub programs
#      inside fixture archives, written to state/verify.json; nothing left behind.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
. "$ROOT/tests/lib/require-cmd.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; return 1; fi; }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || missing_cmd node "devstack-ui"
require_python3 "devstack-ui"
require_cmd curl "devstack-ui"

SRV_PID=""
T="$(mktemp -d)"; trap 'stop_pids "$SRV_PID"; rm -rf "${T:?}"' EXIT
trap_signals
D="$T/dev-stack"; DATA="$ROOT/data"
mkdir -p "$T/state" "$T/content/zim" "$T/models" "$T/outside"

# --- 1. the module -----------------------------------------------------------------------
"$NODE" - "$ROOT/scripts/lib/devstack.js" "$DATA" > "$T/unit.out" 2>&1 <<'JSEOF'
const d = require(process.argv[2]), fs = require('fs'), path = require('path'), data = process.argv[3];
const bad = [];
const want = {
  'caddy_2.0.0_linux_amd64.tar.gz': 'linux-x86_64', 'caddy_2.0.0_linux_arm64.tar.gz': 'linux-arm64',
  'caddy_2.0.0_mac_arm64.tar.gz': 'macos-arm64', 'caddy_2.0.0_mac_amd64.tar.gz': '',
  'caddy_2.0.0_windows_amd64.zip': 'windows-x64', 'caddy_2.0.0_windows_arm64.zip': '',
  'caddy_2.0.0_linux_armv7.tar.gz': '', 'caddy_2.0.0_linux_riscv64.tar.gz': '', 'caddy_2.0.0_checksums.txt': '',
  'caddy-v2.0.0-source.tar.gz': 'source', 'go1.30.1.src.tar.gz': 'source', 'go1.30.1.linux-386.tar.gz': '',
  'ninja-linux.zip': 'linux-x86_64', 'ninja-linux-aarch64.zip': 'linux-arm64', 'ninja-mac.zip': 'macos-arm64',
  'ninja-win.zip': 'windows-x64', 'ninja-winarm64.zip': '',
  'cmake-4.5.1-macos-universal.dmg': 'macos-arm64', 'cmake-4.5.1-windows-x86_64.msi': 'windows-x64',
  'KeePassXC-2.8.0-x86_64.AppImage': 'linux-x86_64', 'KeePassXC-2.8.0-aarch64.AppImage': 'linux-arm64',
  'KeePassXC-2.8.0-Win64.msi': 'windows-x64', 'KeePassXC-2.8.0-x86_64.dmg': '',
  'croc_v11.6.7_Linux-64bit.tar.gz': 'linux-x86_64', 'croc_v11.6.7_Linux-32bit.tar.gz': '',
  'croc_v11.6.7_Linux-ARM.tar.gz': '', 'croc_v11.6.7_macOS-ARM64.tar.gz': 'macos-arm64',
  'OpenJDK21U-jdk_aarch64_mac_hotspot_21.pkg': 'macos-arm64', 'OpenJDK21U-jdk_x64_windows_hotspot_21.msi': 'windows-x64',
  'PortableGit-2.56.1-64-bit.7z.exe': 'windows-x64', 'rclone-v1.76.0-osx-arm64.zip': 'macos-arm64',
  'restic_0.20.0_darwin_arm64.bz2': 'macos-arm64', 'headscale_0.29.8_linux_amd64': 'linux-x86_64',
};
for (const [n, p] of Object.entries(want)) if (d.inferPlatform(n) !== p) bad.push(`platform ${n}: ${d.inferPlatform(n)}`);
// a name that says nothing is read with its folders (index / template dirs, the project)
if (d.inferPlatform('docker-29.1.0.tgz', 'download.docker.com/linux/static/stable/aarch64/') !== 'linux-arm64') bad.push('index dir platform');
if (d.inferPlatform('kubectl', 'dl.k8s.io/v1.3/bin/linux/amd64/') !== 'linux-x86_64') bad.push('template dir platform');
if (d.inferPlatform('MinGit-2.56.1-64-bit.zip', 'git-for-windows/git/v2/') !== 'windows-x64') bad.push('project dir platform');
if (d.inferPlatform('docker-29.1.0.tgz') !== '') bad.push('no context -> none');
if (['v1.9.0', 'v1.10.0', 'v2.0.0', 'v1.2'].sort(d.versionCompare).join() !== 'v1.2,v1.9.0,v1.10.0,v2.0.0') bad.push('versionCompare');

const rows = d.parseTsv(fs.readFileSync(path.join(data, 'dev-stack.tsv'), 'utf8'));
const keys = new Set(rows.map((r) => r.key));
if (keys.size !== rows.length) bad.push('catalog keys are not unique');
if (rows.some((r) => !/^[A-Za-z0-9._+@=-]+$/.test(r.key))) bad.push('a catalog key is not a plain file name');
if (rows.some((r) => !d.projectPath(r))) bad.push('a row has no on-disk layout');
const k = (ref) => (rows.find((r) => r.ref === ref) || {}).key;
if (k('caddyserver/caddy') !== 'caddyserver__caddy' || k('-') !== 'go') bad.push('key rule');
if (!rows.some((r) => r.ref === 'schollz/croc' && r.group === 'storage')) bad.push('croc is not in the catalog (#360)');

// the shipped guides: named by catalog keys, short, and present for the projects of #397
const gdir = path.join(data, 'dev-stack-guides');
const guides = fs.readdirSync(gdir);
for (const g of guides) {
  const key = g.replace(/\.md$/, ''), text = fs.readFileSync(path.join(gdir, g), 'utf8');
  if (!g.endsWith('.md') || !keys.has(key)) bad.push(`guide ${g} is not a catalog key`);
  const see = /^see:\s*(\S+)\s*$/.exec(text);
  if (see ? !guides.includes(see[1] + '.md') : text.split('\n').length > 70 || !text.startsWith('# ')) bad.push(`guide ${g}: too long, no title or a dangling see:`);
}
const need = ['go-gitea/gitea', 'https://download.docker.com/linux/static/stable/x86_64/', 'https://download.docker.com/linux/static/stable/aarch64/',
  'docker/compose', 'docker/buildx', 'distribution/distribution', 'caddyserver/caddy', 'juanfont/headscale', 'git-for-windows/git',
  'Kitware/CMake', 'ninja-build/ninja', 'keepassxreboot/keepassxc', 'rclone/rclone', 'restic/restic', 'FiloSottile/age', 'schollz/croc',
  'prometheus/prometheus', 'prometheus/node_exporter', 'prometheus/alertmanager', 'duckdb/duckdb', '-',
  'adoptium/temurin21-binaries', 'adoptium/temurin25-binaries', 'ventoy/Ventoy'];
for (const ref of need) if (!guides.includes(k(ref) + '.md')) bad.push(`no guide for ${ref}`);
const caddy = fs.readFileSync(path.join(gdir, 'caddyserver__caddy.md'), 'utf8');
if (!/tls internal/.test(caddy) || !/root\.crt/.test(caddy)) bad.push('caddy guide: tls internal + trusting the root (#349)');
const hs = fs.readFileSync(path.join(gdir, 'juanfont__headscale.md'), 'utf8');
if (!/--login-server/.test(hs) || !/urls: \[\]/.test(hs)) bad.push('headscale guide: login-server + no public DERP map (#350)');

// the check rows: ref in the catalog, 5+ fields, both regexes compile
const checked = new Set();
for (const line of fs.readFileSync(path.join(data, 'dev-stack-checks.tsv'), 'utf8').split('\n')) {
  if (!line.trim() || line.startsWith('#')) continue;
  const f = line.split('|');
  if (f.length < 5 || !rows.some((r) => r.ref === f[0])) { bad.push(`check row: ${line}`); continue; }
  try { new RegExp(f.slice(1, -3).join('|')); new RegExp(f[f.length - 1]); } catch (e) { bad.push(`check regex: ${line}`); }
  checked.add(f[0]);
}
for (const ref of need) {
  const none = /keepassxc|Ventoy|git-for-windows|temurin/.test(ref);
  if (checked.has(ref) === none) bad.push(`check row for ${ref}: ${none ? 'unexpected' : 'missing'}`);
}
console.log(bad.length ? bad.join('\n') : 'ok');
JSEOF
check "devstack.js: platforms, versions, keys, guides, check rows" 'grep -qx ok "$T/unit.out"' || cat "$T/unit.out" >&2

"$NODE" -e 'const d=require(process.argv[1]);console.log(d.parseTsv(require("fs").readFileSync(process.argv[2],"utf8")).map(r=>r.key).sort().join("\n"))' \
    "$ROOT/scripts/lib/devstack.js" "$DATA/dev-stack.tsv" > "$T/keys.js"
python3 -I - "$ROOT/scripts/lib/release_mirror.py" "$DATA/dev-stack.tsv" > "$T/keys.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("\n".join(sorted(m.guide_key(e["kind"], e["ref"]) for e in m.load(sys.argv[2]))))
PYEOF
check "catalog keys: devstack.js refKey == release_mirror.py guide_key for every row" '[ -s "$T/keys.js" ] && LC_ALL=C sort "$T/keys.js" | cmp -s - <(LC_ALL=C sort "$T/keys.py")'

# --- fixture tree ------------------------------------------------------------------------
C="$D/cloud/caddyserver/caddy"
mkdir -p "$C/v2.0.0" "$C/v1.10.0" "$C/v1.9.0" "$D/containers/download.docker.com/linux/static/stable/aarch64" \
         "$D/toolchains/go/go1.30.1" "$D/python/pypi/demo/1.0" "$D/python/pypi/other/2.0" "$D/storage/restic/restic" "$D/cloud/juanfont"
for f in caddy_2.0.0_linux_amd64.tar.gz caddy_2.0.0_linux_arm64.tar.gz caddy_2.0.0_mac_arm64.tar.gz caddy_2.0.0_windows_amd64.zip \
         caddy-v2.0.0-source.tar.gz caddy_2.0.0_checksums.txt; do printf '%s' "$f payload" > "$C/v2.0.0/$f"; done
head -c 3000 /dev/urandom > "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"
: > "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz.verified"; : > "$C/v2.0.0/half.zip.part"; echo guide > "$C/v2.0.0/INSTALL.txt"; : > "$C/v2.0.0/.hidden"
echo old > "$C/v1.10.0/caddy_1.10.0_linux_amd64.tar.gz"; echo older > "$C/v1.9.0/caddy_1.9.0_linux_amd64.tar.gz"
echo outside-the-tree-7f3a > "$T/outside/secret.txt"
mkdir -p "$T/outside/v9.0.0"; echo outside-the-tree-7f3a > "$T/outside/v9.0.0/headscale_9.0.0_linux_amd64"
ln -s "$T/outside/secret.txt" "$C/v2.0.0/caddy_2.0.0_linux_leak.tar.gz"     # a file symlink out of the tree
ln -s "$T/outside" "$D/cloud/juanfont/headscale"                              # a project dir symlink out of the tree
echo engine > "$D/containers/download.docker.com/linux/static/stable/aarch64/docker-29.1.0.tgz"
echo extras > "$D/containers/download.docker.com/linux/static/stable/aarch64/docker-rootless-extras-29.1.0.tgz"
echo go > "$D/toolchains/go/go1.30.1/go1.30.1.linux-amd64.tar.gz"; echo src > "$D/toolchains/go/go1.30.1/go1.30.1.src.tar.gz"
echo whl > "$D/python/pypi/demo/1.0/demo-1.0-py3-none-any.whl"

# --- server ------------------------------------------------------------------------------
gcode() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }
start() {   # $1 = state dir, $2 = extra env assignment (or empty)
    stop_pids "$SRV_PID"; SRV_PID=""
    PORT=$(free_port); B="http://127.0.0.1:$PORT"
    env $2 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
      VALARK_STATE_DIR="$1" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" VALARK_DEVSTACK_DIR="$D" \
      "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
    SRV_PID=$!
    local i; for i in $(seq 1 24); do sleep 0.5; curl -s -o /dev/null --max-time 2 "$B/api/health" && return 0; done
    return 1
}
if ! start "$T/state" ""; then fail "server did not start"; echo "devstack-ui: ${PASS} passed, ${FAIL} failed"; exit 1; fi

# --- 2. the listing ----------------------------------------------------------------------
curl -s --max-time 10 "$B/api/devstack" > "$T/ds.json"
"$NODE" - "$T/ds.json" > "$T/list.out" 2>&1 <<'JSEOF'
const d = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8')), bad = [];
const by = (key) => d.projects.find((p) => p.key === key) || {};
if (d.projects.length < 200 || !d.groups.includes('cloud') || !d.groups.includes('storage')) bad.push('every catalog row + the groups');
const c = by('caddyserver__caddy');
if (!(c.mirrored && c.guide && c.group === 'cloud' && c.name === 'caddy' && c.note === 'Caddy web server' && c.ref === 'caddyserver/caddy')) bad.push('caddy: row fields');
if ((c.versions || []).map((v) => v.version).join() !== 'v2.0.0,v1.10.0,v1.9.0' || c.versionsHeld !== 3) bad.push('caddy: versions newest first');
const names = ((c.versions || [])[0] || { files: [] }).files.map((f) => f.name);
if (names.join() !== 'caddy-v2.0.0-source.tar.gz,caddy_2.0.0_checksums.txt,caddy_2.0.0_linux_amd64.tar.gz,caddy_2.0.0_linux_arm64.tar.gz,caddy_2.0.0_mac_arm64.tar.gz,caddy_2.0.0_windows_amd64.zip')
  bad.push('caddy: files (sidecars, INSTALL.txt, dotfiles and symlinks hidden): ' + names.join());
const amd = c.versions[0].files.find((f) => f.name === 'caddy_2.0.0_linux_amd64.tar.gz') || {};
if (amd.size !== 3000 || amd.platform !== 'linux-x86_64' || amd.url !== '/api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz') bad.push('caddy: file size / platform / url');
if ((c.platforms || []).join() !== 'linux-x86_64,linux-arm64,macos-arm64,windows-x64,source') bad.push('caddy: platforms ' + c.platforms);
if (!(c.bytes > 3000) || c.versions[0].bytes < 3000) bad.push('caddy: bytes');
const dk = by('index__download.docker.com__linux__static__stable__aarch64');
if (!(dk.mirrored && dk.versions.length === 1 && dk.versions[0].version === '29.1.0' && dk.versions[0].files.length === 2 && dk.platforms.join() === 'linux-arm64' && dk.guide)) bad.push('docker (index layout): ' + JSON.stringify(dk));
if (by('index__download.docker.com__linux__static__stable__x86_64').mirrored !== false) bad.push('docker x86_64 is not mirrored here');
const go = by('go');
if (!(go.mirrored && go.name === 'Go' && go.versions[0].version === 'go1.30.1' && go.platforms.join() === 'linux-x86_64,source')) bad.push('go layout');
const top = d.projects.find((p) => p.kind === 'pypi-top') || {};
if (!(top.mirrored && top.packages === 2 && top.versions.length === 0)) bad.push('pypi-top is counted, not listed');
const r = by('restic__restic');
if (!(r.mirrored === false && r.versions.length === 0 && r.platforms.length === 0 && r.bytes === 0 && r.guide)) bad.push('restic: an empty project dir is "not mirrored"');
const h = by('juanfont__headscale');
if (h.mirrored !== false) bad.push('a project dir symlinked out of the tree must not be listed');
if (by('astral-sh__uv').guide !== false) bad.push('a project without a guide says so');
if (/secret\.txt|headscale_9|linux_leak/.test(JSON.stringify(d))) bad.push('the listing leaked a file outside the tree');
console.log(bad.length ? bad.join('\n') : 'ok');
JSEOF
check "GET /api/devstack: rows joined with the tree" 'grep -qx ok "$T/list.out"' || cat "$T/list.out" >&2
sleep 0.3
for i in $(seq 1 20); do curl -s --max-time 5 "$B/api/status/storage" > "$T/storage.json"; grep -q '"key":"devstack"' "$T/storage.json" && break; sleep 0.5; done
check "the storage breakdown counts the dev-stack tree" 'grep -q "\"key\":\"devstack\",\"label\":\"Developer Stack\"" "$T/storage.json"'

# --- 3. guides: catalog keys only --------------------------------------------------------
curl -s --max-time 8 "$B/api/devstack/guide?ref=caddyserver__caddy" > "$T/guide.json"
check "guide: a catalog key with a guide -> its text" 'grep -q "\"key\":\"caddyserver__caddy\"" "$T/guide.json" && grep -q "tls internal" "$T/guide.json"'
curl -s --max-time 8 "$B/api/devstack/guide?ref=index__download.docker.com__linux__static__stable__aarch64" > "$T/guide2.json"
check "guide: 'see:' resolves to the shared guide" 'grep -q "dockerd" "$T/guide2.json"'
for ref in "" nope astral-sh__uv caddyserver/caddy ../caddyserver__caddy caddyserver__caddy/../go ..%2Fcaddyserver__caddy \
           ../../../../etc/passwd %2e%2e%2f%2e%2e%2fetc%2fpasswd /etc/passwd caddyserver__caddy.md caddyserver__caddy%00 "see:%20go"; do
    c=$(gcode --path-as-is "$B/api/devstack/guide?ref=$ref"); [ "$c" = "404" ] && pass || fail "guide ref '$ref' must be 404 (got $c)"
done
check "guide: a refused ref never echoes a file" '! curl -s --path-as-is "$B/api/devstack/guide?ref=../../../../etc/passwd" | grep -q "root:"'

# --- 4. downloads through /api/archive ---------------------------------------------------
U="$B/api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0"
curl -s --max-time 8 -o "$T/dl.bin" "$U/caddy_2.0.0_linux_amd64.tar.gz"
check "download: the file, byte for byte" 'cmp -s "$T/dl.bin" "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"'
check "download: sent as an attachment" 'curl -s -D - -o /dev/null "$U/caddy_2.0.0_linux_amd64.tar.gz" | tr -d "\r" | grep -qi "^content-disposition: attachment; filename=\"caddy_2.0.0_linux_amd64.tar.gz\""'
c=$(gcode -I "$U/caddy_2.0.0_linux_amd64.tar.gz"); [ "$c" = "200" ] && pass || fail "HEAD on a dev-stack file must be 200 (got $c)"
for p in cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_leak.tar.gz cloud/juanfont/headscale/secret.txt cloud/juanfont/headscale/v9.0.0/headscale_9.0.0_linux_amd64 cloud/caddyserver/caddy/v9/none.zip \
         ../outside/secret.txt cloud/../../outside/secret.txt %2e%2e/outside/secret.txt ..%2Foutside%2Fsecret.txt; do
    c=$(gcode --path-as-is "$B/api/archive/dev-stack/$p"); { [ "$c" = "404" ] || [ "$c" = "400" ] || [ "$c" = "403" ]; } && pass || fail "archive dev-stack/$p must be refused (got $c)"
    curl -s --path-as-is --max-time 5 "$B/api/archive/dev-stack/$p" | grep -q outside-the-tree-7f3a && fail "archive dev-stack/$p leaked a file outside the tree" || pass
done
c=$(gcode "$B/api/archive/private/x"); [ "$c" = "404" ] && pass || fail "an unlisted archive dir stays 404 (got $c)"
c=$(gcode "$B/api/archive/constructor/x"); [ "$c" = "404" ] && pass || fail "an object-prototype name is not an archive dir (got $c)"

# --- 5. read wall + public peer ----------------------------------------------------------
READS=(api/devstack "api/devstack/guide?ref=caddyserver__caddy" api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz)
mkdir -p "$T/pw" "$T/open"
"$NODE" -e 'const a=require(process.argv[1]);a.setPassword("testpass","admin",process.argv[2]);a.setUseMode("passworded",process.argv[2]);a.setPassword("testpass","admin",process.argv[3]);a.setUseMode("open",process.argv[3]);' \
    "$ROOT/scripts/lib/auth.js" "$T/pw" "$T/open"
if start "$T/pw" VALARK_TEST_FORCE_REMOTE=1; then
    for p in "${READS[@]}"; do c=$(gcode "$B/$p"); [ "$c" = "401" ] && pass || fail "Passworded: un-authed LAN read of /$p must be 401 (got $c)"; done
    curl -s -c "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"password":"testpass"}' "$B/api/auth/login" >/dev/null
    for p in "${READS[@]}"; do c=$(gcode -b "$T/cj" "$B/$p"); [ "$c" = "200" ] && pass || fail "Passworded: a signed-in read of /$p must be 200 (got $c)"; done
else fail "passworded server did not start"; fi
if start "$T/open" VALARK_TEST_FORCE_PUBLIC=1; then
    for p in "${READS[@]}"; do c=$(gcode "$B/$p"); [ "$c" = "403" ] && pass || fail "Open mode: a public peer reading /$p must be 403 (got $c)"; done
    c=$(gcode "$B/api/health"); [ "$c" = "200" ] && pass || fail "the shell stays reachable for a public peer (got $c)"
else fail "open-mode server (public peer) did not start"; fi
if start "$T/open" VALARK_TEST_FORCE_REMOTE=1; then
    for p in "${READS[@]}"; do c=$(gcode "$B/$p"); [ "$c" = "200" ] && pass || fail "Open mode: a LAN read of /$p must be 200 (got $c)"; done
else fail "open-mode server (LAN peer) did not start"; fi
stop_pids "$SRV_PID"; SRV_PID=""

# --- 6. verify.sh verify_devstack (stub programs in fixture archives) --------------------
V="$T/vds"; W="$T/work"; mkdir -p "$W" "$T/vtmp" "$T/vhome" "$T/vstate"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
# PASS from a tar.gz member; the stub also proves HOME is the temp dir and stdin is closed
mkdir -p "$V/cloud/caddyserver/caddy/v2.0.0" "$V/cloud/caddyserver/caddy/v1.0.0" "$W/caddy"
stub "$W/caddy/caddy" '[ "$1" = version ] || exit 9; touch "$HOME/ran-here"; read -r x && exit 8; echo "v2.0.0 h1:stub"'
tar -czf "$V/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" -C "$W/caddy" caddy
echo junk > "$V/cloud/caddyserver/caddy/v1.0.0/caddy_1.0.0_linux_amd64.tar.gz"      # an older version is never the one run
# PASS from a wildcard member (prometheus-*/prometheus) and from a bare program (headscale)
mkdir -p "$V/cloud/prometheus/prometheus/v3.0.0" "$W/prom/prometheus-3.0.0.linux-amd64" "$V/cloud/juanfont/headscale/v0.29.8"
stub "$W/prom/prometheus-3.0.0.linux-amd64/prometheus" 'echo "prometheus, version 3.0.0 (stub)" >&2'
echo conf > "$W/prom/prometheus-3.0.0.linux-amd64/prometheus.yml"
tar -czf "$V/cloud/prometheus/prometheus/v3.0.0/prometheus-3.0.0.linux-amd64.tar.gz" -C "$W/prom" prometheus-3.0.0.linux-amd64
stub "$V/cloud/juanfont/headscale/v0.29.8/headscale_0.29.8_linux_amd64" 'echo "headscale version 0.29.8"'
chmod -x "$V/cloud/juanfont/headscale/v0.29.8/headscale_0.29.8_linux_amd64"
# PASS from a .bz2 program (restic) and from a zip (ninja)
mkdir -p "$V/storage/restic/restic/v0.20.0" "$V/toolchains/ninja-build/ninja/v1.13.2" "$W/ninja"
stub "$W/restic" 'echo "restic 0.20.0 compiled with stub"'; bzip2 -c "$W/restic" > "$V/storage/restic/restic/v0.20.0/restic_0.20.0_linux_amd64.bz2"
stub "$W/ninja/ninja" 'echo 1.13.2'
python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); i = zipfile.ZipInfo("ninja"); i.external_attr = 0o755 << 16; z.writestr(i, open(sys.argv[2]).read()); z.close()' \
    "$V/toolchains/ninja-build/ninja/v1.13.2/ninja-linux.zip" "$W/ninja/ninja"
# FAIL: wrong output (rclone), a non-zero exit (age)
mkdir -p "$V/storage/rclone/rclone/v1.76.0" "$W/rc/rclone-v1.76.0-linux-amd64" "$V/cloud/FiloSottile/age/v1.3.2" "$W/age/age"
stub "$W/rc/rclone-v1.76.0-linux-amd64/rclone" 'echo "Segmentation fault"'
( cd "$W/rc" && python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.write("rclone-v1.76.0-linux-amd64/rclone"); z.close()' "$V/storage/rclone/rclone/v1.76.0/rclone-v1.76.0-linux-amd64.zip" )
stub "$W/age/age/age" 'echo "v1.3.2"; exit 3'
tar -czf "$V/cloud/FiloSottile/age/v1.3.2/age-v1.3.2-linux-amd64.tar.gz" -C "$W/age" age
# SKIP: mirrored, but only for another platform (duckdb); an archive that cannot be unpacked (cmake)
mkdir -p "$V/databases/duckdb/duckdb/v2.0.1" "$V/toolchains/Kitware/CMake/v4.5.1"
echo arm > "$V/databases/duckdb/duckdb/v2.0.1/duckdb-cli-linux-arm64.tar.gz"
echo "not a tarball" > "$V/toolchains/Kitware/CMake/v4.5.1/cmake-4.5.1-linux-x86_64.tar.gz"
# a KeePassXC AppImage is mirrored but has no check row: it must not be run or reported
mkdir -p "$V/dev-tools/keepassxreboot/keepassxc/2.8.0"
stub "$V/dev-tools/keepassxreboot/keepassxc/2.8.0/KeePassXC-2.8.0-x86_64.AppImage" 'touch "'"$T"'/gui-was-run"'

H="$T/verify-harness.sh"
{ sed -e 's|^_LIB=.*|_LIB="'"$ROOT"'/scripts/lib"|' -e '/^case "\${1:-all}" in/,$d' "$ROOT/scripts/verify.sh"   # the harness is not in scripts/
  echo 'verify_devstack "$1"; echo "rc=$?"; write_report'; } > "$H"
grep -q '^verify_devstack() {' "$H" && grep -q '^write_report() {' "$H" && pass || fail "harness must hold the real verify_devstack + write_report"
vrun() { ( cd "$T" && env HOME="$T/vhome" PATH="$(dirname "$NODE"):$PATH" TMPDIR="$T/vtmp" VAL_ARK_DATA="$T/vdata" VALARK_STATE_DIR="$T/vstate" \
             VALARK_DEVSTACK_DIR="$1" bash "$H" "$2" ) > "$T/v.out" 2>&1; }
vrun "$V" linux-x86_64
J="$T/vstate/verify.json"
has() { grep -F -- "$1" "$J" | grep -qF -- "$2"; }
check "verify_devstack returns 0 with failures present (it never stops the loop)" 'grep -qx "rc=0" "$T/v.out"' || cat "$T/v.out" >&2
check "verify.json is valid JSON" 'python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$J"'
check "PASS: tar.gz member (newest version)" 'has "\"status\": \"PASS\", \"comp\": \"apps\"" "tool runs: dev-stack caddy (caddy_2.0.0_linux_amd64.tar.gz)"'
check "PASS: wildcard member, output on stderr" 'has "\"status\": \"PASS\"" "tool runs: dev-stack prometheus ("'
check "PASS: bare program without its exec bit" 'has "\"status\": \"PASS\"" "tool runs: dev-stack headscale ("'
check "PASS: .bz2 program" 'has "\"status\": \"PASS\"" "tool runs: dev-stack restic ("'
if command -v unzip >/dev/null 2>&1; then
    check "PASS: zip member" 'has "\"status\": \"PASS\"" "tool runs: dev-stack ninja ("'
    check "FAIL: output does not match" 'has "\"status\": \"FAIL\", \"comp\": \"apps\"" "dev-stack rclone (rclone-v1.76.0-linux-amd64.zip: Segmentation fault)"'
else
    check "no unzip: zip projects are SKIPped, not failed" 'has "\"status\": \"SKIP\"" "dev-stack ninja could not be unpacked" && has "\"status\": \"SKIP\"" "dev-stack rclone could not be unpacked"'
fi
check "FAIL: non-zero exit even when the output matches" 'has "\"status\": \"FAIL\"" "tool present but won'"'"'t run: dev-stack age ("'
check "SKIP: mirrored, no build for this platform" 'has "\"status\": \"SKIP\", \"comp\": \"apps\"" "dev-stack duckdb has no linux-x86_64 build to run"'
check "SKIP: an archive that cannot be unpacked" 'has "\"status\": \"SKIP\"" "dev-stack CMake could not be unpacked to run"'
check "projects not mirrored, and projects without a check row, are not reported" '! grep -q "dev-stack \(croc\|gitea\|Go\|keepassxc\)" "$J" && [ ! -e "$T/gui-was-run" ]'
check "the counts add up" 'python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1])); c = [x[\"status\"] for x in d[\"checks\"]]
sys.exit(0 if (d[\"pass\"], d[\"fail\"], d[\"skip\"]) == (c.count(\"PASS\"), c.count(\"FAIL\"), c.count(\"SKIP\")) and d[\"fail\"] >= 1 and d[\"skip\"] >= 2 else 1)" "$J"'
check "programs ran with HOME in the temp dir; nothing left in TMPDIR or the real HOME dir" '[ ! -e "$T/vhome/ran-here" ] && [ -z "$(ls -A "$T/vtmp")" ]'
check "nothing was installed: the tree is untouched" '[ ! -x "$V/cloud/juanfont/headscale/v0.29.8/headscale_0.29.8_linux_amd64" ] && [ -z "$(find "$V" -newer "$H" -type f)" ]'
# the other platform: duckdb's arm64 file is now the one tried (junk -> could not be unpacked), caddy has no arm64 build
vrun "$V" linux-arm64
check "platform choice follows the argument" 'has "\"status\": \"SKIP\"" "dev-stack caddy has no linux-arm64 build to run" && has "\"status\": \"SKIP\"" "dev-stack duckdb could not be unpacked"'
# no tree at all: silent, no node needed
rm -f "$J"; vrun "$T/nowhere" linux-x86_64
check "no dev-stack tree: nothing to check, nothing reported" 'grep -qx "rc=0" "$T/v.out" && grep -q "\"pass\": 0, \"fail\": 0, \"skip\": 0" "$J"'
check "verify_local calls verify_devstack with the host platform" 'grep -q "verify_devstack \"\${td##\*/}\"" "$ROOT/scripts/verify.sh"'

# --- no server left behind ---------------------------------------------------------------
check "every server this test started is stopped" '! pgrep -f "server.js $PORT\$" >/dev/null 2>&1 && [ -z "$SRV_PID" ]'

echo "devstack-ui: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
