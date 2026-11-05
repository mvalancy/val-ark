#!/bin/bash
###############################################################################
# Test: the cad-agent reference archive (scripts/tools/cad-agent-references.sh,
# scripts/lib/references_mirror.py) and verify.sh's integrity check.
#
# All offline: a fixture index (17 records), local git repos reached through
# git's url.insteadOf (so https://github.com/... resolves to a local bare repo),
# a local HTTP server (pages, PDFs, 304s, 403, 404, robots.txt, redirects, a
# fake GitHub API) and a stub monolith. Invariants:
#   - every licence class is ARCHIVED (owner, 2026-11-04); `redistribute` is true
#     only for open and share-alike, and a licence change relabels without refetching
#   - repos are full-history bundles (every branch and tag) that `git clone` restores;
#     two records of one repo share one blob; LFS use is recorded
#   - content addressing: identical bytes are stored once; by-id/<id>.<ext> points
#     at the latest copy; a changed source keeps the old blob
#   - --max-repo-mb keeps a pointer only (before cloning when the size is known,
#     after fetching otherwise); no cap by default
#   - 403/429 and robots.txt -> blocked, 404 -> gone, no URL -> no-url, bad ids rejected
#   - a rerun is idempotent (no new lines, no page requests); --refresh sends
#     If-None-Match (304 -> unchanged) and ls-remote (same refs -> unchanged)
#   - the planner orders the work and a budget defers it; the dry run fetches only the index
#   - verify passes, then fails on a missing, truncated or altered blob
#   - the store is outside every tree server.js serves, and counts in the footprint
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/references_mirror.py"
SH="$ROOT/scripts/tools/cad-agent-references.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: no git" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
trap 'rm -rf "${T:?}"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
export VAL_ARK_CONFIG="$T/empty.conf" VAL_ARK_DATA="$T/disk" FORCE_COLOR=0 VALARK_REFS_HOST_INTERVAL=0
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset GITHUB_TOKEN VALARK_MONOLITH VALARK_REFS_DIR VALARK_REFS_INDEX
: > "$VAL_ARK_CONFIG"; mkdir -p "$VAL_ARK_DATA" "$T/git/acme" "$T/site/refs"
printf '[url "file://%s/git/"]\n\tinsteadOf = https://github.com/\n[init]\n\tdefaultBranch = main\n' "$T" > "$GIT_CONFIG_GLOBAL"
# Pull a JSON field: j FILE-or-'-' EXPR (python expression over d)
# Lists/tuples print space-separated, dicts as sorted k=v pairs, so checks compare plain words.
j() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]) if sys.argv[1] != "-" else sys.stdin); v=eval(sys.argv[2])
print(" ".join("%s=%s" % kv for kv in sorted(v.items())) if isinstance(v, dict) else " ".join(map(str, v)) if isinstance(v, (list, tuple)) else v)' "$@"; }
# The latest manifest line of an id, as JSON
line() { grep "\"id\":\"$2\"" "$1/manifest.jsonl" | tail -1; }

# --- 0. scripts parse ----------------------------------------------------------
check "cad-agent-references.sh must be valid bash" 'bash -n "$SH"'
check "references_mirror.py must compile" 'python3 -m py_compile "$PY"'
check "verify.sh must be valid bash" 'bash -n "$ROOT/scripts/verify.sh"'

# --- 1. fixture repos ----------------------------------------------------------
mkrepo() {   # name -> bare repo at $T/git/acme/<name>.git, work tree at $T/w/<name>
    git init -q "$T/w/$1" && git init -q --bare "$T/git/acme/$1.git"
    git -C "$T/w/$1" remote add origin "$T/git/acme/$1.git"
}
mkrepo widget
echo one > "$T/w/widget/README.md"; echo '*.stl filter=lfs diff=lfs merge=lfs -text' > "$T/w/widget/.gitattributes"
git -C "$T/w/widget" add -A && git -C "$T/w/widget" commit -qm first
echo two >> "$T/w/widget/README.md"; git -C "$T/w/widget" commit -qam second; git -C "$T/w/widget" tag v1
git -C "$T/w/widget" checkout -qb feature; echo f > "$T/w/widget/f.txt"; git -C "$T/w/widget" add f.txt
git -C "$T/w/widget" commit -qm feature; git -C "$T/w/widget" checkout -q main
git -C "$T/w/widget" push -q origin main feature v1 2>/dev/null
git -C "$T/git/acme/widget.git" symbolic-ref HEAD refs/heads/main
mkrepo bigrepo
head -c 2500000 /dev/urandom > "$T/w/bigrepo/noise.bin"
git -C "$T/w/bigrepo" add -A && git -C "$T/w/bigrepo" commit -qm noise && git -C "$T/w/bigrepo" push -q origin main 2>/dev/null

