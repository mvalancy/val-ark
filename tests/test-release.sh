#!/bin/bash
###############################################################################
# Test: release.sh tag scheme + VERSION single-source guard (#64).
#
# The shipped tag series is UNPREFIXED (0.1.7, 0.1.8, 0.1.9) and the repo-root
# VERSION file is the single source of truth for the app version. This drives
# scripts/release.sh against throwaway git repos under mktemp — every tag and
# every push lands only in the scratch repos (a local bare "origin"), NEVER in
# the project repo or on any real remote.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RS="$ROOT/scripts/release.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Scratch repo factory: main branch, identity set, VERSION=0.1.9 committed and
# tagged 0.1.9 (annotated, like a real prior release), then a release commit
# bumping VERSION to 0.1.10. Takes a unique name, prints the repo path.
# (Runs in a $() subshell, so it cannot bump a parent-scope counter itself.)
mkrepo() {
    local r="$T/$1"
    git init -q -b main "$r"
    git -C "$r" config user.email test@test
    git -C "$r" config user.name test
    git -C "$r" config tag.gpgSign false
    git -C "$r" config commit.gpgSign false
    echo "0.1.9" > "$r/VERSION"; echo "hello" > "$r/app.txt"
    git -C "$r" add -A; git -C "$r" commit -qm "feat: base"
    git -C "$r" tag -a 0.1.9 -m "Release 0.1.9"
    echo "0.1.10" > "$r/VERSION"
    git -C "$r" add -A; git -C "$r" commit -qm "chore(version): bump VERSION to 0.1.10"
    echo "$r"
}
# Run release.sh with CWD inside a scratch repo (it resolves the repo + VERSION
# from the CWD's git toplevel). Captures stdout+stderr into $OUT.
run_rs() { local r="$1"; shift; OUT="$( cd "$r" && bash "$RS" "$@" 2>&1 )"; }

# --- 1. no-arg run derives the UNPREFIXED tag from the VERSION file -----------
R=$(mkrepo r1)
if run_rs "$R"; then pass; else fail "release.sh with no args must succeed off the VERSION file: $OUT"; fi
[ "$(git -C "$R" tag -l 0.1.10)" = "0.1.10" ] && pass || fail "must create unprefixed tag 0.1.10"
[ -z "$(git -C "$R" tag -l v0.1.10)" ] && pass || fail "must NOT mint a v-prefixed tag"
git -C "$R" cat-file -t refs/tags/0.1.10 2>/dev/null | grep -q tag && pass || fail "tag must be annotated"

# --- 2. changelog baseline = nearest ANCESTOR tag, not highest-sorted ---------
echo "$OUT" | grep -q "(since 0.1.9)" && pass || fail "changelog baseline must be the prior release 0.1.9"
R=$(mkrepo r2)   # off-lineage tag that version-sorts above everything
git -C "$R" branch side HEAD~1
git -C "$R" -c core.hooksPath=/dev/null worktree add -q "$T/side2" side
( cd "$T/side2" && echo x > x.txt && git add -A && git commit -qm "side" && git tag -a 9.9.9 -m off )
run_rs "$R" || fail "release must succeed despite an off-lineage tag: $OUT"
echo "$OUT" | grep -q "(since 0.1.9)" && pass || fail "off-lineage tag 9.9.9 must not become the changelog baseline"

# --- 3. explicit version arg: must match VERSION file; leading v stripped -----
R=$(mkrepo r3)
if run_rs "$R" 0.1.10; then pass; else fail "matching explicit version must be accepted: $OUT"; fi
R=$(mkrepo r4)
run_rs "$R" v0.1.10 || fail "v-prefixed arg must be normalized, not rejected: $OUT"
[ "$(git -C "$R" tag -l 0.1.10)" = "0.1.10" ] && [ -z "$(git -C "$R" tag -l v0.1.10)" ] \
    && pass || fail "v0.1.10 arg must still mint unprefixed 0.1.10"
R=$(mkrepo r5)
if run_rs "$R" 9.9.9; then fail "version arg disagreeing with VERSION file must die"; else pass; fi
[ -z "$(git -C "$R" tag -l 9.9.9)" ] && pass || fail "no tag may be created on a VERSION mismatch"

# --- 4. clean-tree: tracked changes block, untracked files do NOT -------------
R=$(mkrepo r6)
echo "junk" > "$R/scratch.tmp"; mkdir -p "$R/.memsearch"; echo x > "$R/.memsearch/i"
if run_rs "$R"; then pass; else fail "untracked files must not block a release: $OUT"; fi
R=$(mkrepo r7)
echo "dirty" >> "$R/app.txt"
if run_rs "$R"; then fail "uncommitted tracked changes must block a release"; else pass; fi
[ -z "$(git -C "$R" tag -l 0.1.10)" ] && pass || fail "no tag may be created on a dirty tracked tree"

# --- 5. double-release refused under either prefix scheme ---------------------
R=$(mkrepo r8)
git -C "$R" tag -a 0.1.10 -m existing
if run_rs "$R"; then fail "existing tag 0.1.10 must be refused"; else pass; fi
R=$(mkrepo r9)
git -C "$R" tag -a v0.1.10 -m stray
if run_rs "$R"; then fail "stray v0.1.10 must be refused (mixed-scheme guard)"; else pass; fi

# --- 6. malformed / missing VERSION file dies before tagging ------------------
R=$(mkrepo r10)
echo "0.1" > "$R/VERSION"; git -C "$R" commit -qam "bad version"
if run_rs "$R"; then fail "non-X.Y.Z VERSION content must die"; else pass; fi
R=$(mkrepo r11)
git -C "$R" rm -q VERSION; git -C "$R" commit -qm "drop VERSION"
if run_rs "$R"; then fail "missing VERSION file must die"; else pass; fi

# --- 7. --push (as sole arg) pushes the tag to origin — a LOCAL bare repo -----
R=$(mkrepo r12)
git init -q --bare "$T/origin12.git"
git -C "$R" remote add origin "$T/origin12.git"
if run_rs "$R" --push; then pass; else fail "release.sh --push must tag from VERSION and push: $OUT"; fi
[ "$(git -C "$T/origin12.git" tag -l 0.1.10)" = "0.1.10" ] && pass || fail "--push must push the tag to origin"
# without --push nothing is pushed
R=$(mkrepo r13)
git init -q --bare "$T/origin13.git"
git -C "$R" remote add origin "$T/origin13.git"
run_rs "$R"
[ -z "$(git -C "$T/origin13.git" tag -l)" ] && pass || fail "without --push no tag may reach origin"

echo "release: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
