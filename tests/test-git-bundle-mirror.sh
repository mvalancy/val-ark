#!/bin/bash
###############################################################################
# Test: scripts/lib/git_bundle_mirror.py (offline, file:// fixture remote).
#
#  * data/source-repos.tsv parses; repos unique (case-insensitive).
#  * chunked shallow->deepen fetch yields FULL history (forced via tiny chunks).
#  * a pre-existing shallow staging dir is RESUMED, not thrown away.
#  * bundle restores with `git clone`, keeps branches + tags, drops refs/pull/*.
#  * .source.json sha256 matches the bundle; INDEX.txt lists it; verify passes.
#  * a failing remote marks the repo failed (exit 2) without killing the run.
#  * a refresh seeds from the existing bundle and fetches only new objects;
#    a corrupt old bundle falls back to the full fetch (#179).
#  * unchanged upstream refs skip the rebuild + re-copy; a failing incremental
#    fetch falls back to the chunked path; a rebuilt bundle that fails verify
#    never replaces the archived one.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
M="$ROOT/scripts/lib/git_bundle_mirror.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# 1. catalog
python3 - "$ROOT/data/source-repos.tsv" <<'EOF' && pass || fail "source-repos.tsv schema"
import sys
sys.path.insert(0, sys.argv[1].rsplit("/data/", 1)[0] + "/scripts/lib")
import git_bundle_mirror as g
rows = g.load_catalog(sys.argv[1])
names = [r["repo"].lower() for r in rows]
assert len(rows) > 100 and len(names) == len(set(names)), "duplicates or too few rows"
assert all(0 <= r["value"] <= 1000 for r in rows)
for must in ("torvalds/linux", "php/php-src", "mariadb/server", "apache/httpd", "nginx/nginx"):
    assert must in names, must
EOF

# Fixture remote: 40 commits on main, 3 on a side branch, a tag, and a fake pull ref.
mkdir -p "$T/remote/acme"
git init -q -b main "$T/work"
for i in $(seq 1 40); do echo "$i" > "$T/work/f"; git -C "$T/work" add f; git -C "$T/work" commit -qm "c$i"; done
git -C "$T/work" tag v1.0 HEAD~10
git -C "$T/work" checkout -qb side; for i in 1 2 3; do echo "s$i" > "$T/work/s"; git -C "$T/work" add s; git -C "$T/work" commit -qm "s$i"; done
git -C "$T/work" checkout -q main
git clone -q --bare "$T/work" "$T/remote/acme/widget.git"
git -C "$T/remote/acme/widget.git" update-ref refs/pull/1/head "$(git -C "$T/work" rev-parse side)"

export VALARK_GIT_BASE="file://$T/remote" VALARK_GIT_BIG_KB=0 VALARK_GIT_DEEPEN=7
run() { python3 "$M" mirror --dest "$T/dest" --stage "$T/stage" --tries 1 --retry-wait 0 "$@"; }

# 2. chunked mirror -> full history
run --repo acme/widget 2>"$T/log1" && pass || fail "mirror failed: $(cat "$T/log1")"
B="$T/dest/acme/widget.bundle"
[ -f "$B" ] && pass || fail "bundle not written"
git clone -q "$B" "$T/restored" 2>/dev/null && pass || fail "bundle does not clone"
[ "$(git -C "$T/restored" rev-list --count HEAD 2>/dev/null)" = "40" ] && pass || fail "history not complete after deepen chunks"
git -C "$T/restored" rev-parse -q --verify v1.0 >/dev/null && pass || fail "tag missing"
git -C "$T/restored" rev-parse -q --verify origin/side >/dev/null && pass || fail "side branch missing"
git bundle list-heads "$B" | grep -q 'refs/pull/' && fail "refs/pull leaked into bundle" || pass
[ ! -e "$T/stage/acme__widget.git" ] && pass || fail "staging not cleaned after success"

