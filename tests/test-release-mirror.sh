#!/bin/bash
###############################################################################
# Test: the developer + security stack mirror (scripts/lib/release_mirror.py +
# data/dev-stack.tsv). All offline: a local HTTP fixture stands in for the GitHub API,
# ftp.gnu.org, go.dev, python.org, PyPI (+ the top-packages list), the snap store and
# plain directory indexes. Invariants:
#   - the shipped catalog parses (every kind known, every regex compiles, a '|' inside a
#     match regex is part of the match) and holds the core of each group
#   - gh: latest release assets filtered by regex + the tag source tarball, sha256 digest
#     carried; a release-less repo falls back to its newest STABLE tag (source only)
#   - index: (?P<v>) keeps only the highest version (1.10 > 1.9); SHA256SUMS supplies
#     digests and is mirrored itself
#   - gnu: newest version wins, numeric not lexical; .tar.xz preferred over .tar.gz
#   - go: first stable release only, sha256 carried
#   - python: newest FINAL patch for source (pre-release dirs skipped), installers from
#     the newest patch that still ships them
#   - pypi / pypi-top: newest version, every file, yanked files skipped, sha256 carried;
#     one missing project does not drop the rest
#   - template: version from a URL or gh:owner/repo, {v}/{V} substitution, =literal
#   - snap: only the requested channel, every architecture, sha3-384 digest
#   - a failed entry -> exit 1 while the other entries are still planned; an index / gh
#     filter / gnu dir that selects nothing, a non-version template body, and pypi-top
#     projects that fail are errors (exit 1), never a silent empty mirror
#   - fetch: digest + size verified before the rename; mismatch -> no file, exit 2;
#     a .part resumes with Range; a cut-short body (no planned size) is caught against
#     Content-Length and resumed; a complete .part (and a 416) is verified and kept; a
#     server that ignores Range restarts the file; a 206 at the wrong offset restarts; an
#     oversized .part is reset; a second run downloads nothing; volatile files re-download
#     only when HEAD shows upstream changed; never writes outside --dest
#   - disk guards (#347): the Val Ark reserve, --budget and the STOP flag defer files
#     (exit 3, nothing downloaded); a budget spent mid-download keeps the .part
#   - exit codes 0 / 1 / 2 / 3 / 64; argparse errors are 64, not 2
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/release_mirror.py"
. "$ROOT/tests/lib/require-cmd.sh"; require_python3 "release-mirror"

. "$ROOT/tests/lib/ports.sh"
T="$(mktemp -d)"; SRV_PID=""
trap 'stop_pids $SRV_PID; [ -n "$KEEP" ] && cp -r "$T" "$KEEP"; rm -rf "${T:?}"' EXIT; trap_signals
unset GITHUB_TOKEN
PORT="$(free_port)"; B="http://127.0.0.1:$PORT"
mkdir -p "$T/www"

# --- fixture server ------------------------------------------------------------------
cat > "$T/srv.py" <<'PYEOF'
import hashlib, http.server, json, sys
port = int(sys.argv[1]); B = f"http://127.0.0.1:{port}"
BLOB = {name: (name * 50).encode() for name in ["tool-linux-amd64.tar.gz", "tool-windows.zip", "tool.sig",
        "app-1.9.tgz", "app-1.10.tgz", "app-1.2.tgz", "hello-2.9.tar.xz", "hello-2.10.tar.xz", "hello-2.10.tar.gz",
        "hello-2.10.tar.xz.sig", "go1.30.1.linux-amd64.tar.gz", "go1.30.1.src.tar.gz", "Python-3.13.9.tar.xz",
        "python-3.13.8-amd64.exe", "python-3.13.8-macos11.pkg", "Python-3.13.8.tar.xz", "Python-3.14.0.tar.xz", "python-3.14.0-amd64.exe", "Python-3.14.1a1.tar.xz",
        "demo-2.0-py3-none-any.whl", "demo-2.0.tar.gz", "demo-2.0-cp313-win_amd64.whl", "k-v1.2.3-linux.tar.gz",
        "k-1.2.3-mac.zip", "latest.bin", "snap-amd64", "snap-arm64", "snap-edge", "src.tar.gz", "tagsrc.tar.gz",
        "bz-1.0.tar.bz2", "gnu-keyring.gpg", "short.bin", "norange.bin", "wrongoff.bin"]}
