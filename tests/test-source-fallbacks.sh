#!/bin/bash
###############################################################################
# Test: platforms with no upstream binary still get an offline path (scripts/tools/_common.sh
# mirror_source_tarball + build_from_source_hint, data/apt-sets.tsv desktop sets). Offline: a
# local HTTP fixture stands in for the upstream mirrors. Invariants:
#   - mirror_source_tarball tries URLs in order, skips ones that do not answer, stores the
#     release tarball at tools/sources/<tool>-<version>-src/<file> and echoes that path;
#     a second run reuses it; every URL failing is an honest error (non-zero + error count),
#     but a dead earlier mirror recovered by a later one is not counted as a failure
#   - build_from_source_hint names the offline .deb set, the source + build-deps set with the
#     dpkg-buildpackage steps, the mirrored release tarball, the git bundle and the build steps
#   - every tool script whose platform has no upstream build uses the helper (no bare
#     "sudo apt install" hint left for inkscape/blender/kdenlive/kicad/vlc linux)
#   - the git bundles those hints name are in data/source-repos.tsv
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }
. "$ROOT/tests/lib/ports.sh"
T="$(mktemp -d)"; SRV_PID=""
trap 'stop_pids $SRV_PID; rm -rf "${T:?}"' EXIT; trap_signals
PORT="$(free_port)"; B="http://127.0.0.1:$PORT"
mkdir -p "$T/www/rel"; echo "source bytes" > "$T/www/rel/app-1.0.tar.xz"
(cd "$T/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 & SRV_PID=$!
for _ in $(seq 50); do curl -s "$B/" >/dev/null 2>&1 && break; sleep 0.1; done

run() {  # run <bash snippet> : with _common.sh sourced against a throwaway data root
    VAL_ARK_DATA="$T/data" FORCE_COLOR=0 VALARK_DL_RETRIES=1 VALARK_DL_RETRY_DELAY=0 \
        bash -c 'source "'"$ROOT"'/scripts/tools/_common.sh"; '"$1"
}

# 1. fallback order, stored path, echo
OUT=$(run 'p=$(mirror_source_tarball app 1.0 "'"$B"'/missing/app-1.0.tar.xz" "'"$B"'/rel/app-1.0.tar.xz"); rc=$?; echo "RC=$rc P=$p TOOLS=$TOOLS_DIR"' 2>/dev/null)
TOOLS=$(sed -n 's/.* TOOLS=//p' <<<"$OUT")
grep -q "RC=0 P=tools/sources/app-1.0-src/app-1.0.tar.xz " <<<"$OUT" && pass || fail "fallback mirror used, path echoed (got: $OUT)"
[ "$(cat "$TOOLS/sources/app-1.0-src/app-1.0.tar.xz" 2>/dev/null)" = "source bytes" ] && pass || fail "tarball stored under tools/sources/<tool>-<ver>-src/"
# 2. second run reuses the file without fetching
rm -f "$T/www/rel/app-1.0.tar.xz"
OUT=$(run 'p=$(mirror_source_tarball app 1.0 "'"$B"'/rel/app-1.0.tar.xz"); echo "RC=$? P=$p"' 2>/dev/null)
grep -q "RC=0 P=tools/sources/app-1.0-src/app-1.0.tar.xz" <<<"$OUT" && pass || fail "an existing tarball is reused (got: $OUT)"
# 3. every URL failing is an error, never a silent success
OUT=$(run 'mirror_source_tarball app 2.0 "" "'"$B"'/nope/a.tar.xz" >/dev/null; echo "RC=$? E=$_VA_ERRORS"' 2>&1)
grep -q "RC=1 E=1" <<<"$OUT" && grep -q "FAILED: app 2.0 source" <<<"$OUT" && pass || fail "all mirrors failing must log_error + return 1 (got: $OUT)"
# 3b. a dead earlier mirror recovered by the next one is NOT an error (the tool did not fail)
DEAD="http://127.0.0.1:$(free_port)/app-3.0.tar.xz"; echo "v3" > "$T/www/rel/app-3.0.tar.xz"
OUT=$(run 'p=$(mirror_source_tarball app 3.0 "'"$DEAD"'" "'"$B"'/rel/app-3.0.tar.xz"); echo "RC=$? E=$_VA_ERRORS P=$p"; [ -n "$_VA_ERR_FILE" ] && echo "F=$(wc -c < "$_VA_ERR_FILE" 2>/dev/null)"' 2>/dev/null)
grep -q "RC=0 E=0 P=tools/sources/app-3.0-src/app-3.0.tar.xz" <<<"$OUT" && ! grep -q "F=[1-9]" <<<"$OUT" && pass || fail "a recovered mirror failure must not count as an error (got: $OUT)"
# 3c. no URL at all is an error
OUT=$(run 'mirror_source_tarball app 4.0 "" >/dev/null; echo "RC=$?"' 2>&1)
grep -q "RC=1" <<<"$OUT" && grep -q "no source URL" <<<"$OUT" && pass || fail "an empty URL list must be an error (got: $OUT)"

# 3d. a new version's source prunes older <tool>-<ver>-src dirs, never another tool's
mkdir -p "$TOOLS/sources/app-0.9-src" "$TOOLS/sources/app-extra-1-src" "$TOOLS/sources/app-0.8-src"
echo "v5" > "$T/www/rel/app-5.0.tar.xz"
run 'mirror_source_tarball app 5.0 "'"$B"'/rel/app-5.0.tar.xz" >/dev/null' 2>/dev/null
[ -d "$TOOLS/sources/app-5.0-src" ] && [ ! -d "$TOOLS/sources/app-0.9-src" ] && [ ! -d "$TOOLS/sources/app-1.0-src" ] \
    && [ -d "$TOOLS/sources/app-extra-1-src" ] && pass || fail "older source versions pruned, other tools kept ($(ls "$TOOLS/sources" | tr '\n' ' '))"

# 4. the hint text
run 'build_from_source_hint demo "Demo App" linux-arm64 demo-pkg demo tools/sources/demo-1.0-src/demo-1.0.tar.xz owner/demo "  make && make install"' >/dev/null 2>&1
H="$T/data/val-ark/tools/linux-arm64/demo/INSTALL.txt"; [ -f "$H" ] || H="$(find "$T/data" -path '*linux-arm64/demo/INSTALL.txt' | head -1)"
for want in "Demo App - linux-arm64" "--set desktop-apps --set desktop-src --dest" "--arch arm64" "apt-get install demo-pkg" \
            "'desktop-src'" "source/demo/" "apt-get build-dep ./demo_*.dsc" "dpkg-source -x demo_*.dsc" "dpkg-buildpackage" \
            "tools/sources/demo-1.0-src/demo-1.0.tar.xz" "owner/demo.bundle" "make && make install" "release tarball" \
            "Ubuntu noble's version" "may need newer" "1. Install" "2. Rebuild" "3. Upstream source" "4. Full-history"; do
    grep -qF -- "$want" "$H" 2>/dev/null && pass || fail "hint must mention: $want"
done
# build-dep by package NAME fails against a flat repo (no deb-src index): never suggested
! grep -qE "build-dep [a-z]" "$H" && pass || fail "hint must not suggest 'apt-get build-dep <name>'"
! grep -q "software/linux" "$H" && pass || fail "hint must not name a private mirror layout"
run 'build_from_source_hint demo2 "Demo" linux-x86_64 "" "" "" "" ""' >/dev/null 2>&1
H2="$(find "$T/data" -path '*linux-x86_64/demo2/INSTALL.txt' | head -1)"
! grep -q "desktop-apps\|desktop-src\|bundle" "$H2" && grep -q "Online fallback" "$H2" && pass || fail "empty fields leave their sections out"
# no .deb sets (Bambu-like): the source section is number 1 and never mentions desktop-src / build-dep
run 'build_from_source_hint demo3 "Demo3" linux-arm64 "" "" tools/sources/demo3-2-src/v2.tar.gz o/demo3 "  make" archive' >/dev/null 2>&1
H3="$(find "$T/data" -path '*linux-arm64/demo3/INSTALL.txt' | head -1)"
grep -q "^1. Upstream source, tag archive" "$H3" && grep -q "NOT include git submodules" "$H3" && grep -q "^2. Full-history" "$H3" \
    && ! grep -q "desktop-src\|build-dep" "$H3" && pass || fail "a hint without .deb sets numbers from 1 and has no build-dep line ($(head -12 "$H3" | tr '\n' '|'))"

# 5. the scripts use it where upstream ships no build
for f in inkscape blender kdenlive kicad vlc bambu-studio; do
    grep -q "build_from_source_hint" "$ROOT/scripts/tools/$f.sh" && pass || fail "$f.sh must use build_from_source_hint"
    grep -q "mirror_source_tarball" "$ROOT/scripts/tools/$f.sh" && pass || fail "$f.sh must mirror its release source"
done
grep -q 'sudo apt install inkscape' "$ROOT/scripts/tools/inkscape.sh" && fail "inkscape.sh still has the online-only hint" || pass
for f in btop tmux audacity; do grep -q "mirror_source_tarball" "$ROOT/scripts/tools/$f.sh" && pass || fail "$f.sh must mirror its source"; done
# audacity fetches its source only for a platform without a binary (inside the no-binary branch)
awk '/build_from_source_hint audacity/{exit} /mirror_source_tarball audacity/{m=NR} /if \[ -n "\$url" \]; then/{u=NR} END{exit !(m>u && u>0)}' "$ROOT/scripts/tools/audacity.sh" \
    && pass || fail "audacity.sh must mirror source only in the no-binary branch"
grep -q 'kicad_steps" archive' "$ROOT/scripts/tools/kicad.sh" && grep -q 'builds" archive' "$ROOT/scripts/tools/bambu-studio.sh" \
    && pass || fail "forge tag archives (KiCad GitLab, Bambu GitHub) must be marked 'archive'"
grep -q 'libevent' "$ROOT/scripts/tools/tmux.sh" && pass || fail "tmux.sh must mirror libevent (its one non-system library on macOS)"

# 6. the bundles named in hints exist in the source catalog
for r in inkscape/inkscape blender/blender KDE/kdenlive KiCad/kicad-source-mirror videolan/vlc bambulab/BambuStudio \
         audacity/audacity tmux/tmux libevent/libevent aristocratos/btop; do
    grep -q "^[0-9]*|$r|" "$ROOT/data/source-repos.tsv" && pass || fail "data/source-repos.tsv lacks $r"
done

echo "source-fallbacks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