# 3. provenance + index + verify
python3 - "$B" <<'EOF' && pass || fail ".source.json sha256/head mismatch"
import hashlib, json, subprocess, sys
b = sys.argv[1]; meta = json.load(open(b + ".source.json"))
assert meta["sha256"] == hashlib.sha256(open(b, "rb").read()).hexdigest()
assert meta["bytes"] > 0 and meta["default_branch"] == "main" and len(meta["head_commit"]) == 40
EOF
grep -q '^acme/widget	' "$T/dest/INDEX.txt" && pass || fail "INDEX.txt missing repo"
python3 "$M" verify --dest "$T/dest" 2>/dev/null && pass || fail "verify rejected a good bundle"

# 4. resume: leave a shallow partial in staging, then mirror again (forced refresh)
rm -rf "$T/dest2"; mkdir -p "$T/stage2"
git init -q --bare "$T/stage2/acme__widget.git"
git -C "$T/stage2/acme__widget.git" remote add origin "$VALARK_GIT_BASE/acme/widget.git"
git -C "$T/stage2/acme__widget.git" config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
git -C "$T/stage2/acme__widget.git" fetch -q --depth=3 origin
[ -f "$T/stage2/acme__widget.git/shallow" ] || fail "fixture: partial not shallow"
python3 "$M" mirror --dest "$T/dest2" --stage "$T/stage2" --tries 1 --retry-wait 0 --repo acme/widget 2>/dev/null && pass || fail "resume run failed"
python3 -c "import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s['acme/widget'].get('resumed') else 1)" \
    "$T/dest2/.mirror-state.json" && pass || fail "shallow staging was not resumed"
git clone -q "$T/dest2/acme/widget.bundle" "$T/restored2" 2>/dev/null
[ "$(git -C "$T/restored2" rev-list --count HEAD 2>/dev/null)" = "40" ] && pass || fail "resumed mirror lacks full history"

# 5. a missing remote fails that repo only (exit 2), state records the failure
run --repo acme/missing 2>/dev/null; rc=$?
[ "$rc" = "2" ] && pass || fail "missing remote should exit 2 (got $rc)"
python3 -c "import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s['acme/missing']['status']=='failed' and s['acme/widget']['status']=='complete' else 1)" \
    "$T/dest/.mirror-state.json" && pass || fail "failure not recorded / good repo state lost"

# 6. a corrupt bundle is caught by verify
mkdir -p "$T/dest3/x"; echo junk > "$T/dest3/x/y.bundle"
python3 "$M" verify --dest "$T/dest3" 2>/dev/null && fail "verify accepted a corrupt bundle" || pass

# 7. resume keeps tags (fixture partial had heads only)
git -C "$T/restored2" rev-parse -q --verify v1.0 >/dev/null && pass || fail "tags missing after resume"

# 8. a failing destination copy keeps the built bundle; the retry only re-copies.
rm -rf "$T/dest4" "$T/stage4"; mkdir -p "$T/dest4/acme/widget.bundle.part"   # a dir where the .part file goes
python3 "$M" mirror --dest "$T/dest4" --stage "$T/stage4" --tries 1 --retry-wait 0 --repo acme/widget 2>/dev/null
[ $? = 2 ] && [ -f "$T/stage4/acme__widget.bundle" ] && pass || fail "failed copy must keep the staged bundle"
rmdir "$T/dest4/acme/widget.bundle.part"
python3 "$M" mirror --dest "$T/dest4" --stage "$T/stage4" --tries 1 --retry-wait 0 --repo acme/widget 2>/dev/null && \
python3 -c "import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s['acme/widget']['status']=='complete' and s['acme/widget']['resumed'] else 1)" \
    "$T/dest4/.mirror-state.json" && [ ! -e "$T/stage4/acme__widget.bundle" ] && pass || fail "copy retry did not reuse the staged bundle"