# --- 2. fixture HTTP server ----------------------------------------------------
cat > "$T/server.py" <<'EOF'
import http.server, os, sys, json
ROOT = sys.argv[1]
PDF = b"%PDF-1.4\n% fixture\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body=b"", ctype="text/html; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        p = self.path.split("?")[0]
        host = (self.headers.get("Host") or "").split(":")[0]
        with open(os.path.join(ROOT, "http.log"), "a") as fh:
            fh.write("%s %s %s\n" % (p, self.headers.get("If-None-Match") or "-", self.headers.get("User-Agent")))
        if p.startswith("/refs/"):
            f = os.path.join(ROOT, "site", p.lstrip("/"))
            return self.send(200, open(f, "rb").read(), "application/json") if os.path.isfile(f) else self.send(404)
        if p == "/robots.txt" and host == "localhost":
            return self.send(503, b"down")
        if p == "/truncated":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "5000")
            self.end_headers()
            self.wfile.write(b"only 13 bytes")
            self.close_connection = True
            return
        if p.startswith("/monolith/"):
            return self.send(200, b"not the real monolith", "application/octet-stream")
        if p == "/robots.txt":
            return self.send(200, b"User-agent: *\nDisallow: /private/\n", "text/plain")
        if p in ("/guide.html", "/guide-nc.html"):
            ver = open(os.path.join(ROOT, "guide.ver")).read().strip()
            etag = '"%s"' % ver
            if self.headers.get("If-None-Match") == etag:
                return self.send(304, b"", extra={"ETag": etag})
            return self.send(200, b"<!doctype html><html><head><title>Guide</title></head><body>hole for M3: 4.0 mm "
                             + ver.encode() + b"</body></html>", extra={"ETag": etag, "Last-Modified": "Tue, 14 May 2024 10:21:00 GMT"})
        if p in ("/doc.pdf", "/doc-copy"):
            return self.send(200, PDF, "application/pdf")
        if p == "/feed.json":
            return self.send(200, b'{"rows": [1, 2]}', "application/json")
        if p == "/forbidden":
            return self.send(403, b"no", extra={"Retry-After": "3600"})
        if p == "/moved":
            return self.send(301, b"", extra={"Location": "/guide.html"})
        if p == "/big.bin":
            return self.send(200, b"x" * (2 * 1024 * 1024 + 10), "application/octet-stream")
        if p == "/private/page.html":
            return self.send(200, b"<html>secret</html>")
        if p.startswith("/api/repos/acme/"):
            name = p.rsplit("/", 1)[1]
            sizes = {"widget": 40, "huge": 999999, "bigrepo": 10}
            if name in sizes:
                return self.send(200, json.dumps({"size": sizes[name], "default_branch": "main",
                                                  "license": {"spdx_id": "MIT"}}).encode(), "application/json")
        return self.send(404, b"not here")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(ROOT, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
echo v1 > "$T/guide.ver"
python3 "$T/server.py" "$T" & SRV_PID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port"); H="http://127.0.0.1:$PORT"
export VALARK_REFS_GITHUB_API="$H/api"

# --- 3. fixture index ------------------------------------------------------------
write_index() {   # $1 = licence class of record "guide"
python3 - "$T/site/refs" "$H" "$1" <<'EOF'
import json, sys, os
out, H, guide_lic = sys.argv[1], sys.argv[2], sys.argv[3]
R = lambda i, url, lic, kind="project", ev="snippet-only", st="catalogued", **k: dict(
    id=i, title=i, url=url, status=st, kind=kind, licence=lic, licence_read=False, evidence=ev, areas=["a"], **k)
recs = [
    R("widget", "https://github.com/acme/widget", "open"),
    R("widget-docs", "https://github.com/acme/widget/tree/main/docs", "unclear", kind="guide"),
    R("bigrepo", "https://github.com/acme/bigrepo", "share-alike"),
    R("huge", "https://github.com/acme/huge", "open"),
    R("gone-repo", "https://github.com/acme/gone-repo", "unclear"),
    R("guide", H + "/guide.html", guide_lic, kind="guide", ev="read", st="source"),
    R("guide-nc", H + "/guide-nc.html", "non-commercial", kind="guide"),
    R("datasheet", H + "/doc.pdf", "proprietary", kind="datasheet"),
    R("datasheet-copy", H + "/doc-copy", "unrecorded", kind="source", st="source", ev="read"),
    R("feed", H + "/feed.json", "proprietary", kind="vendor-table"),
    R("forbidden", H + "/forbidden", "proprietary", kind="guide"),
    R("missing", H + "/missing", "unclear", kind="guide"),
    R("robots-private", H + "/private/page.html", "open", kind="guide"),
    R("moved", H + "/moved", "open", kind="guide"),
    R("bigfile", H + "/big.bin", "open", kind="guide"),
    R("book", None, "unrecorded", kind="source", st="source", ev="read", isbn="978-0-000-00000-0"),
    R("../evil", H + "/guide.html", "open"),
]
idx = {"schema": "cad-agent-references/1", "built": "2026-11-04", "revision": "f" * 40,
       "areas": [{"slug": "a", "json": "https://example.invalid/catalog/references/a.json"}],
       "records": "https://example.invalid/catalog/references/records.json"}
json.dump(idx, open(os.path.join(out, "index.json"), "w"))
json.dump({"schema": "cad-agent-references/1", "count": len(recs), "records": recs}, open(os.path.join(out, "records.json"), "w"))
json.dump({"schema": "cad-agent-references/1", "area": {"slug": "a"}, "records": recs[:2]}, open(os.path.join(out, "a.json"), "w"))
EOF
}
write_index proprietary
IDX="$H/refs/index.json"
cat > "$T/monolith" <<'EOF'
#!/bin/bash
# stub monolith: -o OUT ... -  (reads stdin) -> writes a marked single file
[ "$1" = -V ] && { echo "monolith stub"; exit 0; }
out=""; base=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -b) base="$2"; shift ;; esac; shift; done
{ echo "<!-- single-file of ${base} -->"; cat; } > "$out"
EOF
chmod +x "$T/monolith"
S1="$T/store"
mirror() { python3 "$PY" mirror --store "$S1" --index "$IDX" --monolith "$T/monolith" --max-file-mb 1 "$@"; }

