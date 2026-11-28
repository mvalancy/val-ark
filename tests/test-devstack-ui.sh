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
#   4. /api/archive/dev-stack/...: file download, Range (206 / 416), HEAD, containment,
#      a control character in the path, and the per-client cap on directory tar streams.
#   5. The read wall (401 unauthed in Passworded mode, 200 with a session) and the
#      public-peer 403 cover the listing, the guide and the downloads.
#   6. verify.sh verify_devstack: PASS / FAIL / SKIP per project from stub programs
#      inside fixture archives, written to state/verify.json; nothing left behind. Also:
#      control characters in a program's output, a program that ignores TERM, the newest
#      version of an index row, the PASS cache, plain-file-only unpacking, the size cap,
#      the clean environment, no network, a killed run, and a host without timeout(1).
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
  'cmake-4.5.1.tar.gz': 'source', 'gcc-15.1.0.tar.xz': 'source', 'nmap-7.98.tar.bz2': 'source', 'cmake-4.5.1.tar.gz.sha256': '', 'notes-1.0.zip': '',
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
# safe(): the same path component in both languages, long names (hashed) and non-ASCII included
LONG="$(printf 'a%.0s' $(seq 1 200))-ü-😀.tar.gz"
"$NODE" -e 'const d=require(process.argv[1]);for(const n of process.argv.slice(2))console.log(d.safe(n))' "$ROOT/scripts/lib/devstack.js" "$LONG" "..weird name?.zip" "---" > "$T/safe.js"
python3 -I - "$ROOT/scripts/lib/release_mirror.py" "$LONG" "..weird name?.zip" "---" > "$T/safe.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for n in sys.argv[2:]: print(m.safe(n))
PYEOF
check "safe(): devstack.js == release_mirror.py, long names hashed alike" '[ "$(wc -l < "$T/safe.js")" -eq 3 ] && cmp -s "$T/safe.js" "$T/safe.py" && [ "$(head -1 "$T/safe.js" | wc -c)" -le 181 ]' || { cat "$T/safe.js" "$T/safe.py" >&2; }

# guide(): only catalog keys are ever read, and a "see:" may only name another catalog key
mkdir -p "$T/gd"; printf 'see: b__b\n' > "$T/gd/a__a.md"; printf '# B\n' > "$T/gd/b__b.md"; printf 'see: ../gd/b__b\n' > "$T/gd/c__c.md"
"$NODE" -e '
const d = require(process.argv[1]), g = process.argv[2], bad = [];
(async () => {
  if (await d.guide(g, "a__a", new Set(["a__a", "b__b"])) !== "# B\n") bad.push("see: to a catalog key resolves");
  if (await d.guide(g, "a__a", new Set(["a__a"])) !== null) bad.push("see: to a name that is not a catalog key must give nothing");
  if (await d.guide(g, "b__b", new Set(["a__a"])) !== null) bad.push("a key outside the allowlist must give nothing");
  if (await d.guide(g, "c__c", new Set(["a__a", "b__b", "c__c"])) !== null) bad.push("see: with a path must give nothing");
  console.log(bad.length ? bad.join("\n") : "ok");
})();' "$ROOT/scripts/lib/devstack.js" "$T/gd" > "$T/guide-unit.out" 2>&1
check "guide(): the allowlist holds for the key and for a 'see:' target" 'grep -qx ok "$T/guide-unit.out"' || cat "$T/guide-unit.out" >&2

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
( cd "$D/python/pypi" && mkdir $(seq -f 'pkg%g' 1 520) )                      # more folders than one capped read holds
: > "$C/v2.0.0/INSTALL.txt.tmp"; : > "$C/v2.0.0/big.iso.oversize-123"; : > "$C/v2.0.0/x.tmp-7"
# an index folder keeps old releases beside the new one: only the newest version is listed
echo old-engine > "$D/containers/download.docker.com/linux/static/stable/aarch64/docker-28.9.9.tgz"
echo old-extras > "$D/containers/download.docker.com/linux/static/stable/aarch64/docker-rootless-extras-28.9.9.tgz"
echo sums > "$D/containers/download.docker.com/linux/static/stable/aarch64/SHA256SUMS"
printf 'x' > "$C/v2.0.0/$(printf 'new\nline.zip')"                            # a control character in a file name
mkdir -p "$D/cloud/quo\"te\\dir" "$D/cloud/目录"                              # a quote + a backslash; non-Latin-1 names
echo quoted > "$D/cloud/quo\"te\\dir/f.txt"; echo unicode-folder > "$D/cloud/目录/a.txt"; echo unicode-file > "$D/cloud/文件.txt"
mkdir -p "$D/os-images/big"; head -c 80000000 /dev/urandom > "$D/os-images/big/blob.bin"   # more than loopback TCP buffers hold

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
  bad.push('caddy: files (sidecars, .tmp / .oversize leftovers, INSTALL.txt, dotfiles and symlinks hidden): ' + JSON.stringify(names));