# 9. renamed upstream (API full_name differs): written once under the API name, then skipped.
python3 - "$ROOT/scripts/lib" "$T" <<'PY' && pass || fail "renamed repo is re-mirrored or indexed under the wrong name"
import os, sys, json
sys.path.insert(0, sys.argv[1]); T = sys.argv[2]
import git_bundle_mirror as g
os.makedirs(T + "/remote/Acme", exist_ok=True)
os.system(f"cp -r {T}/remote/acme/widget.git {T}/remote/Acme/Widget.git")
g.repo_info = lambda n: dict(full_name="Acme/Widget", size=0, default_branch="main", html_url="x")
calls = []
orig = g.mirror_one
g.mirror_one = lambda *a, **k: (calls.append(a[0]), orig(*a, **k))[1]
args = ["mirror", "--dest", T + "/dest5", "--stage", T + "/stage5", "--tries", "1", "--retry-wait", "0", "--repo", "acme/widget"]
assert g.main(args) == 0 and g.main(args) == 0
assert calls == ["Acme/Widget"], calls                      # second run skipped
assert os.path.isfile(T + "/dest5/Acme/Widget.bundle")
assert "Acme/Widget\t" in open(T + "/dest5/INDEX.txt").read()
PY

# 10. unsafe names are refused; verify on an empty dest is not a pass.
python3 "$M" mirror --dest "$T/dest6" --stage "$T/stage6" --tries 1 --retry-wait 0 --repo ../evil 2>/dev/null; [ $? = 2 ] && [ ! -e "$T/evil.bundle" ] && pass || fail "unsafe repo name accepted"
mkdir -p "$T/empty"; python3 "$M" verify --dest "$T/empty" 2>/dev/null && fail "verify passed with zero bundles" || pass

# 11. a failed refresh keeps the previous good bundle listed (and owner/.github-style names are allowed).
python3 - "$ROOT/scripts/lib" "$T" <<'PY' && pass || fail "failed refresh hid a good bundle"
import sys, json
sys.path.insert(0, sys.argv[1]); T = sys.argv[2]
import git_bundle_mirror as g
g.safe_name("acme/.github")
def boom(*a, **k): raise RuntimeError("network down")
g.mirror_one = boom
assert g.main(["mirror", "--dest", T + "/dest", "--stage", T + "/stage", "--tries", "1", "--retry-wait", "0",
               "--refresh-days", "0", "--repo", "acme/widget"]) == 2
st = json.load(open(T + "/dest/.mirror-state.json"))["acme/widget"]
assert st["status"] == "complete" and st["last_error"].endswith("network down"), st
assert "acme/widget\t" in open(T + "/dest/INDEX.txt").read()
PY
for bad in ../evil acme/.. ./x; do python3 -c "import sys;sys.path.insert(0,'$ROOT/scripts/lib');import git_bundle_mirror as g
try: g.safe_name('$bad'); sys.exit(1)
except ValueError: pass" && pass || fail "unsafe name $bad accepted"; done

# 12. incremental refresh (#179): seeded from the archived bundle, upstream sends only new objects.
R="$T/remote/acme/widget.git"
git -C "$T/work" checkout -q main; echo 41 > "$T/work/f"; git -C "$T/work" commit -qam c41
git -C "$T/work" push -q "$R" main
git -C "$R" branch -D side >/dev/null; git -C "$R" tag v2.0 main
GIT_TRACE_PACKET="$T/trace12" run --refresh-days 0 --repo acme/widget 2>"$T/log12" && pass || fail "incremental refresh failed: $(cat "$T/log12")"
python3 -c "import json,sys;s=json.load(open(sys.argv[1]))['acme/widget'];sys.exit(0 if s['status']=='complete' and s.get('incremental') else 1)" \
    "$T/dest/.mirror-state.json" && pass || fail "refresh was not seeded from the existing bundle"