STATE = {"latest": 1, "short": 0}
sha = lambda n: hashlib.sha256(BLOB[n]).hexdigest()
def listing(*names): return "".join(f'<a href="{n}">{n}</a>\n' for n in names).encode()
SUMS = f"{sha('app-1.10.tgz')}  app-1.10.tgz\n".encode()
ROUTES = {
  "/api/repos/o/tool/releases/latest": json.dumps({"tag_name": "v1.0", "assets": [
      {"name": "tool-linux-amd64.tar.gz", "size": 1150, "browser_download_url": f"{B}/f/tool-linux-amd64.tar.gz", "digest": "sha256:" + sha("tool-linux-amd64.tar.gz")},
      {"name": "tool-windows.zip", "size": 800, "browser_download_url": f"{B}/f/tool-windows.zip"},
      {"name": "tool.sig", "size": 400, "browser_download_url": f"{B}/f/tool.sig"}]}).encode(),
  "/api/repos/o/tagonly/git/matching-refs/tags": json.dumps([{"ref": "refs/tags/" + t} for t in ["v2.9", "show", "sprint-7", "v3.0-rc1", "v2.10", "2015012901"]]).encode(),
  "/api/repos/o/nomatch/releases/latest": json.dumps({"tag_name": "v1", "assets": [{"name": "x.zip", "size": 1, "browser_download_url": f"{B}/f/x.zip"}]}).encode(),
  "/api/repos/o/edge/releases/latest": json.dumps({"tag_name": "v1", "assets": [
      {"name": n, "size": 0, "browser_download_url": f"{B}/f/{n}"} for n in ["short.bin", "norange.bin", "wrongoff.bin"]]}).encode(),
  "/api/repos/o/stale/releases/latest": json.dumps({"tag_name": "3.2.0-alpha08", "assets": []}).encode(),
  "/api/repos/o/stale/git/matching-refs/tags": json.dumps([{"ref": "refs/tags/" + t} for t in ["3.2.0-alpha08", "2026.9.1", "2026.10.2", "2026.10.2-rc1"]]).encode(),
  "/gnu/bz/": listing("bz-0.9.tar.bz2", "bz-1.0.tar.bz2"),
  "/empty/": listing("other.txt"),
  "/ver-bad.txt": b"<html><body>Moved</body></html>\n",
  "/api/repos/o/k/releases/latest": json.dumps({"tag_name": "v1.2.3", "assets": []}).encode(),
  "/idx/": listing("app-1.9.tgz", "app-1.10.tgz", "app-1.10.tgz", "app-1.2.tgz", "SHA256SUMS", "sub/", "README"),
  "/idx/SHA256SUMS": SUMS,
  "/gnu/hello/": listing("hello-2.9.tar.xz", "hello-2.10.tar.xz", "hello-2.10.tar.gz", "hello-2.10.tar.xz.sig", "hello-2.10.tar.gz.sig"),
  "/go.json": json.dumps([{"version": "go1.31rc1", "stable": False, "files": []}, {"version": "go1.30.1", "stable": True, "files": [
      {"filename": "go1.30.1.linux-amd64.tar.gz", "kind": "archive", "size": 1350, "sha256": sha("go1.30.1.linux-amd64.tar.gz")},
      {"filename": "go1.30.1.src.tar.gz", "kind": "source", "size": 950, "sha256": sha("go1.30.1.src.tar.gz")}]}]).encode(),
  "/py/": listing("3.13.8/", "3.13.9/", "3.13.10/", "3.14.0/", "3.14.1/", "3.12.0/"),
  "/py/3.13.10/": listing("Python-3.13.10a1.tar.xz"),
  "/py/3.13.9/": listing("Python-3.13.9.tar.xz"),
  "/py/3.13.8/": listing("Python-3.13.8.tar.xz", "python-3.13.8-amd64.exe", "python-3.13.8-macos11.pkg"),
  "/py/3.14.0/": listing("Python-3.14.0.tar.xz", "python-3.14.0-amd64.exe"),
  "/py/3.14.1/": listing("Python-3.14.1a1.tar.xz"),
  "/pypi/demo/json": json.dumps({"info": {"name": "Demo_Pkg", "version": "2.0"}, "urls": [
      {"filename": "demo-2.0-py3-none-any.whl", "url": f"{B}/f/demo-2.0-py3-none-any.whl", "size": 1250, "digests": {"sha256": sha("demo-2.0-py3-none-any.whl")}},
      {"filename": "demo-2.0.tar.gz", "url": f"{B}/f/demo-2.0.tar.gz", "size": 750, "digests": {"sha256": sha("demo-2.0.tar.gz")}},
      {"filename": "demo-2.0-cp313-win_amd64.whl", "url": f"{B}/f/demo-2.0-cp313-win_amd64.whl", "size": 1400, "yanked": True, "digests": {"sha256": "0" * 64}}]}).encode(),
  "/top.json": json.dumps({"rows": [{"project": "demo"}, {"project": "gone"}, {"project": "never-reached"}]}).encode(),
  "/ver.txt": b"v1.2.3\n",
  "/snap/s?fields=download,version,revision": json.dumps({"channel-map": [
      {"channel": {"track": "latest", "risk": "stable", "architecture": "amd64"}, "version": "1.0", "revision": 7,
       "download": {"url": f"{B}/f/snap-amd64", "size": 500, "sha3-384": hashlib.sha3_384(BLOB["snap-amd64"]).hexdigest()}},
      {"channel": {"track": "latest", "risk": "stable", "architecture": "arm64"}, "version": "1.0", "revision": 8,
       "download": {"url": f"{B}/f/snap-arm64", "size": 500, "sha3-384": hashlib.sha3_384(BLOB["snap-arm64"]).hexdigest()}},
      {"channel": {"track": "latest", "risk": "edge", "architecture": "amd64"}, "version": "1.1", "revision": 9,
       "download": {"url": f"{B}/f/snap-edge", "size": 450}}]}).encode(),
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path
        with open(sys.argv[2], "a") as log: log.write(f"{self.command} {p} {self.headers.get('Range') or '-'}\n")
        if p.startswith(("/web/o/tool/archive/", "/web/o/k/archive/", "/web/o/edge/archive/")): body = BLOB["src.tar.gz"]
        elif p.startswith("/web/o/tagonly/archive/"): body = BLOB["tagsrc.tar.gz"]
        elif p.startswith("/f/") or p.startswith("/idx/app") or p.startswith("/gnu/hello/hello") or p.startswith("/gnu/bz/bz"):
            name = p.rsplit("/", 1)[-1]
            if name == "bad.bin": body = b"x" * 10
            elif name not in BLOB: return self.send_error(404)
            else: body = BLOB[name]
        elif p.startswith("/py/") and p.count("/") == 3 and not p.endswith("/"): body = BLOB[p.rsplit("/", 1)[-1]]
        elif p == "/ctl/bump": STATE["latest"] += 1; body = b"ok"
        elif p == "/t/nohead.bin": body = BLOB["latest.bin"]
        elif p == "/t/latest.bin": body = BLOB["latest.bin"] + str(STATE["latest"]).encode()
        elif p.startswith("/t/"): body = BLOB[p.rsplit("/", 1)[-1]]
        elif p == "/gnu/gnu-keyring.gpg": body = BLOB["gnu-keyring.gpg"]
        elif p.startswith("/flaky/"): return self.send_error(503)
        elif p == "/br/":
            # like a CDN that sends Brotli even when asked for identity (stdlib cannot decode it)
            self.send_response(200); self.send_header("Content-Encoding", "br"); self.send_header("Content-Length", "4"); self.end_headers(); self.wfile.write(b"\x8b\x00\x80\x03"); return
        elif p in ROUTES: body = ROUTES[p]
        else: return self.send_error(404)
        if self.command == "HEAD" and p == "/t/nohead.bin": return self.send_error(405)
        rng = self.headers.get("Range")
        name = p.rsplit("/", 1)[-1]
        start = int(rng[6:].split("-")[0]) if rng and rng.startswith("bytes=") and name != "norange.bin" else 0
        if start and start >= len(body):
            self.send_response(416); self.send_header("Content-Range", f"bytes */{len(body)}"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if start and name == "wrongoff.bin":  # claims a 206 but restarts at byte 0
            self.send_response(206); self.send_header("Content-Range", f"bytes 0-{len(body)-1}/{len(body)}"); start = 0
        elif start:
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{len(body)-1}/{len(body)}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(body) - start))
        if p == "/t/latest.bin": self.send_header("ETag", '"v%d"' % STATE["latest"])  # no 3.12-only f-string quoting
        self.end_headers()
        if self.command == "HEAD": return
        if name == "short.bin" and STATE["short"] == 0:  # first GET: promise 450 bytes, send 300, hang up
            STATE["short"] = 1; self.wfile.write(body[:300]); self.wfile.flush(); self.close_connection = True; return
        self.wfile.write(body[start:])
    do_HEAD = do_GET