# --- 4. the dry run reads only the index ------------------------------------------
: > "$T/http.log"
python3 "$PY" plan --index "$IDX" --max-repo-mb 100 --show 50 > "$T/plan.json" 2>"$T/plan.err"
check "plan exits 0" '[ $? = 0 ]'
check "plan counts 16 valid records" '[ "$(j "$T/plan.json" "d[\"records\"]")" = 16 ]'
check "plan rejects the traversal id" '[ "$(j "$T/plan.json" "d[\"rejected_ids\"]")" = "../evil" ]'
check "plan classifies 5 repos, 1 pdf by name" '[ "$(j "$T/plan.json" "d[\"actions\"]")" = "fetch:git=5 fetch:page=9 fetch:pdf=1 no-url:none=1" ]'
check "plan: redistribute true for open/share-alike only (6 of 16)" '[ "$(j "$T/plan.json" "d[\"redistribute\"][\"true\"]")" = 6 ]'
check "plan: two records of one repo are estimated once" '[ "$(j "$T/plan.json" "[w[\"bytes\"] for w in d[\"first\"] if w[\"id\"]==\"widget-docs\"][0]")" = 0 ]'
check "plan fetches nothing but the index" '! grep -qv "^/refs/" "$T/http.log"'
python3 "$PY" plan --index "$IDX" --github-sizes --max-repo-mb 100 > "$T/plan2.json" 2>/dev/null
check "plan --github-sizes sizes a repo from the API" '[ "$(j "$T/plan2.json" "d[\"largest_repos\"][0]")" = "bytes=1023998976 id=huge" ]'
check "plan --max-repo-mb counts repos over the cap" '[ "$(j "$T/plan2.json" "d[\"repos_over_cap\"]")" = 1 ]'
python3 "$PY" plan --index "$IDX" --budget 1 > "$T/plan3.json" 2>/dev/null
check "a 1-byte budget defers every paid item (a second record of a repo goes with its repo)" '[ "$(j "$T/plan3.json" "d[\"deferred_over_budget\"]")" = 15 ]'
check "the planner still lists the free no-url note" '[ "$(j "$T/plan3.json" "d[\"planned\"]")" = 1 ]'
python3 "$PY" plan --index "$T/missing.json" >/dev/null 2>&1
check "an unreadable index exits 2" '[ $? = 2 ]'
echo '{"schema": "something-else/1"}' > "$T/wrong.json"
python3 "$PY" plan --index "$T/wrong.json" >/dev/null 2>&1
check "a foreign schema exits 2" '[ $? = 2 ]'

# --- 5. first mirror ---------------------------------------------------------------
: > "$T/http.log"
GITHUB_TOKEN=fixture mirror --max-repo-mb 1 > "$T/run1.json" 2>"$T/run1.err"
check "mirror exits 0" '[ $? = 0 ]'
check "statuses of the first run" '[ "$(j "$T/run1.json" "d[\"statuses\"]")" = "archived=8 blocked=2 gone=2 no-url=1 too-large=3" ]' \
    || cat "$T/run1.err" >&2
for id in widget widget-docs guide guide-nc datasheet datasheet-copy feed moved; do
    check "$id archived" '[ "$(line "$S1" $id | j - "d[\"status\"]")" = archived ]'
done
check "every line carries the manifest schema fields" 'python3 - "$S1/manifest.jsonl" <<EOF
import json, sys
need = {"v", "id", "url", "method", "status", "fetched", "licence_class", "licence_read", "redistribute", "index_revision"}
arch = {"kind", "sha256", "bytes", "blob", "link", "tool"}
for l in open(sys.argv[1]):
    e = json.loads(l)
    assert need <= set(e), (e["id"], need - set(e))
    if e["status"] == "archived":
        assert arch <= set(e), (e["id"], arch - set(e))
    assert e["v"] == 1 and e["index_revision"] == "f" * 40
EOF'
# Licence -> redistribute; every class archived
for pair in widget:True widget-docs:False bigrepo:True guide:False guide-nc:False datasheet:False datasheet-copy:False feed:False moved:True; do
    check "redistribute ${pair%%:*} = ${pair##*:}" '[ "$(line "$S1" ${pair%%:*} | j - "d[\"redistribute\"]")" = ${pair##*:} ]'
