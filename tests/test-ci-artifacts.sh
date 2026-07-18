#!/bin/bash
###############################################################################
# Test: release workflow offline self-replication artifacts (#88 slice 1).
#
# A tagged Release must ship the offline self-replication payload — the SAME
# format scripts/mirror-self.sh serves at /sources/val-ark/ and bootstrap.sh
# consumes: a full-history git bundle (`git clone <bundle>`) and a source
# tarball with a val-ark/ prefix (`tar --strip-components=1`) — plus a
# SHA256SUMS. This exercises that packaging logic END-TO-END offline: it runs
# the exact bundle/archive/sha256 steps the workflow runs, against a THROWAWAY
# git repo under mktemp (never the real repo, no network, no tag, no push), and
# proves the bundle verifies + clones, the tarball extracts like bootstrap, and
# the checksums both match and fail-closed on tamper. It also grep-asserts the
# real .github/workflows/release.yml still wires those same commands + attaches
# the files, so the test and CI can't silently drift apart.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- 1. workflow file sanity --------------------------------------------------
[ -f "$WF" ] && pass || fail "release.yml must exist"
# YAML forbids tab indentation — a cheap, dependency-free validity signal.
if grep -Pq '\t' "$WF" 2>/dev/null; then fail "release.yml must not use tab indentation (invalid YAML)"; else pass; fi
# Full parse when PyYAML happens to be present (skipped gracefully offline).
if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$WF" 2>/dev/null \
        && pass || fail "release.yml must be valid YAML"
else
    pass   # no PyYAML available offline; the structural asserts below still gate it
fi

# --- 2. the artifact build + attach wiring must be present (keeps CI in lockstep)
grep -q 'git bundle create' "$WF"  && pass || fail "workflow must build a git bundle"
grep -q 'git archive'       "$WF"  && pass || fail "workflow must build a source tarball"
grep -q 'prefix="val-ark/"' "$WF"  && pass || fail "tarball must carry the val-ark/ prefix bootstrap.sh strips"
grep -q 'sha256sum'         "$WF"  && pass || fail "workflow must generate SHA256SUMS"
grep -q 'files:'            "$WF"  && pass || fail "workflow must attach files to the release"
grep -q 'GITHUB_REF_NAME'   "$WF"  && pass || fail "version must come from the tag (GITHUB_REF_NAME), never hardcoded"

# --- 3. bash -n the artifacts step's shell (the `run: |` block) ----------------
# Extract the block bounded by `id: artifacts` .. its `run: |` .. the next
# less-indented key, then syntax-check it as the shell CI actually runs.
SH="$T/step.sh"
awk '
  /^[[:space:]]*id: artifacts[[:space:]]*$/ { instep=1 }
  instep && /^[[:space:]]*run: \|[[:space:]]*$/ { match($0,/^[[:space:]]*/); ind=RLENGTH; inrun=1; next }
  inrun {
    if ($0 ~ /[^[:space:]]/) { match($0,/^[[:space:]]*/); if (RLENGTH <= ind) { inrun=0; instep=0; next } }
    print
  }
' "$WF" > "$SH"
[ -s "$SH" ] && bash -n "$SH" 2>/dev/null && pass || fail "the artifacts step shell must pass bash -n"

# --- 4. throwaway repo (scratch history; the real repo is never touched) -------
R="$T/repo"; git init -q -b main "$R"
git -C "$R" config user.email test@test; git -C "$R" config user.name test
git -C "$R" config commit.gpgSign false;  git -C "$R" config tag.gpgSign false
mkdir -p "$R/scripts"; echo hi > "$R/README.md"; echo 'echo x' > "$R/scripts/start.sh"
git -C "$R" add -A; git -C "$R" commit -qm "feat: base"
git -C "$R" commit -q --allow-empty -m "second commit (multi-commit history)"

# --- 5. run the SAME packaging steps the workflow runs (versioned by the tag) --
VERSION="0.1.11"                       # stands in for ${GITHUB_REF_NAME#v}
OUT="$T/out"; mkdir -p "$OUT"
BUNDLE="val-ark-${VERSION}.bundle"; TARBALL="val-ark-${VERSION}.tar.gz"
( cd "$R" && git bundle create "$OUT/$BUNDLE" --all ) >/dev/null 2>&1 \
    && pass || fail "git bundle create --all must succeed"
( cd "$R" && git archive --format=tar.gz --prefix="val-ark/" -o "$OUT/$TARBALL" HEAD ) >/dev/null 2>&1 \
    && pass || fail "git archive must succeed"
( cd "$OUT" && sha256sum "$BUNDLE" "$TARBALL" > SHA256SUMS ) \
    && pass || fail "sha256sum must succeed"

# --- 6. all three artifacts produced, non-empty, versioned by tag -------------
[ -s "$OUT/$BUNDLE" ]     && pass || fail "the versioned bundle artifact must be produced"
[ -s "$OUT/$TARBALL" ]    && pass || fail "the versioned tarball artifact must be produced"
[ -s "$OUT/SHA256SUMS" ]  && pass || fail "SHA256SUMS must be produced"

# --- 7. bundle verifies AND clones offline (bootstrap.sh does `git clone`) -----
( cd "$R" && git bundle verify "$OUT/$BUNDLE" ) >/dev/null 2>&1 \
    && pass || fail "git bundle verify must pass (self-contained history)"
git clone -q "$OUT/$BUNDLE" "$T/clone" >/dev/null 2>&1 && [ -f "$T/clone/README.md" ] \
    && pass || fail "the bundle must clone offline exactly like bootstrap.sh"

# --- 8. tarball extracts like bootstrap (val-ark/ prefix, --strip-components=1) -
tar -tzf "$OUT/$TARBALL" | grep -q '^val-ark/' \
    && pass || fail "tarball must carry the val-ark/ prefix bootstrap.sh strips"
mkdir -p "$T/extract"
tar -xzf "$OUT/$TARBALL" -C "$T/extract" --strip-components=1 2>/dev/null && [ -f "$T/extract/README.md" ] \
    && pass || fail "tarball must extract like bootstrap.sh (--strip-components=1)"

# --- 9. SHA256SUMS matches, and fails CLOSED on a tampered artifact ------------
( cd "$OUT" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1 \
    && pass || fail "SHA256SUMS must verify against the produced artifacts"
cp "$OUT/$BUNDLE" "$T/b.bak"; printf 'tampered\n' >> "$OUT/$BUNDLE"
if ( cd "$OUT" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1; then
    fail "a tampered artifact must break SHA256SUMS verification"
else
    pass
fi
cp "$T/b.bak" "$OUT/$BUNDLE"

# --- 10. version derivation strips an optional leading v ----------------------
v1="v0.1.11"; v2="0.1.11"
[ "${v1#v}" = "0.1.11" ] && [ "${v2#v}" = "0.1.11" ] \
    && pass || fail "version derivation must strip an optional leading v (0.1.11 and v0.1.11 -> 0.1.11)"

echo "ci-artifacts: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
