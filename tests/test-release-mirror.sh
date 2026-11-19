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
#   - a failed entry -> exit 1 while the other entries are still planned
#   - fetch: digest + size verified before the rename; mismatch -> no file, exit 2;
#     a .part resumes with Range; a second run downloads nothing; never writes outside --dest
#   - exit codes 0 / 1 / 2 / 3 / 64; argparse errors are 64, not 2
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/release_mirror.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }

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
        "k-1.2.3-mac.zip", "latest.bin", "snap-amd64", "snap-arm64", "snap-edge", "src.tar.gz", "tagsrc.tar.gz"]}
sha = lambda n: hashlib.sha256(BLOB[n]).hexdigest()
def listing(*names): return "".join(f'<a href="{n}">{n}</a>\n' for n in names).encode()
SUMS = f"{sha('app-1.10.tgz')}  app-1.10.tgz\n".encode()
ROUTES = {
  "/api/repos/o/tool/releases/latest": json.dumps({"tag_name": "v1.0", "assets": [
      {"name": "tool-linux-amd64.tar.gz", "size": 1150, "browser_download_url": f"{B}/f/tool-linux-amd64.tar.gz", "digest": "sha256:" + sha("tool-linux-amd64.tar.gz")},
      {"name": "tool-windows.zip", "size": 800, "browser_download_url": f"{B}/f/tool-windows.zip"},
      {"name": "tool.sig", "size": 400, "browser_download_url": f"{B}/f/tool.sig"}]}).encode(),
  "/api/repos/o/tagonly/tags?per_page=100": json.dumps([{"name": "v3.0-rc1"}, {"name": "v2.10"}, {"name": "v2.9"}]).encode(),
  "/api/repos/o/k/releases/latest": json.dumps({"tag_name": "v1.2.3", "assets": []}).encode(),
  "/idx/": listing("app-1.9.tgz", "app-1.10.tgz", "app-1.2.tgz", "SHA256SUMS", "sub/", "README"),
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
        if p.startswith(("/web/o/tool/archive/", "/web/o/k/archive/")): body = BLOB["src.tar.gz"]
        elif p.startswith("/web/o/tagonly/archive/"): body = BLOB["tagsrc.tar.gz"]
        elif p.startswith("/f/") or p.startswith("/idx/app") or p.startswith("/gnu/hello/hello"):
            name = p.rsplit("/", 1)[-1]
            if name == "bad.bin": body = b"x" * 10
            elif name not in BLOB: return self.send_error(404)
            else: body = BLOB[name]
        elif p.startswith("/py/") and p.count("/") == 3 and not p.endswith("/"): body = BLOB[p.rsplit("/", 1)[-1]]
        elif p == "/t/latest.bin": body = BLOB["latest.bin"]
        elif p.startswith("/t/"): body = BLOB[p.rsplit("/", 1)[-1]]
        elif p in ROUTES: body = ROUTES[p]
        else: return self.send_error(404)
        if p.startswith("/f/") and self.server.hits is not None: self.server.hits.append(p)
        start = 0
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0])
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{len(body)-1}/{len(body)}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(body) - start)); self.end_headers(); self.wfile.write(body[start:])
        with open(sys.argv[2], "a") as log: log.write(f"{p} {rng or '-'}\n")
s = http.server.ThreadingHTTPServer(("127.0.0.1", port), H); s.hits = []
s.serve_forever()
PYEOF
python3 "$T/srv.py" "$PORT" "$T/access.log" & SRV_PID=$!
for _ in $(seq 50); do curl -s "$B/ver.txt" >/dev/null 2>&1 && break; sleep 0.1; done

export VALARK_GH_API="$B/api" VALARK_GH_WEB="$B/web" VALARK_GNU_BASE="$B/gnu" VALARK_GO_JSON="$B/go.json" \
       VALARK_PYTHON_FTP="$B/py" VALARK_PYPI="$B/pypi" VALARK_PYPI_TOP="$B/top.json" VALARK_SNAP_API="$B/snap"