const amd = c.versions[0].files.find((f) => f.name === 'caddy_2.0.0_linux_amd64.tar.gz') || {};
if (amd.size !== 3000 || amd.platform !== 'linux-x86_64' || amd.url !== '/api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz') bad.push('caddy: file size / platform / url');
if ((c.platforms || []).join() !== 'linux-x86_64,linux-arm64,macos-arm64,windows-x64,source') bad.push('caddy: platforms ' + c.platforms);
if (!(c.bytes > 3000) || c.versions[0].bytes < 3000) bad.push('caddy: bytes');
const dk = by('index__download.docker.com__linux__static__stable__aarch64');
if (!(dk.mirrored && dk.versions.length === 1 && dk.versions[0].version === '29.1.0' && dk.platforms.join() === 'linux-arm64' && dk.guide)) bad.push('docker (index layout): ' + JSON.stringify(dk));
if (((dk.versions || [])[0] || { files: [] }).files.map((f) => f.name).join() !== 'SHA256SUMS,docker-29.1.0.tgz,docker-rootless-extras-29.1.0.tgz') bad.push('docker: only the newest version of an index folder (and its checksum list) is listed');
if (by('index__download.docker.com__linux__static__stable__x86_64').mirrored !== false) bad.push('docker x86_64 is not mirrored here');
const go = by('go');
if (!(go.mirrored && go.name === 'Go' && go.versions[0].version === 'go1.30.1' && go.platforms.join() === 'linux-x86_64,source')) bad.push('go layout');
const top = d.projects.find((p) => p.kind === 'pypi-top') || {};
if (!(top.mirrored && top.packages === 522 && top.versions.length === 0)) bad.push('pypi-top is counted in full, not listed: ' + top.packages);
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
# Range: a dropped download resumes (curl -C -), and a range past the end is refused
check "HEAD says the size and that ranges work" 'curl -s -I --max-time 8 "$U/caddy_2.0.0_linux_amd64.tar.gz" | tr -d "\r" | grep -qi "^content-length: 3000$" && curl -s -I "$U/caddy_2.0.0_linux_amd64.tar.gz" | grep -qi "^accept-ranges: bytes"'
c=$(curl -s -o "$T/r.bin" -w '%{http_code}' --max-time 8 -r 10-19 "$U/caddy_2.0.0_linux_amd64.tar.gz")
check "Range: 206 with exactly the bytes asked for" '[ "$c" = 206 ] && [ "$(wc -c < "$T/r.bin")" -eq 10 ] && cmp -s "$T/r.bin" <(tail -c +11 "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" | head -c 10)'
check "Range: Content-Range names the slice and the whole" 'curl -s -D - -o /dev/null -r 2990- "$U/caddy_2.0.0_linux_amd64.tar.gz" | tr -d "\r" | grep -qi "^content-range: bytes 2990-2999/3000$"'
head -c 1000 "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" > "$T/resume.bin"; curl -s --max-time 8 -C - -o "$T/resume.bin" "$U/caddy_2.0.0_linux_amd64.tar.gz"
check "Range: an interrupted download resumes to the same bytes" 'cmp -s "$T/resume.bin" "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"'
# validators: a resume is only spliced onto the file it started from (If-Range)
curl -s -D "$T/h.txt" -o /dev/null --max-time 8 "$U/caddy_2.0.0_linux_amd64.tar.gz"
ETAG="$(tr -d '\r' < "$T/h.txt" | sed -n 's/^[Ee][Tt]ag: //p')"; LM="$(tr -d '\r' < "$T/h.txt" | sed -n 's/^[Ll]ast-[Mm]odified: //p')"
check "a file download carries a weak ETag and Last-Modified" '[[ "$ETAG" == W/\"*\" ]] && [ -n "$LM" ]'
c=$(curl -s -o "$T/ir.bin" -w '%{http_code}' --max-time 8 -r 10-19 -H "If-Range: $ETAG" "$U/caddy_2.0.0_linux_amd64.tar.gz")
check "If-Range with the current ETag: the range is honoured (206)" '[ "$c" = 206 ] && [ "$(wc -c < "$T/ir.bin")" -eq 10 ]'
c=$(curl -s -o "$T/ir.bin" -w '%{http_code}' --max-time 8 -r 10-19 -H "If-Range: $LM" "$U/caddy_2.0.0_linux_amd64.tar.gz")
check "If-Range with the current Last-Modified date: 206" '[ "$c" = 206 ] && [ "$(wc -c < "$T/ir.bin")" -eq 10 ]'
c=$(curl -s -o "$T/ir.bin" -w '%{http_code}' --max-time 8 -r 10-19 -H 'If-Range: W/"dead-beef"' "$U/caddy_2.0.0_linux_amd64.tar.gz")
check "If-Range with another ETag: the whole file (200), not a slice" '[ "$c" = 200 ] && cmp -s "$T/ir.bin" "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"'
cp "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" "$T/orig.bin"; head -c 3000 /dev/urandom > "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"; touch -d '2031-01-01' "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"
c=$(curl -s -o "$T/ir.bin" -w '%{http_code}' --max-time 8 -r 1000- -H "If-Range: $ETAG" "$U/caddy_2.0.0_linux_amd64.tar.gz")
check "a replaced file (same size): a resume with the old ETag restarts with the new file" '[ "$c" = 200 ] && cmp -s "$T/ir.bin" "$C/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" && ! cmp -s "$T/ir.bin" "$T/orig.bin"'
c=$(gcode "$B/styles.css"); curl -s -D "$T/hs.txt" -o /dev/null "$B/styles.css"
check "static files keep their headers (type, cache, ranges) and gain the validators" '[ "$c" = 200 ] && tr -d "\r" < "$T/hs.txt" | grep -qi "^content-type: text/css" && grep -qi "^cache-control: no-cache" "$T/hs.txt" && grep -qi "^accept-ranges: bytes" "$T/hs.txt" && grep -qi "^etag: W/" "$T/hs.txt"'
# names a header cannot carry as they are: an ASCII stand-in plus filename*=UTF-8''...
curl -s -D "$T/hu.txt" -o "$T/u.bin" --max-time 6 "$B/api/archive/dev-stack/cloud/%E6%96%87%E4%BB%B6.txt"
check "a non-Latin-1 file name downloads (it used to throw in the header and hang)" '[ "$(cat "$T/u.bin")" = unicode-file ] && tr -d "\r" < "$T/hu.txt" | grep -qi "^content-disposition: attachment; filename=\"__.txt\"; filename\*=UTF-8'"''"'%E6%96%87%E4%BB%B6.txt$"'
curl -s --max-time 10 "$B/api/archive/dev-stack/cloud/%E7%9B%AE%E5%BD%95" | tar -tzf - > "$T/tar-u.list" 2>/dev/null
check "a non-Latin-1 folder name downloads as a tar.gz with its files" 'grep -q "/a.txt$" "$T/tar-u.list"'
curl -s --max-time 10 "$B/api/archive/dev-stack/cloud/quo%22te%5Cdir" | tar -xzOf - > "$T/tar-q.out" 2>/dev/null
check "a folder with a quote and a backslash in its name still has its files in the tar" 'grep -qx quoted "$T/tar-q.out"'
check "...and its header holds a safe stand-in name" 'curl -s -D - -o /dev/null --max-time 10 "$B/api/archive/dev-stack/cloud/quo%22te%5Cdir" | tr -d "\r" | grep -qi "^content-disposition: attachment; filename=\"quo_te_dir.tar.gz\"; filename\*=UTF-8'"''"'quo%22te%5Cdir.tar.gz$"'
c=$(gcode -r 5000- "$U/caddy_2.0.0_linux_amd64.tar.gz"); [ "$c" = "416" ] && pass || fail "a range past the end must be 416 (got $c)"
# a control character in the path: a clean 404 at once (it used to throw in the header and hang)
for p in "cloud/caddyserver/caddy/v2.0.0/new%0Aline.zip" "cloud/a%0Db" "cloud/caddyserver/caddy/v2.0.0/x%1F"; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$B/api/archive/dev-stack/$p"); [ "$c" = "404" ] && pass || fail "archive dev-stack/$p must be a prompt 404 (got $c)"
done
c=$(gcode "$B/api/health"); [ "$c" = "200" ] && pass || fail "the server still answers after those requests (got $c)"
# a folder streams as a .tar.gz; one client cannot hold more than its share of tar streams
curl -s --max-time 20 "$B/api/archive/dev-stack/cloud/caddyserver/caddy/v1.9.0" | tar -tzf - > "$T/tar.list" 2>/dev/null
check "a version folder downloads as a tar.gz stream" 'grep -qx "v1.9.0/caddy_1.9.0_linux_amd64.tar.gz" "$T/tar.list"'
if start "$T/state" "VALARK_MAX_ARCHIVE_TAR=5 VALARK_MAX_ARCHIVE_TAR_PER_IP=1"; then
    curl -s -o /dev/null --limit-rate 200k --max-time 30 "$B/api/archive/dev-stack/os-images/big" & SLOW_PID=$!
    sleep 1.5
    R="$(curl -s -i --max-time 6 "$B/api/archive/dev-stack/cloud/caddyserver/caddy/v1.9.0")"
    echo "$R" | grep -qE '^HTTP/[0-9.]+ 503' && pass || fail "a second tar stream from the same client must be 503 while the first runs (got: $(echo "$R" | head -1))"
    echo "$R" | grep -qi '^Retry-After:' && pass || fail "the tar 503 must carry Retry-After"
    c=$(gcode "$B/api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"); [ "$c" = "200" ] && pass || fail "single files stay downloadable meanwhile (got $c)"
    kill "$SLOW_PID" 2>/dev/null; wait "$SLOW_PID" 2>/dev/null
    c=503; for i in $(seq 1 20); do c=$(gcode "$B/api/archive/dev-stack/cloud/caddyserver/caddy/v1.9.0"); [ "$c" = 200 ] && break; sleep 0.3; done
    [ "$c" = "200" ] && pass || fail "the slot is free again once the first stream ends (got $c)"
    # with one slot per client, a request that failed to release it would lock the next one out
    for i in 1 2 3; do
        c=$(curl -s -o "$T/slot.tgz" -w '%{http_code}' --max-time 10 "$B/api/archive/dev-stack/cloud/%E7%9B%AE%E5%BD%95")
        [ "$c" = 200 ] && tar -tzf "$T/slot.tgz" 2>/dev/null | grep -q "/a.txt$" && pass || fail "non-Latin-1 folder download #$i must succeed and free its tar slot (got $c)"
    done
    c=$(gcode "$B/api/archive/dev-stack/cloud/quo%22te%5Cdir"); [ "$c" = "200" ] && pass || fail "the tar slot count is back to zero afterwards (got $c)"