s = http.server.ThreadingHTTPServer(("127.0.0.1", port), H); s.hits = []
s.serve_forever()
PYEOF
python3 "$T/srv.py" "$PORT" "$T/access.log" & SRV_PID=$!
for _ in $(seq 50); do curl -s "$B/ver.txt" >/dev/null 2>&1 && break; sleep 0.1; done

export VALARK_GH_API="$B/api" VALARK_GH_WEB="$B/web" VALARK_GNU_BASE="$B/gnu" VALARK_GO_JSON="$B/go.json" \
       VALARK_PYTHON_FTP="$B/py" VALARK_PYPI="$B/pypi" VALARK_PYPI_TOP="$B/top.json" VALARK_SNAP_API="$B/snap"
run() { python3 -I "$PY" "$@"; }
# fetch keeps the Val Ark reserve (#347): zero it so a small CI disk does not defer every file;
# the reserve, budget and STOP guards have their own checks below.
export VALARK_RESERVE_MIN_GB=0 VALARK_RESERVE_PCT=0
unset VALARK_STOP_FLAG

# --- the shipped catalog ----------------------------------------------------------------
run plan --tsv /nonexistent >/dev/null 2>&1; check "unreadable --tsv -> 64" '[ $? -eq 64 ]'
python3 -I - "$PY" "$ROOT/data/dev-stack.tsv" > "$T/cat.out" 2>&1 <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
e = m.load(sys.argv[2]); refs = {x["ref"] for x in e}; groups = {x["group"] for x in e}
need = ["NationalSecurityAgency/ghidra", "llvm/llvm-project", "relatedb/relate", "milvus-io/milvus", "containers/podman",
        "microk8s", "seaweedfs/seaweedfs", "astral-sh/python-build-standalone", "radareorg/radare2", "duckdb/duckdb"]
missing = [r for r in need if r not in refs]
pbs = next(x for x in e if x["ref"] == "astral-sh/python-build-standalone")
print(len(e), sorted(groups), missing, "|" in pbs["match"] and pbs["group"] == "python")
PYEOF
check "catalog parses with every group" 'grep -q "python.*toolchains" "$T/cat.out" && grep -q "reverse-engineering" "$T/cat.out" && grep -q "security" "$T/cat.out" && grep -q "storage" "$T/cat.out" && grep -q "databases" "$T/cat.out" && grep -q "containers" "$T/cat.out"'
check "catalog holds the core entries" 'grep -q "\[\] True$" "$T/cat.out"'
awk -F'|' '!/^#/ && NF' "$ROOT/data/dev-stack.tsv" | cut -d'|' -f2- | rev | cut -d'|' -f3- | rev | sort | uniq -d > "$T/dups"
check "no duplicate kind+ref+match in the catalog" '[ ! -s "$T/dups" ]'