done
check "a proprietary page is archived, not link-only" '[ -s "$S1/$(line "$S1" guide | j - "d[\"blob\"]")" ]'
# Git: full history bundle, shared by both records of the repo
WSHA=$(line "$S1" widget | j - 'd["sha256"]')
check "two records of one repo share one bundle" '[ "$(line "$S1" widget-docs | j - "d[\"sha256\"]")" = "$WSHA" ]'
check "the bundle is content-addressed" '[ -f "$S1/blobs/${WSHA:0:2}/$WSHA.bundle" ] && [ "$(sha256sum "$S1/blobs/${WSHA:0:2}/$WSHA.bundle" | cut -d" " -f1)" = "$WSHA" ]'
git clone -q "$S1/by-id/widget.bundle" "$T/restored" 2>/dev/null
check "git clone of by-id/widget.bundle restores main" '[ "$(git -C "$T/restored" rev-parse HEAD)" = "$(git -C "$T/w/widget" rev-parse main)" ]'
check "the bundle holds every branch and tag" 'git -C "$T/restored" rev-parse -q --verify origin/feature >/dev/null && git -C "$T/restored" rev-parse -q --verify v1 >/dev/null'
check "the bundle holds full history" '[ "$(git -C "$T/restored" rev-list --count HEAD)" = 2 ]'
check "manifest commit = HEAD, ref = main, refs = 3" '[ "$(line "$S1" widget | j - "(d[\"commit\"], d[\"ref\"], d[\"refs\"])")" = "$(git -C "$T/w/widget" rev-parse main) refs/heads/main 3" ]'
check "LFS use is recorded" '[ "$(line "$S1" widget | j - "d[\"lfs\"]")" = True ]'
check "repo size from the API is recorded" '[ "$(line "$S1" widget | j - "d[\"repo_kb\"]")" = 40 ]'
# Size cap: before cloning (API size) and after fetching (no API entry)
check "huge: too-large from the API size, never cloned" '[ "$(line "$S1" huge | j - "(d[\"status\"], d[\"repo_kb\"], d.get(\"blob\"))")" = "too-large 999999 None" ]'
check "bigrepo: too-large after the fetch, no blob kept" '[ "$(line "$S1" bigrepo | j - "(d[\"status\"], d[\"cap_mb\"], d.get(\"blob\"))")" = "too-large 1 None" ] && [ ! -e "$S1/by-id/bigrepo.bundle" ]'
check "gone-repo: gone" '[ "$(line "$S1" gone-repo | j - "d[\"status\"]")" = gone ]'
# Pages and files
check "html via monolith, single file of the final URL" '[ "$(line "$S1" guide | j - "(d[\"kind\"], d[\"tool\"])")" = "html monolith" ] && grep -q "single-file of $H/guide.html" "$S1/by-id/guide.html"'
check "ETag and Last-Modified recorded" '[ "$(line "$S1" guide | j - "d[\"etag\"]")" = "\"v1\"" ] && line "$S1" guide | grep -q "Tue, 14 May 2024"'
check "pdf kept as served" '[ "$(line "$S1" datasheet | j - "(d[\"kind\"], d[\"tool\"])")" = "pdf urllib" ] && head -c 5 "$S1/by-id/datasheet.pdf" | grep -q "%PDF-"'
check "a PDF without .pdf in its URL is found by its bytes" '[ "$(line "$S1" datasheet-copy | j - "d[\"kind\"]")" = pdf ]'
check "identical bytes are stored once" '[ "$(line "$S1" datasheet | j - "d[\"blob\"]")" = "$(line "$S1" datasheet-copy | j - "d[\"blob\"]")" ]'
check "a JSON feed is a file with its extension" '[ "$(line "$S1" feed | j - "(d[\"kind\"], d[\"blob\"][-5:])")" = "file .json" ]'
check "a redirect records its final URL" '[ "$(line "$S1" moved | j - "d[\"final_url\"]")" = "$H/guide.html" ]'
check "403 -> blocked with Retry-After" '[ "$(line "$S1" forbidden | j - "(d[\"status\"], d[\"retry_after\"])")" = "blocked 3600" ]'
check "404 -> gone" '[ "$(line "$S1" missing | j - "d[\"status\"]")" = gone ]'
check "robots.txt disallow -> blocked, page never requested" '[ "$(line "$S1" robots-private | j - "d[\"error\"]")" = "disallowed by robots.txt" ] && ! grep -q "^/private/" "$T/http.log"'
check "over --max-file-mb -> too-large" '[ "$(line "$S1" bigfile | j - "d[\"status\"]")" = too-large ]'
check "no url -> no-url" '[ "$(line "$S1" book | j - "d[\"status\"]")" = no-url ]'
check "the traversal id never reaches the store" '! ls -a "$S1/by-id" "$T" | grep -q evil && [ "$(j "$T/run1.json" "d[\"rejected_ids\"]")" = "../evil" ]'
check "the project UA is sent" 'grep -q "val-ark-references/1" "$T/http.log"'
check "the index is snapshotted for offline mining" '[ -s "$S1/index/index.json" ] && [ -s "$S1/index/records.json" ] && [ -s "$S1/index/a.json" ]'
check "by-id links are relative" '[ "$(readlink "$S1/by-id/guide.html" | cut -c1-9)" = "../blobs/" ]'
check "latest lists one archived entry per id" '[ "$(python3 "$PY" latest --store "$S1" | wc -l)" = 8 ]'

# --- 6. rerun is idempotent ----------------------------------------------------------
N1=$(wc -l < "$S1/manifest.jsonl"); : > "$T/http.log"
mkdir -p "$S1/tmp/git-killed"; touch "$S1/tmp/http-killed"
mirror --max-repo-mb 1 > "$T/run2.json" 2>/dev/null
check "a rerun clears a killed run's temporary files" '[ -z "$(ls -A "$S1/tmp")" ]'
check "rerun adds no manifest lines" '[ "$(wc -l < "$S1/manifest.jsonl")" = "$N1" ]'
check "rerun requests nothing but the index" '! grep -qv "^/refs/" "$T/http.log"'
check "rerun reports everything idle" '[ "$(j "$T/run2.json" "(d[\"done\"], d[\"idle\"])")" = "0 16" ]'