else fail "server (tar caps) did not start"; fi
if start "$T/state" "VALARK_MAX_ARCHIVE_TAR=-3 VALARK_MAX_ARCHIVE_TAR_PER_IP=0"; then
    c=$(gcode "$B/api/archive/dev-stack/cloud/caddyserver/caddy/v1.9.0"); [ "$c" = "200" ] && pass || fail "a zero or negative tar cap is clamped to 1, not 'no downloads' (got $c)"
else fail "server (clamped tar caps) did not start"; fi
rm -rf "$D/os-images/big"
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
stub "$W/caddy/caddy" '[ "$#" = 1 ] && [ "$1" = version ] || exit 9; touch "$HOME/ran-here"; read -r x && exit 8
echo run >> "'"$T"'/runs-caddy"; env > "'"$T"'/env-caddy"; tail -n +3 /proc/net/dev 2>/dev/null | grep -vc "^ *lo:" > "'"$T"'/net-caddy"
echo "v2.0.0 h1:stub"'
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
# FAIL: wrong output (rclone), a non-zero exit with control characters in the output (age),
# a program that ignores TERM (croc), the NEWEST docker in an index folder that holds two
mkdir -p "$V/storage/rclone/rclone/v1.76.0" "$W/rc/rclone-v1.76.0-linux-amd64" "$V/cloud/FiloSottile/age/v1.3.2" "$W/age/age"
stub "$W/rc/rclone-v1.76.0-linux-amd64/rclone" 'echo "Segmentation fault"'
( cd "$W/rc" && python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.write("rclone-v1.76.0-linux-amd64/rclone"); z.close()' "$V/storage/rclone/rclone/v1.76.0/rclone-v1.76.0-linux-amd64.zip" )
stub "$W/age/age/age" 'printf "\001\033[31mv1.3.2 \"boom\" \\\\ \033[0m\n"; echo run >> "'"$T"'/runs-age"; exit 3'
tar -czf "$V/cloud/FiloSottile/age/v1.3.2/age-v1.3.2-linux-amd64.tar.gz" -C "$W/age" age
mkdir -p "$V/storage/schollz/croc/v11.0.0" "$W/croc"
stub "$W/croc/croc" 'trap "" TERM; echo "croc version v11.0.0"; while :; do sleep 1; done'
tar -czf "$V/storage/schollz/croc/v11.0.0/croc_v11.0.0_Linux-64bit.tar.gz" -C "$W/croc" croc
DX="$V/containers/download.docker.com/linux/static/stable/x86_64"; mkdir -p "$DX" "$W/d28/docker" "$W/d29/docker"
stub "$W/d28/docker/docker" 'echo "Docker version 28.0.0, build stub"'; tar -czf "$DX/docker-28.0.0.tgz" -C "$W/d28" docker
stub "$W/d29/docker/docker" 'echo "broken build"; exit 1';             tar -czf "$DX/docker-29.0.0.tgz" -C "$W/d29" docker
# SKIP: the named member is a folder (registry/), which must bring no tree with it
mkdir -p "$V/containers/distribution/distribution/v3.0.0" "$W/reg/registry/deep"
stub "$W/reg/registry/registry" 'touch "'"$T"'/tree-was-unpacked"; echo "registry v3.0.0"'; echo x > "$W/reg/registry/deep/file"
tar -czf "$V/containers/distribution/distribution/v3.0.0/registry_3.0.0_linux_amd64.tar.gz" -C "$W/reg" registry
# SKIP: mirrored, but only for another platform (duckdb); an archive that cannot be unpacked (cmake)
mkdir -p "$V/databases/duckdb/duckdb/v2.0.1" "$V/toolchains/Kitware/CMake/v4.5.1"
echo arm > "$V/databases/duckdb/duckdb/v2.0.1/duckdb-cli-linux-arm64.tar.gz"
echo "not a tarball" > "$V/toolchains/Kitware/CMake/v4.5.1/cmake-4.5.1-linux-x86_64.tar.gz"
# a KeePassXC AppImage is mirrored but has no check row: it must not be run or reported
mkdir -p "$V/dev-tools/keepassxreboot/keepassxc/2.8.0"
stub "$V/dev-tools/keepassxreboot/keepassxc/2.8.0/KeePassXC-2.8.0-x86_64.AppImage" 'touch "'"$T"'/gui-was-run"'

H="$T/verify-harness.sh"
{ sed -e 's|^_LIB=.*|_LIB="'"$ROOT"'/scripts/lib"|' -e '/^case "\${1:-all}" in/,$d' "$ROOT/scripts/verify.sh"   # the harness is not in scripts/
  echo 'trap '"'"'echo caller-exit >> "$CALLER_LOG"'"'"' EXIT'
  echo 'verify_devstack "$1"; echo "rc=$?"; trap -p EXIT TERM INT > "$CALLER_LOG.after"; write_report'; } > "$H"
grep -q '^verify_devstack() {' "$H" && grep -q '^write_report() {' "$H" && pass || fail "harness must hold the real verify_devstack + write_report"
# vrun TREE PLATFORM [VAR=value ...]: one verify_devstack run + report, short timeout
vrun() { local tree="$1" plat="$2"; shift 2
         ( cd "$T" && env HOME="$T/vhome" PATH="$(dirname "$NODE"):$PATH" TMPDIR="$T/vtmp" VAL_ARK_DATA="$T/vdata" VALARK_STATE_DIR="$T/vstate" \
             CALLER_LOG="$T/caller.log" VALARK_DEVSTACK_CHECK_TIMEOUT="${VT:-2}" VALARK_DEVSTACK_DIR="$tree" "$@" bash "$H" "$plat" ) > "$T/v.out" 2>&1; }
VT=10 vrun "$V" linux-x86_64     # long enough that a healthy stub never times out on a busy runner; the TERM-ignoring one costs 15 s, once
J="$T/vstate/verify.json"
has() { grep -F -- "$1" "$J" | grep -qF -- "$2"; }
check "verify_devstack returns 0 with failures present (it never stops the loop)" 'grep -qx "rc=0" "$T/v.out"' || cat "$T/v.out" >&2
check "the caller's traps are back after the run (its EXIT trap still set and still run; no TERM / INT trap left)" 'grep -q "caller-exit" "$T/caller.log.after" && [ "$(wc -l < "$T/caller.log.after")" -eq 1 ] && [ "$(grep -c caller-exit "$T/caller.log")" -eq 1 ]'
check "verify.json is valid JSON" 'python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$J"'
check "PASS: tar.gz member (newest version)" 'has "\"status\": \"PASS\", \"comp\": \"apps\"" "tool runs: dev-stack caddy (caddy_2.0.0_linux_amd64.tar.gz)"'
check "PASS: wildcard member, output on stderr" 'has "\"status\": \"PASS\"" "tool runs: dev-stack prometheus ("'
check "PASS: bare program without its exec bit" 'has "\"status\": \"PASS\"" "tool runs: dev-stack headscale ("'
check "PASS: .bz2 program" 'has "\"status\": \"PASS\"" "tool runs: dev-stack restic ("'
if command -v unzip >/dev/null 2>&1; then
    check "PASS: zip member" 'has "\"status\": \"PASS\"" "tool runs: dev-stack ninja ("'
    check "FAIL: output does not match" 'has "\"status\": \"FAIL\", \"comp\": \"apps\"" "dev-stack rclone (rclone-v1.76.0-linux-amd64.zip: Segmentation fault)"'
else
    check "no unzip: zip projects are SKIPped with that reason, not failed" 'has "\"status\": \"SKIP\"" "dev-stack ninja: unzip not found" && has "\"status\": \"SKIP\"" "dev-stack rclone: unzip not found"'
fi
check "FAIL: non-zero exit even when the output matches" 'has "\"status\": \"FAIL\"" "tool present but won'"'"'t run: dev-stack age ("'
check "SKIP: mirrored, no build for this platform" 'has "\"status\": \"SKIP\", \"comp\": \"apps\"" "dev-stack duckdb has no linux-x86_64 build to run"'
check "SKIP: an archive that cannot be unpacked" 'has "\"status\": \"SKIP\"" "dev-stack CMake: could not be unpacked (cmake-4.5.1-linux-x86_64.tar.gz)"'
{ sed -n '/^_json_str() {/p' "$ROOT/scripts/verify.sh"; echo '_json_str "$(printf "a\001b\033[1mc\177d\te\"f")"'; } > "$T/json-str.sh"
check "_json_str itself drops every control character (any caller is safe)" '[ "$(bash "$T/json-str.sh")" = "\"ab[1mcd e\\\"f\"" ]' || bash "$T/json-str.sh" | od -c | head -3 >&2
check "FAIL: control characters, quotes and backslashes in a program's output cannot break the report" 'has "\"status\": \"FAIL\"" "dev-stack age (age-v1.3.2-linux-amd64.tar.gz: [31mv1.3.2 \\\"boom\\\" \\\\ [0m)" && ! tr -d "\n" < "$J" | LC_ALL=C grep -q "[[:cntrl:]]"'
check "FAIL: a program that ignores TERM is killed, and the run goes on" 'has "\"status\": \"FAIL\"" "dev-stack croc (croc_v11.0.0_Linux-64bit.tar.gz: croc version v11.0.0)" && ! pgrep -f "$T/vtmp/valark-verify-devstack" >/dev/null'
check "FAIL: an index folder with two versions runs the newest (old good, new broken)" 'has "\"status\": \"FAIL\"" "dev-stack Docker Engine static binaries x86_64 (docker-29.0.0.tgz: broken build)" && ! grep -q "docker-28.0.0" "$J"'
check "SKIP: a member that is a folder brings no tree with it" 'has "\"status\": \"SKIP\"" "dev-stack distribution: could not be unpacked" && [ ! -e "$T/tree-was-unpacked" ]'
check "the program gets a clean environment (minimal PATH, HOME in the temp dir, nothing of ours)" 'grep -qx "PATH=/usr/bin:/bin" "$T/env-caddy" && grep -q "^HOME=$T/vtmp/valark-verify-devstack" "$T/env-caddy" && ! grep -q "VALARK\|VAL_ARK" "$T/env-caddy"'
if unshare -rn true 2>/dev/null; then
    check "the program runs with no network (only loopback in its namespace)" '[ "$(cat "$T/net-caddy")" = 0 ]'
fi
check "projects not mirrored, and projects without a check row, are not reported" '! grep -q "dev-stack \(gitea\|Go\|keepassxc\)" "$J" && [ ! -e "$T/gui-was-run" ]'
check "the counts add up" 'python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1])); c = [x[\"status\"] for x in d[\"checks\"]]
sys.exit(0 if (d[\"pass\"], d[\"fail\"], d[\"skip\"]) == (c.count(\"PASS\"), c.count(\"FAIL\"), c.count(\"SKIP\")) and d[\"fail\"] >= 1 and d[\"skip\"] >= 2 else 1)" "$J"'
check "programs ran with HOME in the temp dir; nothing left in TMPDIR or the real HOME dir" '[ ! -e "$T/vhome/ran-here" ] && [ -z "$(ls -A "$T/vtmp")" ]'
check "nothing was installed: the tree is untouched" '[ ! -x "$V/cloud/juanfont/headscale/v0.29.8/headscale_0.29.8_linux_amd64" ] && [ -z "$(find "$V" -newer "$H" -type f)" ]'
rm -rf "$V/storage/schollz"     # the TERM-ignoring stub costs 7 s a run: once is enough
# From here the runs count how often a stub ran, so a stub must never time out: on a busy CI
# runner a 2 s limit sometimes did, the PASS was not cached, and every later count was one off.
VT=60
# the PASS cache: a pass is kept per file; a FAIL is tried again; a changed file or an old entry re-runs
CACHE="$T/vstate/devstack-checks.tsv"
check "a PASS is recorded per file (path, size, mtime, ctime, time, check row); a FAIL is not" 'F="$V/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz" awk -F"\t" "\$1 == ENVIRON[\"F\"] && \$2 > 0 && \$3 > 0 && \$4 > 0 && \$5 > 0 && index(\$6, \"caddy|version|\") == 1 { ok = 1 } END { exit !ok }" "$CACHE" && ! grep -q "age-v1.3.2\|docker-29" "$CACHE"'
vrun "$V" linux-x86_64
check "second run: the cached PASS is reported without running the program again" '[ "$(wc -l < "$T/runs-caddy")" -eq 1 ] && has "\"status\": \"PASS\"" "tool runs: dev-stack caddy (caddy_2.0.0_linux_amd64.tar.gz)"'
check "second run: a FAIL is tried again" '[ "$(wc -l < "$T/runs-age")" -eq 2 ] && has "\"status\": \"FAIL\"" "dev-stack age ("'
touch -d '2020-01-02 03:04:05' "$V/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"; vrun "$V" linux-x86_64
check "a changed file (mtime) is run again" '[ "$(wc -l < "$T/runs-caddy")" -eq 2 ]'
awk -F'\t' -v OFS='\t' '{ $5 = $5 - 8 * 86400; print }' "$CACHE" > "$CACHE.old" && mv "$CACHE.old" "$CACHE"; vrun "$V" linux-x86_64
check "an entry older than 7 days is run again" '[ "$(wc -l < "$T/runs-caddy")" -eq 3 ]'
chmod 600 "$V/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz"; vrun "$V" linux-x86_64      # ctime moves, size and mtime do not
check "a file whose ctime changed (same size and mtime) is run again" '[ "$(wc -l < "$T/runs-caddy")" -eq 4 ]'
vrun "$V" linux-x86_64
check "(and is cached again afterwards)" '[ "$(wc -l < "$T/runs-caddy")" -eq 4 ]'
awk -F'\t' -v OFS='\t' '{ $5 = $5 + 86400; print }' "$CACHE" > "$CACHE.old" && mv "$CACHE.old" "$CACHE"; vrun "$V" linux-x86_64
check "an entry stamped in the future is not trusted: run again" '[ "$(wc -l < "$T/runs-caddy")" -eq 5 ]'
VT=2
sed 's/^caddyserver\/caddy|\(.*\)|version|/caddyserver\/caddy|\1|version --json|/' "$DATA/dev-stack-checks.tsv" > "$T/checks-changed.tsv"
vrun "$V" linux-x86_64 VALARK_DEVSTACK_CHECKS="$T/checks-changed.tsv"
check "a changed check row is run again (the stub rejects the new arguments: FAIL, and the pass is dropped)" 'has "\"status\": \"FAIL\"" "dev-stack caddy (" && ! grep -q "caddy_2.0.0" "$CACHE"'
# a check file that cannot be read is a visible failure, not silence
vrun "$V" linux-x86_64 VALARK_DEVSTACK_CHECKS="$T/no-such-checks.tsv"
check "a plan that cannot be made is reported as a FAIL" 'has "\"status\": \"FAIL\"" "dev-stack run checks could not be planned (" && grep -qx "rc=0" "$T/v.out" && [ -z "$(ls -A "$T/vtmp")" ]'
printf '1000|^x$|.|--version|x\nschollz/croc|^croc_|croc|--version|x\n' > "$T/checks-odd.tsv"
"$NODE" "$ROOT/scripts/lib/devstack.js" checks "$T/checks-odd.tsv" "$DATA/dev-stack.tsv" "$D" linux-x86_64 > "$T/odd.out" 2> "$T/odd.err"; rc=$?
check "checks: a mirrored project with no versions listed (pypi-top) is a skip line, not a crash" '[ $rc -eq 0 ] && [ "$(cat "$T/odd.out")" = "skip$(printf "\037")Wheelhouse" ]' || cat "$T/odd.err" >&2
"$NODE" "$ROOT/scripts/lib/devstack.js" checks "$T/no-such-checks.tsv" "$DATA/dev-stack.tsv" "$D" linux-x86_64 > /dev/null 2> "$T/odd.err"
check "checks: an unreadable check file exits 1 with the reason" '[ $? -eq 1 ] && grep -q "no-such-checks.tsv" "$T/odd.err"'
# the size cap: nothing unpacked may grow past it (a 3 MB program against a 1 MB cap)
V2="$T/vds2"; mkdir -p "$V2/storage/restic/restic/v0.20.0"
{ printf '#!/bin/sh\necho "restic 0.20.0"\nexit 0\n'; head -c 3000000 /dev/zero; } | bzip2 -c > "$V2/storage/restic/restic/v0.20.0/restic_0.20.0_linux_amd64.bz2"
vrun "$V2" linux-x86_64 VALARK_DEVSTACK_CHECK_MAX_MB=1
check "SKIP: a file that unpacks past the cap" 'has "\"status\": \"SKIP\"" "dev-stack restic: could not be unpacked" && [ -z "$(ls -A "$T/vtmp")" ]'
vrun "$V2" linux-x86_64
check "...and the same file runs under the default cap" 'has "\"status\": \"PASS\"" "tool runs: dev-stack restic ("'
# a program that prints its version and leaves a detached child holding its output open:
# the check must end when the program does, not when the child does
V4="$T/vds4"; mkdir -p "$V4/cloud/go-gitea/gitea/v1.0.0"
stub "$V4/cloud/go-gitea/gitea/v1.0.0/gitea-1.0.0-linux-amd64" 'echo "Gitea version 1.0.0 (stub)"; setsid sleep 25.37 & exit 0'
SECONDS=0; vrun "$V4" linux-x86_64; TOOK=$SECONDS
check "a detached child cannot hold a check open (returned in ${TOOK}s, PASS on the program's own exit)" '[ "$TOOK" -lt 12 ] && has "\"status\": \"PASS\"" "tool runs: dev-stack gitea ("' || cat "$T/v.out" >&2
pkill -f 'sleep 25\.37' 2>/dev/null
# the size limit is set inside _devstack_program only: the calling shell can still write big files
{ sed -n '/^_devstack_program() {/,/^}/p' "$ROOT/scripts/verify.sh"
  echo 'VALARK_DEVSTACK_CHECK_MAX_MB=1 _devstack_program "$1" . "$2" > /dev/null; head -c 3000000 /dev/zero > "$2/big" && echo big-ok'; } > "$T/ulimit.sh"
mkdir -p "$T/ul"; bash "$T/ulimit.sh" "$V/cloud/juanfont/headscale/v0.29.8/headscale_0.29.8_linux_amd64" "$T/ul" > "$T/ulimit.out" 2>&1
check "the unpack size limit does not leak into the shell that called _devstack_program" 'grep -qx big-ok "$T/ulimit.out" && [ "$(wc -c < "$T/ul/big")" -eq 3000000 ] && [ -x "$T/ul/program" ]' || cat "$T/ulimit.out" >&2
# a killed run leaves no temp dir behind (TERM lands once the running program's timeout ends)
V3="$T/vds3"; mkdir -p "$V3/storage/schollz/croc/v11.0.0" "$W/croc3"
stub "$W/croc3/croc" 'touch "'"$T"'/croc3-started"; sleep 30'
tar -czf "$V3/storage/schollz/croc/v11.0.0/croc_v11.0.0_Linux-64bit.tar.gz" -C "$W/croc3" croc
rm -f "$J"
: > "$T/caller.log"
( cd "$T" && exec env HOME="$T/vhome" PATH="$(dirname "$NODE"):$PATH" TMPDIR="$T/vtmp" VAL_ARK_DATA="$T/vdata" VALARK_STATE_DIR="$T/vstate" CALLER_LOG="$T/caller.log" \
    VALARK_DEVSTACK_CHECK_TIMEOUT=3 VALARK_DEVSTACK_DIR="$V3" bash "$H" linux-x86_64 ) > "$T/v.out" 2>&1 & VPID=$!
for i in $(seq 1 50); do [ -e "$T/croc3-started" ] && break; sleep 0.1; done
check "(the run is in flight, with its temp dir)" '[ -e "$T/croc3-started" ] && [ -n "$(ls -A "$T/vtmp")" ]'
kill -TERM "$VPID" 2>/dev/null; wait "$VPID"; rc=$?
check "a killed run exits 143, writes no report, removes its temp dir and still runs the caller's EXIT trap" '[ $rc -eq 143 ] && [ ! -e "$J" ] && [ -z "$(ls -A "$T/vtmp")" ] && [ "$(grep -c caller-exit "$T/caller.log")" -eq 1 ]'
# a host without timeout(1): one SKIP that says so
NT="$T/no-timeout-bin"; mkdir -p "$NT"
IFS=: read -ra _dirs <<< "$(dirname "$NODE"):$PATH"
for d in "${_dirs[@]}"; do for f in "$d"/*; do n="${f##*/}"; [ "$n" != timeout ] && [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$NT/$n" ] && ln -s "$f" "$NT/$n" 2>/dev/null; done; done
( cd "$T" && env -i HOME="$T/vhome" PATH="$NT" TMPDIR="$T/vtmp" VAL_ARK_DATA="$T/vdata" VALARK_STATE_DIR="$T/vstate" CALLER_LOG="$T/caller.log" VALARK_DEVSTACK_DIR="$V2" bash "$H" linux-x86_64 ) > "$T/v.out" 2>&1
check "no timeout(1): SKIP with that reason, nothing run" 'has "\"status\": \"SKIP\"" "dev-stack run checks: timeout(1) not found" && ! grep -q "could not be unpacked\|tool runs" "$J"' || cat "$T/v.out" >&2
# the other platform: duckdb's arm64 file is now the one tried (junk -> could not be unpacked), caddy has no arm64 build
vrun "$V" linux-arm64
check "platform choice follows the argument" 'has "\"status\": \"SKIP\"" "dev-stack caddy has no linux-arm64 build to run" && has "\"status\": \"SKIP\"" "dev-stack duckdb: could not be unpacked"'
# no tree at all: silent, no node needed
rm -f "$J"; vrun "$T/nowhere" linux-x86_64
check "no dev-stack tree: nothing to check, nothing reported" 'grep -qx "rc=0" "$T/v.out" && grep -q "\"pass\": 0, \"fail\": 0, \"skip\": 0" "$J"'
check "verify_local calls verify_devstack with the host platform" 'grep -q "verify_devstack \"\${td##\*/}\"" "$ROOT/scripts/verify.sh"'

# --- no server left behind ---------------------------------------------------------------
check "every server this test started is stopped" '! pgrep -f "server.js $PORT\$" >/dev/null 2>&1 && [ -z "$SRV_PID" ]'

echo "devstack-ui: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