run() { python3 -I "$PY" "$@"; }

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
870|go|-||toolchains|go
860|python|3.13,3.14||python|python.org
850|pypi|demo||python|pypi
840|template|$B/ver.txt|$B/t/k-{v}-linux.tar.gz $B/t/k-{V}-mac.zip|cloud|template from url
839|template|gh:o/k|$B/t/k-{v}-linux.tar.gz|storage|template from gh
838|template|=latest|$B/t/latest.bin|storage|literal
830|snap|s|latest/stable|containers|snap
EOF
run plan --tsv "$T/c.tsv" > "$T/plan" 2> "$T/plan.err"; rc=$?
check "plan of a clean catalog -> 0" "[ $rc -eq 0 ]" || cat "$T/plan.err" >&2
row() { grep -F -- "$1" "$T/plan"; }
check "gh: regex filters assets (no .sig)" 'row tool-linux-amd64.tar.gz >/dev/null && row tool-windows.zip >/dev/null && ! row tool.sig >/dev/null'
check "gh: sha256 digest + size carried" 'row tool-linux-amd64.tar.gz | grep -q "	1150	sha256:[0-9a-f]\{64\}$"'
check "gh: tag source tarball" 'row "dev-tools/o/tool/v1.0/tool-v1.0-source.tar.gz" | grep -q "/web/o/tool/archive/refs/tags/v1.0.tar.gz"'
check "gh: tag-only repo -> newest stable tag source" 'row "dev-tools/o/tagonly/v2.10/" >/dev/null && ! row "rc1" >/dev/null'
check "index: highest version only (1.10 > 1.9)" 'row app-1.10.tgz >/dev/null && ! row app-1.9.tgz >/dev/null && ! row app-1.2.tgz >/dev/null'
check "index: SHA256SUMS digest + file mirrored" 'row app-1.10.tgz | grep -q "sha256:" && row "/SHA256SUMS" >/dev/null && ! row README >/dev/null'
check "gnu: 2.10 > 2.9, xz preferred, sig kept" 'row hello-2.10.tar.xz >/dev/null && row hello-2.10.tar.xz.sig >/dev/null && ! row hello-2.9 >/dev/null && ! row hello-2.10.tar.gz >/dev/null'
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
check "pypi-top: missing project warned, rest planned" 'grep -q demo-2.0.tar.gz "$T/fplan" && grep -q "WARN pypi-top: 1 projects" "$T/ferr" && ! grep -q never "$T/fplan"'
printf '900|gh|o/missing||dev-tools|404\n' > "$T/n.tsv"
run plan --tsv "$T/n.tsv" >/dev/null 2>&1; check "nothing resolved, entry failed -> 1" '[ $? -eq 1 ]'

# usage errors are 64
printf '900|nope|x||g|n\n' > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "unknown kind -> 64" '[ $? -eq 64 ]'
printf '900|gh|o/tool|([|g|n\n' > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "bad regex -> 64" '[ $? -eq 64 ]'
printf '900|index|%s/idx/||g|n\n' "$B" > "$T/u.tsv"; run plan --tsv "$T/u.tsv" >/dev/null 2>&1; check "index without a match -> 64" '[ $? -eq 64 ]'
run plan --bogus >/dev/null 2>&1; check "argparse error -> 64" '[ $? -eq 64 ]'
run fetch --tsv "$T/c.tsv" >/dev/null 2>&1; check "fetch without --dest -> 64" '[ $? -eq 64 ]'
run plan --tsv "$T/c.tsv" --group nothing >/dev/null 2>&1; check "filters matching nothing -> 64" '[ $? -eq 64 ]'

# --- fetch ------------------------------------------------------------------------------
D="$T/dest"
run fetch --tsv "$T/c.tsv" --only o/tool --only "$B/idx/" --only s --dest "$D" > "$T/fetch1" 2> "$T/fetch1.err"; rc=$?
check "fetch -> 0" '[ $rc -eq 0 ]' || cat "$T/fetch1.err" >&2
check "files land at their dest" '[ -f "$D/dev-tools/o/tool/v1.0/tool-linux-amd64.tar.gz" ] && [ -f "$D/containers/snap/s/1.0-r7/s_amd64_r7.snap" ]'
check "no .part left behind" '[ -z "$(find "$D" -name "*.part")" ]'
: > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --only "$B/idx/" --only s --dest "$D" > "$T/fetch2" 2>&1
check "second run downloads nothing" '! grep -q " ok	" "$T/fetch2" && ! grep -Eq "^/(f|idx/app|web)/" <(grep -v "releases/latest\|^/idx/ \|SHA256SUMS\|/snap/" "$T/access.log")'

# resume: a partial .part is continued with a Range request
F="$D/dev-tools/o/tool/v1.0/tool-windows.zip"; head -c 100 "$F" > "$F.part"; rm "$F"; : > "$T/access.log"
run fetch --tsv "$T/c.tsv" --only o/tool --dest "$D" >/dev/null 2>&1
check "a .part resumes with Range" 'grep -q "tool-windows.zip bytes=100-" "$T/access.log" && [ "$(wc -c < "$F")" -eq 800 ]'

# digest mismatch: no file, exit 2
printf '900|gh|o/tool|\\.zip$|dev-tools|n\n' > "$T/m.tsv"
python3 -I - "$PY" "$T/m.tsv" "$T/dest2" > "$T/mm.out" 2>&1 <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = m.plan
def tampered(entries):
    rows, f = real(entries)
    return [(u, d, s, "sha256:" + "1" * 64) if d.endswith(".zip") else (u, d, s, g) for u, d, s, g in rows], f
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
m.plan = lambda e: ([("$B/f/tool.sig", "../escape.sig", 400, "")], [])
print("rc", m.main(["fetch", "--tsv", sys.argv[2], "--dest", sys.argv[3]]))
PYEOF
check "dest outside --dest refused -> 2" 'grep -q "rc 2" "$T/esc.out" && [ ! -e "$T/escape.sig" ]'
check "safe() strips path separators from upstream names" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"rm\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
sys.exit(0 if m.row(\"u\",\"g\",\"../..\",\"a/b\")[1]==\"g/_/a-b\" else 1)"'

echo "release-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