# --- 7. refresh: 304 and unchanged refs keep the copy; a new commit adds a blob --------
: > "$T/http.log"
mirror --refresh > "$T/run3.json" 2>/dev/null
check "refresh: the page answers 304 -> unchanged, same blob" '[ "$(line "$S1" guide | j - "(d[\"status\"], d[\"http_status\"])")" = "unchanged 304" ] && [ "$(line "$S1" guide | j - "d[\"sha256\"]")" = "$(grep "\"id\":\"guide\"" "$S1/manifest.jsonl" | head -1 | j - "d[\"sha256\"]")" ]'
check "refresh sends If-None-Match" 'grep -q "^/guide.html \"v1\"" "$T/http.log"'
check "refresh: same refs -> unchanged without a fetch" '[ "$(line "$S1" widget | j - "(d[\"status\"], d[\"sha256\"])")" = "unchanged $WSHA" ]'
check "refresh without a cap archives bigrepo" '[ "$(line "$S1" bigrepo | j - "d[\"status\"]")" = archived ]'
echo three >> "$T/w/widget/README.md"; git -C "$T/w/widget" commit -qam third; git -C "$T/w/widget" push -q origin main 2>/dev/null
echo v2 > "$T/guide.ver"
mirror --refresh > "$T/run4.json" 2>/dev/null
W2=$(line "$S1" widget | j - 'd["sha256"]')
check "a new commit makes a new bundle" '[ "$(line "$S1" widget | j - "d[\"status\"]")" = archived ] && [ "$W2" != "$WSHA" ]'
check "the old bundle is kept as evidence" '[ -f "$S1/blobs/${WSHA:0:2}/$WSHA.bundle" ]'
check "by-id follows the newest copy" '[ "$(sha256sum "$(readlink -f "$S1/by-id/widget.bundle")" | cut -d" " -f1)" = "$W2" ]'
check "the new bundle has the new commit" 'git clone -q "$S1/by-id/widget.bundle" "$T/restored2" 2>/dev/null && [ "$(git -C "$T/restored2" rev-list --count HEAD)" = 3 ]'
check "a changed page is a new blob" '[ "$(line "$S1" guide | j - "d[\"status\"]")" = archived ] && grep -q " v2" "$S1/by-id/guide.html"'

# --- 8. a licence change relabels without refetching ------------------------------------
write_index open; N1=$(wc -l < "$S1/manifest.jsonl"); OLD=$(line "$S1" guide); : > "$T/http.log"
mirror > "$T/run5.json" 2>/dev/null
check "relabelled: redistribute now true, same blob, same fetch time" '[ "$(line "$S1" guide | j - "(d[\"status\"], d[\"redistribute\"], d[\"licence_class\"])")" = "relabelled True open" ] && [ "$(line "$S1" guide | j - "d[\"sha256\"], d[\"fetched\"]")" = "$(echo "$OLD" | j - "d[\"sha256\"], d[\"fetched\"]")" ]'
check "relabelling requests no page" '! grep -q "^/guide" "$T/http.log"'
check "relabelling adds exactly one line" '[ "$(wc -l < "$S1/manifest.jsonl")" = $((N1 + 1)) ]'

# --- 9. a lock holder blocks a second run ----------------------------------------------
( exec 9>"$S1/.lock"; flock 9; sleep 3 ) & LK=$!; sleep 0.5
mirror >/dev/null 2>&1; check "a second mirror exits 3 while the lock is held" '[ $? = 3 ]'
wait "$LK" 2>/dev/null

# --- 10. without monolith pages are raw HTML -------------------------------------------
python3 "$PY" mirror --store "$T/store2" --index "$IDX" --monolith "" > /dev/null 2>&1
check "no monolith -> raw-html" '[ "$(line "$T/store2" guide | j - "d[\"tool\"]")" = raw-html ] && ! grep -q single-file "$T/store2/by-id/guide.html"'

