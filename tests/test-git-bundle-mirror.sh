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

echo "git-bundle-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