# --- per-kind plans ---------------------------------------------------------------------
cat > "$T/c.tsv" <<EOF
# comment
900|gh|o/tool|\.(tar\.gz|zip)$|dev-tools|regex with a pipe
900|gh|o/tagonly||dev-tools|no releases
890|index|$B/idx/|^app-(?P<v>[\d.]+)\.tgz$|dev-tools|versioned index
880|gnu|hello||toolchains|gnu
879|gnu|bz||toolchains|bz2 only
870|go|-||toolchains|go
860|python|3.13,3.14||python|python.org
850|pypi|demo||python|pypi
840|template|$B/ver.txt|$B/t/k-{v}-linux.tar.gz $B/t/k-{V}-mac.zip $B/t/{v}/k-{v}-path.tar.gz|cloud|template from url
839|template|gh:o/k|$B/t/k-{v}-linux.tar.gz|storage|template from gh
838|template|=latest|$B/t/latest.bin|storage|literal
830|snap|s|latest/stable|containers|snap
EOF
run plan --tsv "$T/c.tsv" > "$T/plan" 2> "$T/plan.err"; rc=$?
check "plan of a clean catalog -> 0" "[ $rc -eq 0 ]" || cat "$T/plan.err" >&2
row() { grep -F -- "$1" "$T/plan"; }
check "gh: regex filters assets (no .sig)" 'row tool-linux-amd64.tar.gz >/dev/null && row tool-windows.zip >/dev/null && ! row tool.sig >/dev/null'
check "gh: sha256 digest + size carried" 'row tool-linux-amd64.tar.gz | grep -q "	1150	sha256:[0-9a-f]\{64\}	0$"'
check "gh: tag source tarball" 'row "dev-tools/o/tool/v1.0/tool-v1.0-source.tar.gz" | grep -q "/web/o/tool/archive/refs/tags/v1.0.tar.gz"'
check "gh: tag-only repo -> newest plain version tag (not show/sprint/rc/date)" 'row "dev-tools/o/tagonly/v2.10/" >/dev/null && [ "$(grep -c "o/tagonly/" "$T/plan")" -eq 1 ]'
check "index: highest version only (1.10 > 1.9)" 'row app-1.10.tgz >/dev/null && ! row app-1.9.tgz >/dev/null && ! row app-1.2.tgz >/dev/null'
check "index: a file listed twice is planned once" '[ "$(grep -c "/app-1.10.tgz	" "$T/plan")" -eq 1 ]'
check "gnu: keyring mirrored for offline .sig checks" 'row "toolchains/gnu/gnu-keyring.gpg" | grep -q "	1$"'
check "safe(): long names stay distinct" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"rm\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
a,b=m.safe(\"x\"*200+\"a\"),m.safe(\"x\"*200+\"b\")
t=m.safe(\"y\"*200+\".tar.gz\"); u=m.safe(\"tool-1.2.3-\"+\"z\"*200+\".zip\")
sys.exit(0 if a!=b and len(a)<=180 and len(t)<=180 and t.endswith(\".tar.gz\") and u.endswith(\".zip\") and u.startswith(\"tool-1.2.3-\") and len(u)<=180 and m.safe(\"short\")==\"short\" else 1)"'
VALARK_GNU_BASE="$B/dead,$B/gnu" run plan --tsv "$T/c.tsv" --only hello > "$T/gm" 2>&1
check "gnu: a first mirror without the package (404) falls back to the next" 'grep -q "gnu/hello/2.10/hello-2.10.tar.xz" "$T/gm"'
python3 -I - "$PY" "$T/c.tsv" <<'PYEOF' > "$T/gm3" 2>&1; rc=$?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.GNU = "http://127.0.0.1:1," + m.GNU.split(",")[0]  # port 1: connection refused (unreachable)
dead = []; real = m.hrefs
m.hrefs = lambda url, tries=m.TRIES: (dead.append(tries) if url.startswith("http://127.0.0.1:1/") else None) or real(url, tries)
rows, fails = m.plan([e for e in m.load(sys.argv[2]) if e["ref"] in ("hello", "bz")])
print("dead-calls", dead, "rows", len(rows), "fails", len(fails))
PYEOF
check "gnu: an unreachable mirror gets ONE single-try request per run, not per package" 'grep -q "dead-calls \[1\] rows" "$T/gm3" && grep -q "fails 0" "$T/gm3"' || cat "$T/gm3" >&2
VALARK_GNU_BASE="$B/dead" run plan --tsv "$T/c.tsv" --only hello > "$T/gm2" 2>&1; rc=$?
check "gnu: no mirror answering -> exit 1, names the mirrors" '[ $rc -eq 1 ] && grep -q "no mirror answered" "$T/gm2"'
python3 -I - "$PY" "$B" <<'PYEOF' > "$T/lk.out" 2>&1
import importlib.util, sys, threading
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.GNU = f"{sys.argv[2]}/gnu,{sys.argv[2]}/dead"
m.gnu_listing("hello")  # first answer marks the mirror live
held = []; real = m.hrefs
def spy(url, tries=m.TRIES): held.append(m.MIRROR_LOCK.locked()); return real(url, tries)
m.hrefs = spy; m.gnu_listing("bz")
m.GNU = f"http://127.0.0.1:1,{sys.argv[2]}/dead"; m.hrefs = real
try: m.gnu_listing("hello")
except LookupError: pass
try: m.gnu_listing("bz")
except LookupError as e: print("msg", "skipped (unreachable earlier" in str(e))
print("live-unlocked", held == [False])
m.DEAD_MIRRORS.clear(); m.LIVE_MIRRORS.clear()
m.GNU = f"{sys.argv[2]}/flaky,{sys.argv[2]}/gnu"  # /flaky/ answers 503: reachable, so NOT dead
m.gnu_listing("hello")
print("http-error-not-dead", f"{sys.argv[2]}/flaky" not in m.DEAD_MIRRORS and f"{sys.argv[2]}/flaky" in m.LIVE_MIRRORS)
m.GNU = f"http://127.0.0.1:1,{sys.argv[2]}/gnu"  # nothing listens on port 1: connection refused
m.gnu_listing("hello")
print("refused-dead", "http://127.0.0.1:1" in m.DEAD_MIRRORS)
PYEOF
check "gnu: a mirror that answered is used without the lock; a skipped dead mirror is named" 'grep -q "live-unlocked True" "$T/lk.out" && grep -q "msg True" "$T/lk.out"' || cat "$T/lk.out" >&2
check "gnu: an HTTP error keeps a mirror live; only a network failure marks it dead" 'grep -q "http-error-not-dead True" "$T/lk.out" && grep -q "refused-dead True" "$T/lk.out"' || cat "$T/lk.out" >&2
check "index: SHA256SUMS digest + file mirrored" 'row app-1.10.tgz | grep -q "sha256:" && row "/SHA256SUMS" >/dev/null && ! row README >/dev/null'
check "volatile flag: SUMS + =literal 1, versioned 0" 'row "/SHA256SUMS" | grep -q "	1$" && row latest.bin | grep -q "	1$" && row app-1.10.tgz | grep -q "	0$" && row "/t/k-1.2.3-mac.zip" | grep -q "	0$"'
check "gnu: 2.10 > 2.9, xz preferred, sig kept" 'row hello-2.10.tar.xz >/dev/null && row hello-2.10.tar.xz.sig >/dev/null && ! row hello-2.9 >/dev/null && ! row hello-2.10.tar.gz >/dev/null'
check "gnu: a bz2-only release is still mirrored" 'row "gnu/bz/1.0/bz-1.0.tar.bz2" >/dev/null && ! row bz-0.9 >/dev/null'
check "template: a version in the path is not repeated in dest" 'row "cloud/127.0.0.1-$PORT/v1.2.3/t/k-v1.2.3-path.tar.gz" >/dev/null'
check "go: stable only, sha256" 'row go1.30.1.linux-amd64.tar.gz | grep -q sha256: && row go1.30.1.src.tar.gz >/dev/null && ! row go1.31 >/dev/null'
check "python: newest final source, pre-release dirs skipped" 'row "python/3.13.9/Python-3.13.9.tar.xz" >/dev/null && ! row 3.13.10 >/dev/null && ! row 3.14.1 >/dev/null && row python-3.14.0-amd64.exe >/dev/null'
check "python: installers from the newest patch that ships them" 'row python-3.13.8-amd64.exe >/dev/null && row python-3.13.8-macos11.pkg >/dev/null && ! row Python-3.13.8.tar.xz >/dev/null'
check "pypi: normalized name, yanked skipped, sha256" 'row "python/pypi/demo-pkg/2.0/demo-2.0-py3-none-any.whl" | grep -q sha256: && row demo-2.0.tar.gz >/dev/null && ! row win_amd64 >/dev/null'
check "template: {v} and {V}" 'row "/t/k-v1.2.3-linux.tar.gz" >/dev/null && row "/t/k-1.2.3-mac.zip" >/dev/null'
check "template: gh: version + =literal" '[ "$(grep -c "k-v1.2.3-linux" "$T/plan")" -ge 1 ] && row "storage/127.0.0.1-$PORT/latest/t/latest.bin" >/dev/null'
check "snap: channel filter, both arches, sha3-384" '[ "$(grep -c "containers/snap/s/" "$T/plan")" -eq 2 ] && row snap-amd64 | grep -q "sha3_384:" && ! row snap-edge >/dev/null'
check "plan is ordered by rank" '[ "$(head -1 "$T/plan" | cut -f2 | cut -d/ -f1)" = dev-tools ] && [ "$(tail -1 "$T/plan" | cut -f2 | cut -d/ -f1)" = containers ]'

# a failing entry: exit 1, others still planned; pypi-top tolerates one missing project
printf '900|gh|o/missing||dev-tools|404\n800|pypi-top|2||python|top\n' > "$T/f.tsv"
run plan --tsv "$T/f.tsv" > "$T/fplan" 2> "$T/ferr"; rc=$?
check "a failed entry -> exit 1" '[ $rc -eq 1 ] && grep -q "ERROR resolve gh o/missing" "$T/ferr"'
check "pypi-top: missing project is an error, rest planned" 'grep -q demo-2.0.tar.gz "$T/fplan" && grep -q "ERROR resolve pypi-top 2: 1 of 2 projects unresolved" "$T/ferr" && ! grep -q never "$T/fplan"'
printf '900|index|%s/br/|^app-.*\\.tgz$|g|n\n' "$B" > "$T/br.tsv"; run plan --tsv "$T/br.tsv" >/dev/null 2> "$T/brerr"
check "a Brotli listing is named as the error (not just an empty index)" 'grep -q "undecodable Content-Encoding br" "$T/brerr"'
printf '900|template|gh:o/stale|%s/t/n-{V}.bin|g|n\n900|template|ghtag:o/stale|%s/t/n-{V}.bin|g2|n\n' "$B" "$B" > "$T/st.tsv"
run plan --tsv "$T/st.tsv" > "$T/stplan" 2> "$T/sterr"; rc=$?
check "gh: template with a non-version latest release -> ERROR; ghtag: -> newest plain tag" '[ $rc -eq 1 ] && grep -q "not a plain version" "$T/sterr" && grep -q "g2/127.0.0.1-$PORT/2026.10.2/t/n-2026.10.2.bin" "$T/stplan" && [ "$(wc -l < "$T/stplan")" -eq 1 ]'
for bad in "900|index|$B/br/|^app-.*\\.tgz\$|g|n" "900|index|$B/empty/|^app-.*\\.tgz\$|g|n" "900|gh|o/nomatch|\\.tar\\.gz\$|g|n" "900|template|$B/ver-bad.txt|$B/t/k-{v}.bin|g|n"; do
  printf '%s\n' "$bad" > "$T/e.tsv"; run plan --tsv "$T/e.tsv" > "$T/eplan" 2> "$T/eerr"; rc=$?
  check "selects nothing / bad version -> exit 1 + ERROR ($(cut -d'|' -f2 <<< "$bad"))" '[ $rc -eq 1 ] && grep -q "^ERROR resolve" "$T/eerr" && [ ! -s "$T/eplan" ]'
done
printf '900|gh|o/missing||dev-tools|404\n' > "$T/n.tsv"
run plan --tsv "$T/n.tsv" >/dev/null 2>&1; check "nothing resolved, entry failed -> 1" '[ $? -eq 1 ]'

# usage errors are 64
printf '900|nope|x||g|n\n' > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "unknown kind -> 64" '[ $? -eq 64 ]'
printf '900|gh|o/tool|([|g|n\n' > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "bad regex -> 64" '[ $? -eq 64 ]'
printf '900|index|%s/idx/||g|n\n' "$B" > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "index without a match -> 64" '[ $? -eq 64 ]'
printf '900|template|%s/ver.txt| |g|n\n800|gh|o/tool||g|n\n' "$B" > "$T/u.tsv"; : > "$T/access.log"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; rc=$?
check "template without URLs -> 64 before any request" '[ $rc -eq 64 ] && [ ! -s "$T/access.log" ]'
printf '900|pypi-top|lots||g|n\n' > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "pypi-top with a non-number -> 64" '[ $? -eq 64 ]'
run plan --bogus >/dev/null 2>&1; check "argparse error -> 64" '[ $? -eq 64 ]'
run fetch --tsv "$T/c.tsv" >/dev/null 2>&1; check "fetch without --dest -> 64" '[ $? -eq 64 ]'
run plan --tsv "$T/c.tsv" --group nothing >/dev/null 2>&1; check "filters matching nothing -> 64" '[ $? -eq 64 ]'

# --- fetch ------------------------------------------------------------------------------
export VALARK_RETRY_SLEEP=0
printf '900|gh|o/tool|\\.zip$|dev-tools|n\n' > "$T/m.tsv"
D="$T/dest"
run fetch --tsv "$T/c.tsv" --only o/tool --only "$B/idx/" --only s --dest "$D" > "$T/fetch1" 2> "$T/fetch1.err"; rc=$?
check "fetch -> 0" '[ $rc -eq 0 ]' || cat "$T/fetch1.err" >&2
check "files land at their dest" '[ -f "$D/dev-tools/o/tool/v1.0/tool-linux-amd64.tar.gz" ] && [ -f "$D/containers/snap/s/1.0-r7/s_amd64_r7.snap" ]'
check "no .part left behind" '[ -z "$(find "$D" -name "*.part")" ]'
: > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --only "$B/idx/" --only s --dest "$D" > "$T/fetch2" 2>&1
check "first run reported ok rows" 'grep -q "^ok	" "$T/fetch1"'
check "second run downloads nothing" '! grep -q "^ok	" "$T/fetch2" && ! grep -Eq "^GET /(f|idx/app|web)/" "$T/access.log"'

# resume: a partial .part is continued with a Range request
F="$D/dev-tools/o/tool/v1.0/tool-windows.zip"; head -c 100 "$F" > "$F.part"; rm "$F"; : > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$D" >/dev/null 2>&1
check "a .part resumes with Range" 'grep -q "tool-windows.zip bytes=100-" "$T/access.log" && [ "$(wc -c < "$F")" -eq 800 ]'

# a complete .part (killed before the rename): verified + renamed, no request at all
cp "$F" "$F.part"; rm "$F"; : > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$D" > "$T/cp.out" 2>&1; rc=$?
check "a complete .part is finished without a request" '[ $rc -eq 0 ] && [ -f "$F" ] && [ ! -e "$F.part" ] && ! grep -q "tool-windows.zip" "$T/access.log"'
# an oversized .part is reset and the file fetched whole
head -c 900 /dev/zero > "$F.part"; rm "$F"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$D" >/dev/null 2>&1
check "an oversized .part is reset" '[ "$(wc -c < "$F")" -eq 800 ] && cmp -s "$F" <(curl -s "$B/f/tool-windows.zip")'

# unknown size (source tarballs, templates): cut-short body caught via Content-Length + resumed;
# a server ignoring Range restarts; a 206 at the wrong offset restarts; a 416 .part is kept
printf '900|gh|o/edge||dev-tools|n\n' > "$T/edge.tsv"; E="$T/edge"
mkdir -p "$E/dev-tools/o/edge/v1"; head -c 200 /dev/zero > "$E/dev-tools/o/edge/v1/norange.bin.part"
curl -s "$B/f/wrongoff.bin" | head -c 100 > "$E/dev-tools/o/edge/v1/wrongoff.bin.part"
: > "$T/access.log"
VALARK_RETRY_SLEEP=0 run fetch --tsv "$T/edge.tsv" --dest "$E" > "$T/edge.out" 2> "$T/edge.err"; rc=$?
check "edge fetch -> 0" '[ $rc -eq 0 ]' || cat "$T/edge.err" >&2
for n in short norange wrongoff; do
  check "$n.bin lands whole and correct" 'cmp -s "$E/dev-tools/o/edge/v1/$n.bin" <(curl -s "$B/f/$n.bin")'
done
check "the cut-short body was resumed, not restarted" 'grep -q "GET /f/short.bin bytes=300-" "$T/access.log"'
SB="$E/dev-tools/o/edge/v1/short.bin"; cp "$SB" "$SB.part"; rm "$SB"; : > "$T/access.log"
VALARK_RETRY_SLEEP=0 run fetch --tsv "$T/edge.tsv" --dest "$E" >/dev/null 2>&1; rc=$?
check "416 on a complete .part (no planned size) -> verified + kept" '[ $rc -eq 0 ] && [ -f "$SB" ] && [ ! -e "$SB.part" ] && grep -q "short.bin bytes=450-" "$T/access.log"'

# volatile (=latest): HEAD decides; unchanged -> skip, changed -> re-download
printf '838|template|=latest|%s/t/latest.bin|storage|literal\n' "$B" > "$T/v.tsv"; V="$T/vol"
run fetch --tsv "$T/v.tsv" --dest "$V" >/dev/null 2>&1; LB=$(find "$V" -name latest.bin)
check "volatile file + sidecar written" '[ -f "$LB" ] && grep -q ETag "$LB.source.json"'
: > "$T/access.log"; run fetch --tsv "$T/v.tsv" --dest "$V" > "$T/v2" 2>&1
check "volatile unchanged upstream -> HEAD only, skip" 'grep -q "^skip" "$T/v2" && grep -q "^HEAD /t/latest.bin" "$T/access.log" && ! grep -q "^GET /t/latest.bin" "$T/access.log"'
curl -s "$B/ctl/bump" >/dev/null; run fetch --tsv "$T/v.tsv" --dest "$V" > "$T/v3" 2>&1
check "volatile changed upstream -> re-downloaded" 'grep -q "^ok" "$T/v3" && grep -q "latest.bin2$" <(tail -c 20 "$LB"; echo)'

# a digest-verified file is stamped; a later run trusts the stamp (no re-hash) until the file changes
python3 -I - "$PY" "$D" <<'PYEOF' > "$T/st.out" 2>&1
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
f = next(pathlib.Path(sys.argv[2]).rglob("tool-linux-amd64.tar.gz")); dg = "sha256:" + __import__("hashlib").sha256(f.read_bytes()).hexdigest()
calls = []; real = m.hashlib.new; m.hashlib.new = lambda a: calls.append(a) or real(a)
print("stamp", m.stamp_path(f).exists())
print("trusted", m.check(f, 0, dg, trust_stamp=True), len(calls))
os.utime(f, ns=(1, 1)); print("rehash", m.check(f, 0, dg, trust_stamp=True), len(calls))
print("wrong", m.check(f, 0, "sha256:" + "0" * 64, trust_stamp=True) is not None)
PYEOF
check "verified stamp: written, trusted, invalidated by mtime, never for another digest" 'grep -q "stamp True" "$T/st.out" && grep -q "trusted None 0" "$T/st.out" && grep -q "rehash None 1" "$T/st.out" && grep -q "wrong True" "$T/st.out"' || cat "$T/st.out" >&2

# the stamp through fetch: a second fetch skips a digest file WITHOUT hashing it; VALARK_REHASH=1 re-hashes
python3 -I - "$PY" "$T/c.tsv" "$T/stampdest" <<'PYEOF' > "$T/sf.out" 2>&1
import importlib.util, io, contextlib, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []; real = m.hashlib.new; m.hashlib.new = lambda a: calls.append(a) or real(a)
args = ["fetch", "--tsv", sys.argv[2], "--only", "o/tool", "--dest", sys.argv[3]]
with contextlib.redirect_stdout(io.StringIO()): r1 = m.main(args)
n1 = len(calls)
with contextlib.redirect_stdout(io.StringIO()) as o: r2 = m.main(args)
n2 = len(calls) - n1
m.REHASH = True
with contextlib.redirect_stdout(io.StringIO()): r3 = m.main(args)
n3 = len(calls) - n1 - n2
print("r", r1, r2, r3, "first", n1 > 0, "second", n2, "skips", o.getvalue().count("skip"), "rehash", n3 > 0)
PYEOF
check "stamp via fetch: rerun skips without hashing; VALARK_REHASH=1 re-hashes" 'grep -q "r 0 0 0 first True second 0 skips 3 rehash True" "$T/sf.out"' || cat "$T/sf.out" >&2
# the GNU keyring is actually fetched (gnu rows through fetch)
run fetch --tsv "$T/c.tsv" --only hello --dest "$T/gnudest" > "$T/gf" 2>&1; rc=$?
check "gnu fetch: tarball, .sig and keyring land" '[ $rc -eq 0 ] && [ -f "$T/gnudest/toolchains/gnu/gnu-keyring.gpg" ] && [ -f "$T/gnudest/toolchains/gnu/hello/2.10/hello-2.10.tar.xz.sig" ]' || cat "$T/gf" >&2

# a volatile .part with no digest is never resumed (its bytes may be an older upstream file)
printf '838|template|=latest|%s/t/latest.bin|storage|literal\n' "$B" > "$T/v.tsv"; V2="$T/vol2"
LB2="$V2/storage/127.0.0.1-$PORT/latest/t/latest.bin"; mkdir -p "$(dirname "$LB2")"; printf 'XXXXX' > "$LB2.part"
run fetch --tsv "$T/v.tsv" --dest "$V2" >/dev/null 2>&1
check "volatile .part discarded, file fetched whole" 'cmp -s "$LB2" <(curl -s "$B/t/latest.bin")'
# a server that refuses HEAD: the volatile file is re-downloaded with GET, not an error
printf '838|template|=latest|%s/t/nohead.bin|storage|literal\n' "$B" > "$T/nh.tsv"
run fetch --tsv "$T/nh.tsv" --dest "$T/nh" >/dev/null 2>&1; run fetch --tsv "$T/nh.tsv" --dest "$T/nh" > "$T/nh2" 2>&1; rc=$?
check "HEAD refused (405) -> re-download, exit 0" '[ $rc -eq 0 ] && grep -q "^ok" "$T/nh2"'
# a leftover complete-size .part with the wrong bytes is restarted in the same run
G="$D/dev-tools/o/tool/v1.0/tool-linux-amd64.tar.gz"; rm -f "$G"; head -c 1150 /dev/zero > "$G.part"
printf '900|gh|o/tool|linux-amd64|dev-tools|n\n' > "$T/g.tsv"
run fetch --tsv "$T/g.tsv" --dest "$D" >/dev/null 2>&1; rc=$?
check "bad leftover .part -> restarted in this run, exit 0" '[ $rc -eq 0 ] && cmp -s "$G" <(curl -s "$B/f/tool-linux-amd64.tar.gz")'

# a body longer than the planned size, and a 404 (not retried)
python3 -I - "$PY" "$T/m.tsv" "$T/dest5" "$B" > "$T/lg.out" 2>&1 <<'PYEOF'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.BACKOFF = 0
real = m.plan
m.plan = lambda e: ([(u, d, 700, "", 0) for u, d, s, g, v in real(e)[0] if d.endswith(".zip")] + [(sys.argv[4] + "/f/nope.bin", "x/nope.bin", 0, "", 0)], [])
rc = m.main(["fetch", "--tsv", sys.argv[2], "--dest", sys.argv[3]])
print("rc", rc, "zip", any(pathlib.Path(sys.argv[3]).rglob("*.zip")))
PYEOF
check "body longer than planned -> exit 2, no file" 'grep -q "rc 2 zip False" "$T/lg.out"' || cat "$T/lg.out" >&2
check "a 404 download is not retried" '[ "$(grep -c "GET /f/nope.bin" "$T/access.log")" -eq 1 ]'

# size check without a digest: a planned size the body does not reach -> exit 2, no file
python3 -I - "$PY" "$T/m.tsv" "$T/dest4" > "$T/sz.out" 2>&1 <<'PYEOF'
import importlib.util, os, pathlib, sys
os.environ["VALARK_RETRY_SLEEP"] = "0"
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.BACKOFF = 0
real = m.plan
m.plan = lambda e: ([(u, d, 801, "", 0) for u, d, s, g, v in real(e)[0] if d.endswith(".zip")], [])
rc = m.main(["fetch", "--tsv", sys.argv[2], "--dest", sys.argv[3]])
print("rc", rc, "zip", any(pathlib.Path(sys.argv[3]).rglob("*.zip")))
PYEOF
check "size mismatch without a digest -> exit 2, no file" 'grep -q "rc 2 zip False" "$T/sz.out"' || cat "$T/sz.out" >&2

# digest mismatch: no file, exit 2
python3 -I - "$PY" "$T/m.tsv" "$T/dest2" > "$T/mm.out" 2>&1 <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = m.plan
def tampered(entries):
    rows, f = real(entries)
    return [(u, d, s, "sha256:" + "1" * 64, v) if d.endswith(".zip") else (u, d, s, g, v) for u, d, s, g, v in rows], f
m.plan = tampered
rc = m.main(["fetch", "--tsv", sys.argv[2], "--dest", sys.argv[3]])
import pathlib
print("rc", rc, "zip", any(pathlib.Path(sys.argv[3]).rglob("*.zip")), "part", any(pathlib.Path(sys.argv[3]).rglob("*.part")))
PYEOF
check "digest mismatch -> exit 2, nothing finalized" 'grep -q "rc 2 zip False part False" "$T/mm.out"' || cat "$T/mm.out" >&2

# containment: a dest that climbs out of --dest is refused
python3 -I - "$PY" "$T/c.tsv" "$T/dest3" > "$T/esc.out" 2>&1 <<PYEOF
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.plan = lambda e: ([("$B/f/tool.sig", "../escape.sig", 400, "", 0)], [])
print("rc", m.main(["fetch", "--tsv", sys.argv[2], "--dest", sys.argv[3]]))
PYEOF
check "dest outside --dest refused -> 2" 'grep -q "rc 2" "$T/esc.out" && [ ! -e "$T/escape.sig" ]'
check "safe() strips path separators from upstream names" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"rm\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
sys.exit(0 if m.row(\"u\",\"g\",\"../..\",\"a/b\")[1]==\"g/_/a-b\" else 1)"'

# --- disk guards (#347): the reserve, --budget and the STOP flag defer (exit 3), keep .parts --
G="$T/guard"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$G" --budget x >/dev/null 2>&1; check "--budget not a number -> 64" '[ $? -eq 64 ]'
: > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$G" --budget 0 > "$T/g0" 2>&1; rc=$?
check "--budget 0 -> exit 3, every file deferred, nothing downloaded" '[ $rc -eq 3 ] && grep -q "^deferred	" "$T/g0" && ! grep -q "^ok	" "$T/g0" && ! grep -Eq "^GET /(f|web)/" "$T/access.log"' || cat "$T/g0" >&2
: > "$T/access.log"
VALARK_RESERVE_MIN_GB=999999999 run fetch --tsv "$T/c.tsv" --only o/tool --dest "$G" > "$T/gr" 2>&1; rc=$?
check "the Val Ark reserve -> exit 3, nothing downloaded" '[ $rc -eq 3 ] && grep -q "reserve" "$T/gr" && ! grep -Eq "^GET /(f|web)/" "$T/access.log"' || cat "$T/gr" >&2
touch "$T/STOP"; : > "$T/access.log"
VALARK_STOP_FLAG="$T/STOP" run fetch --tsv "$T/c.tsv" --only o/tool --dest "$G" > "$T/gs" 2>&1; rc=$?
check "the STOP flag -> exit 3, nothing downloaded" '[ $rc -eq 3 ] && grep -q "STOP" "$T/gs" && ! grep -Eq "^GET /(f|web)/" "$T/access.log"' || cat "$T/gs" >&2
rm -f "$T/STOP"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$G" --budget 100000000 > "$T/gb" 2>&1; rc=$?
check "a budget that fits -> 0, files land" '[ $rc -eq 0 ] && grep -q "^ok	" "$T/gb"' || cat "$T/gb" >&2
# mid-download: the budget is re-checked while writing; the .part stays and resumes next run
python3 -I - "$PY" "$T/c.tsv" "$T/guard2" > "$T/gm.out" 2>&1 <<'PYEOF'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.RECHECK = 1                          # re-check after every chunk
class Spent(m.Guard):                  # the budget runs out once the first bytes are written
    def why(self, path, need=0):
        return "this run's byte budget is spent" if self.added > 0 else None
m.GUARD = Spent()
rc = m.main(["fetch", "--tsv", sys.argv[2], "--only", "o/tool", "--dest", sys.argv[3]])
parts = list(pathlib.Path(sys.argv[3]).rglob("*.part"))
print("rc", rc, "parts", len(parts) > 0)
PYEOF
check "budget spent mid-download -> exit 3, the .part is kept" 'grep -q "rc 3 parts True" "$T/gm.out"' || cat "$T/gm.out" >&2

# a body whose Content-Length (the planned size is unknown) exceeds the budget is deferred before
# any byte is written: exit 3, the request was made, no .part, no file
rm -rf "$T/cl"; : > "$T/access.log"
run fetch --tsv "$T/edge.tsv" --dest "$T/cl" --budget 100 > "$T/cl.out" 2> "$T/cl.err"; rc=$?
check "Content-Length over --budget -> exit 3, deferred" '[ $rc -eq 3 ] && grep -q "^deferred	" "$T/cl.out" && ! grep -q "^ok	" "$T/cl.out"' || { cat "$T/cl.out" "$T/cl.err" >&2; }
check "the over-budget body is refused after the response headers (a GET was made)" 'grep -q "^GET /web/o/edge/archive/" "$T/access.log"'
check "nothing written: no .part, no file" '[ -z "$(find "$T/cl" -type f 2>/dev/null)" ]'
check "the summary line reports the deferred files" 'grep -q "^summary: .*deferred=[1-9]" "$T/cl.err"'

# N5: a resolve failure (exit 1) must not hide that files were also deferred (exit 3): both are reported
printf '900|gh|o/missing||dev-tools|404\n' > "$T/mix.tsv"; cat "$T/edge.tsv" >> "$T/mix.tsv"; rm -rf "$T/mx"
run fetch --tsv "$T/mix.tsv" --dest "$T/mx" --budget 100 > "$T/mx.out" 2> "$T/mx.err"; rc=$?
check "resolve failure + deferred files -> exit 1, summary names both" '[ $rc -eq 1 ] && grep -q "^summary: resolve_failures=1 fetch_errors=0 deferred=[1-9]" "$T/mx.err"' || cat "$T/mx.err" >&2

# the STOP-flag early exit also prints the summary line (the loop reads it), with the resolve failure
: > "$T/stopflag"
VALARK_STOP_FLAG="$T/stopflag" run fetch --tsv "$T/mix.tsv" --dest "$T/sf" --budget 100 > "$T/sf.out" 2> "$T/sf.err"; rc=$?
check "STOP flag + resolve failure -> exit 1, summary line names both" '[ $rc -eq 1 ] && grep -q "^summary: resolve_failures=1 fetch_errors=0 deferred=[1-9]" "$T/sf.err" && ! grep -q "^ok	" "$T/sf.out"' || cat "$T/sf.err" >&2

echo "release-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