# --- 11. verify ------------------------------------------------------------------------
python3 "$PY" verify --store "$S1" --sample 100 --bundles 10 > "$T/v1.json"
check "verify passes on a good store" '[ $? = 0 ] && [ "$(j "$T/v1.json" "d[\"ok\"]")" = True ]'
check "verify ran git bundle verify" '[ "$(j "$T/v1.json" "d[\"bundles_verified\"]")" -ge 2 ]'
PDFB="$S1/$(line "$S1" datasheet | j - 'd["blob"]')"; cp "$PDFB" "$T/pdf.bak"
printf 'X' | dd of="$PDFB" bs=1 seek=3 conv=notrunc 2>/dev/null
python3 "$PY" verify --store "$S1" --sample 100 --bundles 0 > "$T/v2.json"
check "verify fails on an altered blob (sha256)" '[ $? = 1 ] && grep -q "sha256 mismatch" "$T/v2.json"'
echo extra >> "$PDFB"
python3 "$PY" verify --store "$S1" --sample 0 --bundles 0 > "$T/v3.json"
check "verify fails on a size mismatch without hashing" '[ $? = 1 ] && grep -q "manifest says" "$T/v3.json"'
cp "$T/pdf.bak" "$PDFB"
BB="$S1/$(line "$S1" bigrepo | j - 'd["blob"]')"; cp "$BB" "$T/b.bak"; truncate -s 2000 "$BB"
python3 "$PY" verify --store "$S1" --sample 0 --bundles 0 > /dev/null
check "verify fails on a truncated bundle" '[ $? = 1 ]'
cp "$T/b.bak" "$BB"
# verify.sh's function, extracted and run in a harness with verify.sh's own chk/bad
HV="$T/harness.sh"
{
    echo 'PASS=0; FAIL=0; chk(){ PASS=$((PASS+1)); echo "PASS $*"; }; bad(){ FAIL=$((FAIL+1)); echo "FAIL $*"; }'
    echo "_LIB='$ROOT/scripts/lib'"
    awk '/^verify_cad_agent_references\(\) \{/,/^\}/' "$ROOT/scripts/verify.sh"
    echo 'verify_cad_agent_references "$1"; exit $FAIL'
} > "$HV"
check "harness holds the real function" 'grep -q "references_mirror.py\" verify" "$HV"'
OUT=$(bash "$HV" "$S1"); check "verify.sh PASSES a good store" '[ $? = 0 ] && echo "$OUT" | grep -q "^PASS cad-agent references integrity: 9 copies"' || echo "$OUT" >&2
rm -f "$PDFB"
OUT=$(bash "$HV" "$S1"); check "verify.sh FAILS a missing blob, naming it" '[ $? = 1 ] && echo "$OUT" | grep -q "datasheet: blob missing"'
cp "$T/pdf.bak" "$PDFB"
OUT=$(bash "$HV" "$T/nothing"); check "verify.sh is silent with no store" '[ $? = 0 ] && [ -z "$OUT" ]'

# --- 12. the tool script ---------------------------------------------------------------
export VALARK_RESERVE_MIN_GB=0 VALARK_RESERVE_PCT=0 VALARK_MONOLITH=""
OUT=$(bash "$SH" --dry-run --index "$IDX" 2>&1)
check "tool --dry-run prints the plan" 'echo "$OUT" | grep -q "\"to_do\": 16"' || echo "$OUT" >&2
check "the dry run creates no store" '! [ -e "$VAL_ARK_DATA/val-ark/private" ]'
OUT=$(bash "$SH" --index "$IDX" 2>&1); RC=$?
check "tool run exits 0 (blocked/gone are warnings, not failures)" '[ $RC = 0 ]' || echo "$OUT" >&2
check "tool run stores under <home>/private/cad-agent-references" '[ -s "$VAL_ARK_DATA/val-ark/private/cad-agent-references/manifest.jsonl" ]'
check "tool run warns about blocked sources" 'echo "$OUT" | grep -q "refuse automated fetches"'
check "tool run rejects a non-numeric cap" '! bash "$SH" --max-repo-mb lots --index "$IDX" >/dev/null 2>&1'
OUT=$(bash "$SH" --index "$T/missing.json" 2>&1)
check "tool run fails honestly on an unreadable index" '[ $? != 0 ] && echo "$OUT" | grep -q "could not be read"'
check "private/ counts in the footprint" '( . "$ROOT/scripts/lib/valark-env.sh"; [ "$PRIVATE_DIR" = "$VAL_ARK_DATA/val-ark/private" ] && [ "$(valark_data_used_bytes)" -gt 0 ] )'
check ".gitignore keeps private/ out of git" 'grep -qx "/private" "$ROOT/.gitignore"'


# --- 13. one bad item never stops a run --------------------------------------------
mkindex() {   # dir, python list of (id, url, licence) -> $T/site/<dir>/{index,records}.json
python3 - "$T/site/$1" "$2" <<'EOF2'
import json, os, sys
out, recs = sys.argv[1], eval(sys.argv[2])
os.makedirs(out, exist_ok=True)
rs = [dict(id=i, title=i, url=u, status="catalogued", kind="guide", licence=l, licence_read=False,
           evidence="snippet-only", areas=["a"]) for i, u, l in recs]
json.dump({"schema": "cad-agent-references/1", "revision": "e" * 40, "areas": []}, open(os.path.join(out, "index.json"), "w"))
json.dump({"schema": "cad-agent-references/1", "count": len(rs), "records": rs}, open(os.path.join(out, "records.json"), "w"))
EOF2
}
mkindex bad "[('a-space', '$H/a b.html', 'open'), ('page-ok', '$H/guide.html', 'open'),
  ('slow', 'https://github.com/acme/slow', 'open'), ('w2', 'https://github.com/acme/widget', 'open'),
  ('trunc', '$H/truncated', 'open'), ('robots-5xx', 'http://localhost:$PORT/guide.html', 'open')]"
REALGIT=$(command -v git); mkdir -p "$T/fakebin"
cat > "$T/fakebin/git" <<EOF2
#!/bin/bash
case " \$* " in *" ls-remote "*slow*) exec sleep 30 ;; esac
[ -n "\${FAKE_GIT_SLOW_BUNDLE:-}" ] && [ "\$1" = bundle ] && [ "\$2" = create ] && exec sleep 30
exec "$REALGIT" "\$@"
EOF2
chmod +x "$T/fakebin/git"
printf '<html>not runnable</html>\n' > "$T/noexec-mono"   # no x bit: like a noexec mount
printf '#!/bin/bash\nexec sleep 30\n' > "$T/hang-mono"; chmod +x "$T/hang-mono"
S4="$T/store4"
PATH="$T/fakebin:$PATH" python3 "$PY" mirror --store "$S4" --index "$T/site/bad/index.json" --monolith "$T/noexec-mono" \
    --git-timeout 3 > "$T/bad1.json" 2>"$T/bad1.err"