# Seeded: one negotiation that advertises the history we hold; no shallow/deepen chunk walk.
grep -q 'fetch> have ' "$T/trace12" && ! grep -q 'fetch> deepen' "$T/trace12" && pass || fail "refresh refetched history from upstream"
rm -rf "$T/r12"; git clone -q "$B" "$T/r12" 2>/dev/null
[ "$(git -C "$T/r12" rev-list --count HEAD 2>/dev/null)" = "41" ] && pass || fail "incremental bundle lacks the new commit"
git -C "$T/r12" rev-parse -q --verify v2.0 >/dev/null && git -C "$T/r12" rev-parse -q --verify v1.0 >/dev/null && pass || fail "tags lost/missing after incremental refresh"
git -C "$T/r12" rev-parse -q --verify origin/side >/dev/null && fail "branch deleted upstream survived the refresh" || pass
python3 "$M" verify --dest "$T/dest" 2>/dev/null && pass || fail "incremental bundle does not verify"
python3 - "$B" <<'EOF2' && pass || fail ".source.json stale after incremental refresh"
import hashlib, json, sys
b = sys.argv[1]; meta = json.load(open(b + ".source.json"))
assert meta["sha256"] == hashlib.sha256(open(b, "rb").read()).hexdigest()
EOF2
[ ! -e "$T/stage/acme__widget.git" ] && pass || fail "staging not cleaned after incremental refresh"

# 13. a corrupt archived bundle falls back to the full fetch (and is replaced by a good one).
echo junk > "$B"
run --refresh-days 0 --repo acme/widget 2>"$T/log13" && pass || fail "fallback refresh failed: $(cat "$T/log13")"
python3 -c "import json,sys;s=json.load(open(sys.argv[1]))['acme/widget'];sys.exit(0 if s['status']=='complete' and not s.get('incremental') else 1)" \
    "$T/dest/.mirror-state.json" && pass || fail "corrupt bundle was not a full-fetch fallback"
rm -rf "$T/r13"; git clone -q "$B" "$T/r13" 2>/dev/null
[ "$(git -C "$T/r13" rev-list --count HEAD 2>/dev/null)" = "41" ] && pass || fail "fallback bundle lacks full history"

# 14. unchanged upstream (ls-remote == bundle list-heads): no rebuild, no re-copy.
ino0=$(stat -c '%i %Y %s' "$B"); sum0=$(sha256sum < "$B"); touch -d '2 days ago' "$B"; m0=$(stat -c %Y "$B")
run --refresh-days 0 --repo acme/widget 2>"$T/log14" && pass || fail "unchanged refresh failed: $(cat "$T/log14")"
python3 -c "import json,sys;s=json.load(open(sys.argv[1]))['acme/widget'];sys.exit(0 if s['status']=='complete' and s.get('unchanged') and s['bytes']>0 and len(s['head'])==40 else 1)" \
    "$T/dest/.mirror-state.json" && pass || fail "unchanged upstream not recorded as unchanged"
[ "$(stat -c %Y "$B")" = "$m0" ] && [ "$(sha256sum < "$B")" = "$sum0" ] && pass || fail "unchanged upstream still rewrote the bundle"
grep -q '^acme/widget	' "$T/dest/INDEX.txt" && [ ! -e "$T/stage/acme__widget.git" ] && pass || fail "unchanged: index lost or staging left"
# A moved tag is a change: must rebuild, not short-circuit.
git -C "$R" tag -f v1.0 main >/dev/null
run --refresh-days 0 --repo acme/widget 2>/dev/null
python3 -c "import json,sys;s=json.load(open(sys.argv[1]))['acme/widget'];sys.exit(0 if s['status']=='complete' and not s.get('unchanged') else 1)" \
    "$T/dest/.mirror-state.json" && [ "$(git bundle list-heads "$B" | awk '$2=="refs/tags/v1.0"{print $1}')" = "$(git -C "$R" rev-parse main)" ] \
    && pass || fail "a moved tag was treated as unchanged"