check "a run with bad items exits 0" '[ $? = 0 ]' || cat "$T/bad1.err" >&2
check "every item got a line" '[ "$(j "$T/bad1.json" "d[\"done\"]")" = 6 ]'
check "a URL with a space -> failed, recorded" '[ "$(line "$S4" a-space | j - "d[\"status\"]")" = failed ] && line "$S4" a-space | grep -q InvalidURL'
check "git ls-remote timeout -> failed, recorded" '[ "$(line "$S4" slow | j - "d[\"status\"]")" = failed ] && line "$S4" slow | grep -q "ls-remote timed out"'
check "the run went on: the repo after them archived" '[ "$(line "$S4" w2 | j - "d[\"status\"]")" = archived ]'
check "a non-executable monolith falls back to raw HTML" '[ "$(line "$S4" page-ok | j - "(d[\"status\"], d[\"tool\"])")" = "archived raw-html" ] && line "$S4" page-ok | grep -q "cannot run"'
check "a truncated body (Content-Length) is never stored" '[ "$(line "$S4" trunc | j - "(d[\"status\"], d[\"error\"])")" = "failed truncated: 13 of 5000 bytes" ]'
check "robots.txt answering 5xx -> blocked" '[ "$(line "$S4" robots-5xx | j - "(d[\"status\"], d[\"error\"])")" = "blocked robots.txt unreachable (503)" ]'
N4=$(wc -l < "$S4/manifest.jsonl")
python3 "$PY" mirror --store "$S4" --index "$T/site/bad/index.json" --monolith "" > /dev/null 2>&1
check "a failed item waits --retry-hours before a retry" '[ "$(wc -l < "$S4/manifest.jsonl")" = "$N4" ]'
PATH="$T/fakebin:$PATH" python3 "$PY" mirror --store "$S4" --index "$T/site/bad/index.json" --monolith "" --retry-hours 0 --git-timeout 3 > /dev/null 2>&1
check "--retry-hours 0 retries the failed items" '[ "$(wc -l < "$S4/manifest.jsonl")" = $((N4 + 3)) ]'
python3 "$PY" mirror --store "$T/store5" --index "$T/site/bad/index.json" --monolith "$T/hang-mono" --monolith-timeout 1 \
    --git-timeout 3 > /dev/null 2>&1
check "a hanging monolith times out and falls back to raw HTML" '[ "$(line "$T/store5" page-ok | j - "d[\"tool\"]")" = raw-html ] && line "$T/store5" page-ok | grep -q "timed out after 1s"'
FAKE_GIT_SLOW_BUNDLE=1 PATH="$T/fakebin:$PATH" python3 "$PY" mirror --store "$T/store6" --index "$T/site/bad/index.json" \
    --monolith "" --git-timeout 3 > /dev/null 2>&1
check "git bundle timeout -> failed, recorded, temp cleaned" '[ "$(line "$T/store6" w2 | j - "d[\"status\"]")" = failed ] && line "$T/store6" w2 | grep -q "bundle timed out" && [ -z "$(ls -A "$T/store6/tmp")" ]'

# --- 14. the budget is enforced on bytes written ----------------------------------------
# mirror() passes --store "$S1"; the later --store wins.
GITHUB_TOKEN=fixture mirror --store "$T/store7" --budget 1000000 > "$T/b1.json" 2>"$T/b1.err"
check "a repo larger than the budget left stops the run" 'j "$T/b1.json" "d[\"stopped\"]" | grep -q "budget reached: bigrepo needs"' || cat "$T/b1.json" >&2
check "nothing over budget is written" '[ "$(j "$T/b1.json" "d[\"added_bytes\"]")" -le 1000000 ] && ! grep -q "\"id\":\"bigrepo\"" "$T/store7/manifest.jsonl" && [ -z "$(ls -A "$T/store7/tmp")" ]'
check "the tool says why it stopped" 'grep -q "references: stopped, budget reached" "$T/b1.err"'
mkindex big "[('bigfile', '$H/big.bin', 'open')]"
python3 "$PY" mirror --store "$T/store8" --index "$T/site/big/index.json" --monolith "" --budget 2097160 > "$T/b2.json" 2>/dev/null
check "a file larger than the budget left stops the run, nothing kept" 'j "$T/b2.json" "d[\"stopped\"]" | grep -q "budget reached: bigfile" && [ ! -s "$T/store8/manifest.jsonl" ] && [ -z "$(ls "$T/store8/blobs")" ]'
python3 "$PY" mirror --store "$T/store8" --index "$T/site/big/index.json" --monolith "" --budget 0 > "$T/b3.json" 2>/dev/null
check "a zero budget fetches nothing" '[ "$(j "$T/b3.json" "d[\"done\"]")" = 0 ]'

# --- 15. manifest: a torn last line is skipped, then dropped ----------------------------
printf '{"v":1,"id":"torn","sta' >> "$S1/manifest.jsonl"
python3 "$PY" verify --store "$S1" --sample 0 --bundles 0 > "$T/v4.json"
check "verify warns on a torn last line and still passes" '[ $? = 0 ] && grep -q "torn last line" "$T/v4.json"'
mirror > /dev/null 2>"$T/torn.err"
check "the next mirror run drops the torn line" 'grep -q "dropped a torn last manifest line" "$T/torn.err" && python3 -c "import json,sys; [json.loads(l) for l in open(sys.argv[1])]" "$S1/manifest.jsonl"'
python3 "$PY" verify --store "$S1" --sample 0 --bundles 0 > "$T/v5.json"
check "verify is clean after the repair" '[ $? = 0 ] && [ "$(j "$T/v5.json" "d[\"warnings\"]")" = "" ]'

# --- 16. an index may not point at local files --------------------------------------------
mkdir -p "$T/evil"; echo '{"secret": 1}' > "$T/secret.json"
echo "{\"schema\": \"cad-agent-references/1\", \"records\": \"file://$T/site/refs/records.json\"}" > "$T/evil/index.json"
python3 "$PY" plan --index "$T/evil/index.json" >/dev/null 2>&1
check "records named as file:// are refused" '[ $? = 2 ]'
mkindex evil2 "[('book2', None, 'open')]"
python3 - "$T/site/evil2/index.json" "$T/secret.json" <<'EOF2'
import json, sys
d = json.load(open(sys.argv[1])); d["areas"] = [{"slug": "zz", "json": "file://" + sys.argv[2]}, {"slug": "yy", "json": sys.argv[2]}]
json.dump(d, open(sys.argv[1], "w"))
EOF2
python3 "$PY" mirror --store "$T/store9" --index "$T/site/evil2/index.json" --monolith "" > /dev/null 2>&1
check "area files named as local paths are never read" '[ ! -e "$T/store9/index/zz.json" ] && [ ! -e "$T/store9/index/yy.json" ] && [ -s "$T/store9/index/records.json" ]'

# --- 17. opt-in: not in `all`, not one click ----------------------------------------------
check "download-tools.sh list (and so all) leaves it out" '! bash "$ROOT/scripts/download-tools.sh" list 2>/dev/null | grep -q cad-agent-references && bash "$ROOT/scripts/download-tools.sh" list 2>/dev/null | grep -q "  cad-agent$"'
check "the web UI cannot start it" 'grep -q "f !== .cad-agent-references.sh." "$ROOT/scripts/server.js"'

# --- 18. monolith: pinned sha256, and a binary that cannot run is not used ----------------
if [ "$(uname -s)/$(uname -m)" = Linux/x86_64 ]; then
    OUT=$(env -u VALARK_MONOLITH VALARK_DL_RETRIES=1 VALARK_REFS_DIR="$T/store10" VALARK_MONOLITH_BASE_URL="$H/monolith" PATH="/usr/bin:/bin" \
        bash -c 'source "$1"; refs_monolith' _ "$SH" 2>&1)
    check "a monolith download with the wrong sha256 is refused and deleted" 'echo "$OUT" | grep -q "is not the pinned" && [ ! -e "$T/store10/.bin/monolith-v2.12.0" ]' || echo "$OUT" >&2
fi
check "a binary that cannot execute is not used" '! bash -c "source \"\$1\"; refs_runs \"\$2\"" _ "$SH" "$T/noexec-mono" && bash -c "source \"\$1\"; refs_runs \"\$2\"" _ "$SH" "$T/monolith"'

# --- 19. the store is never served ----------------------------------------------------------
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
if [ -n "$NODE" ] && command -v curl >/dev/null 2>&1; then
    MADE_PRIVATE=0; [ -e "${ROOT:?}/private" ] || MADE_PRIVATE=1
    PD="${ROOT:?}/private/refs-test-$$"; mkdir -p "$PD"; echo SECRET > "$PD/copy.html"
    SP=3962; B="http://127.0.0.1:$SP"
    env VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
        VALARK_WEB_PORT="$SP" VALARK_HTTPS_PORT="$((SP + 9000))" VALARK_STATE_DIR="$T/srvstate" \
        "$NODE" "$ROOT/scripts/server.js" "$SP" >"$T/srv.log" 2>&1 &
    NPID=$!
    up=0; for _ in $(seq 1 30); do sleep 0.4; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
    if [ "$up" = 1 ]; then
        R="private/refs-test-$$/copy.html"
        for u in "/$R" "/api/archive/$R" "/api/archive/private/refs-test-$$" "/tools/../$R" "/tools/..%2f$R" "/%2e%2e/$R" "/sources/%2e%2e/$R"; do
            code=$(curl -s -o "$T/served" -w '%{http_code}' --path-as-is --max-time 5 "$B$u")
            check "server.js does not serve $u (got $code)" '[ "$code" != 200 ] && ! grep -q SECRET "$T/served"'
        done
    else
        fail "server.js did not start on :$SP"
    fi
    kill "$NPID" 2>/dev/null
    rm -f "${PD:?}/copy.html"; rmdir "${PD:?}"
    [ "$MADE_PRIVATE" = 1 ] && rmdir "${ROOT:?}/private"
else
    echo "  SKIP: served-tree check (no node or curl)" >&2
fi

echo "cad-agent-references: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