# 15. the single incremental fetch keeps failing -> chunked shallow/deepen fallback, same run.
echo 42 > "$T/work/f"; git -C "$T/work" commit -qam c42; git -C "$T/work" push -q "$R" main
python3 - "$ROOT/scripts/lib" "$T" <<'PY' && pass || fail "failing incremental fetch did not fall back to the chunked path"
import json, subprocess, sys
sys.path.insert(0, sys.argv[1]); T = sys.argv[2]
import git_bundle_mirror as g
g.repo_info = lambda n: dict(full_name="acme/widget", size=1, default_branch="main", html_url="x")
calls, real = [], g.git
def flaky(local, *args, **k):
    calls.append(args)
    if args[:4] == ("fetch", "--quiet", "--prune", "origin"):
        raise RuntimeError("fetch: early EOF")
    return real(local, *args, **k)
g.git = flaky
assert g.main(["mirror", "--dest", T + "/dest", "--stage", T + "/stage", "--tries", "6", "--retry-wait", "0",
               "--refresh-days", "0", "--repo", "acme/widget"]) == 0
st = json.load(open(T + "/dest/.mirror-state.json"))["acme/widget"]
assert st["status"] == "complete" and not st["incremental"], st
incr = [c for c in calls if c[:4] == ("fetch", "--quiet", "--prune", "origin")]
assert len(incr) == 1, calls          # flaky() is one call; real retries are bounded inside git()
assert any("--depth=1" in c for c in calls), calls
out = subprocess.run(["git", "bundle", "list-heads", T + "/dest/acme/widget.bundle"], capture_output=True, text=True).stdout
head = subprocess.run(["git", "-C", T + "/remote/acme/widget.git", "rev-parse", "main"], capture_output=True, text=True).stdout.strip()
assert head + " refs/heads/main" in out, out
PY
python3 -c "import sys;sys.path.insert(0,'$ROOT/scripts/lib');import git_bundle_mirror as g;sys.exit(0 if 1<=g.INCR_TRIES<=3 else 1)" \
    && pass || fail "incremental fetch must get only a few tries before falling back"
rm -rf "$T/r15"; git clone -q "$B" "$T/r15" 2>/dev/null
[ "$(git -C "$T/r15" rev-list --count HEAD 2>/dev/null)" = "42" ] && pass || fail "fallback bundle lacks full history"

# 16. a rebuilt bundle that fails `git bundle verify` never replaces the archived one.
echo 43 > "$T/work/f"; git -C "$T/work" commit -qam c43; git -C "$T/work" push -q "$R" main
python3 - "$ROOT/scripts/lib" "$T" <<'PY' && pass || fail "a broken rebuilt bundle replaced the good archived bundle"
import hashlib, json, os, subprocess, sys
sys.path.insert(0, sys.argv[1]); T = sys.argv[2]
import git_bundle_mirror as g
g.repo_info = lambda n: dict(full_name="acme/widget", size=0, default_branch="main", html_url="x")
B = T + "/dest/acme/widget.bundle"
before = hashlib.sha256(open(B, "rb").read()).hexdigest()
real = subprocess.run
def run(cmd, *a, **k):  # the post-build verify (git -C <staging> bundle verify) reports a corrupt bundle
    if isinstance(cmd, list) and cmd[:1] == ["git"] and "-C" in cmd and cmd[3:5] == ["bundle", "verify"]:
        return subprocess.CompletedProcess(cmd, 1, "", "error: simulated corrupt bundle")
    return real(cmd, *a, **k)
g.subprocess.run = run
assert g.main(["mirror", "--dest", T + "/dest", "--stage", T + "/stage", "--tries", "1", "--retry-wait", "0",
               "--refresh-days", "0", "--repo", "acme/widget"]) == 2
assert hashlib.sha256(open(B, "rb").read()).hexdigest() == before
assert not os.path.exists(B + ".part") and not os.path.exists(T + "/stage/acme__widget.bundle")
st = json.load(open(T + "/dest/.mirror-state.json"))["acme/widget"]
assert st["status"] == "complete" and "bundle verify" in st["last_error"], st
PY

echo "git-bundle-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
