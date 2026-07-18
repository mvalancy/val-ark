#!/bin/bash
###############################################################################
# Test: bootstrap.sh's post-setup hand-off guidance (epic #90 slice 1).
#
# Confirms the "bootstrap finished → running box the owner can open" hand-off is
# ACCURATE and safe:
#   - the data disk autodetects, so the hand-off must NOT tell the owner to
#     hand-edit .env when it doesn't apply (only when data would land on the
#     system/boot disk);
#   - it prints the CORRECT start command — `./start.sh serve` (plain
#     `./start.sh` opens an interactive menu, not the web server);
#   - it prints the exact first-boot wizard URL with the configured port;
#   - re-running bootstrap is idempotent and makes NO network calls.
#
# Fully offline: sources bootstrap.sh as a library (VALARK_BOOTSTRAP_LIB=1) to
# unit-test the pure helpers, and runs the WHOLE installer against a stubbed
# checkout (fake curl/git, stub setup.sh) — NO network, NO real setup, NO server.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BS="$ROOT/bootstrap.sh"; export BS
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

[ -f "$BS" ] || { echo "SKIP: bootstrap.sh not found" >&2; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Source bootstrap in library mode (installer stops at the sentinel) and run a
# snippet against its helpers — a fresh shell each time, so state can't leak.
run_lib() { VALARK_BOOTSTRAP_LIB=1 bash -c '. "$BS"; '"$1"; }

# ---------------------------------------------------------------------------
# 0. Library mode must NOT run the installer (no host given → no Usage/exit 1).
# ---------------------------------------------------------------------------
if run_lib 'declare -F bootstrap_handoff >/dev/null'; then pass; else fail "lib mode loads helpers without running installer"; fi

# ---------------------------------------------------------------------------
# 1. Port parser (pure): reads VALARK_WEB_PORT, ignores comments/junk, else 3000.
# ---------------------------------------------------------------------------
[ "$(run_lib 'bootstrap_port_from_env /no/such/.env')" = 3000 ] && pass || fail "missing .env → default port 3000"
printf 'VALARK_WEB_PORT=8080\n'      > "$T/env1"; [ "$(run_lib "bootstrap_port_from_env '$T/env1'")" = 8080 ] && pass || fail "VALARK_WEB_PORT=8080 parsed"
printf '# VALARK_WEB_PORT=9999\n'    > "$T/env2"; [ "$(run_lib "bootstrap_port_from_env '$T/env2'")" = 3000 ] && pass || fail "commented port ignored → 3000"
printf 'VALARK_WEB_PORT="7000"\n'    > "$T/env3"; [ "$(run_lib "bootstrap_port_from_env '$T/env3'")" = 7000 ] && pass || fail "quoted port parsed"
printf 'VALARK_WEB_PORT=nope\n'      > "$T/env4"; [ "$(run_lib "bootstrap_port_from_env '$T/env4'")" = 3000 ] && pass || fail "non-numeric port → 3000"

# ---------------------------------------------------------------------------
# 2. OS-volume verdict (pure): 1 = data would fill the system disk, 0 = data disk.
# ---------------------------------------------------------------------------
[ "$(run_lib 'bootstrap_on_os_vol /repo /repo sA sA')"       = 1 ] && pass || fail "DATA_ROOT == PROJECT_ROOT → on OS volume"
[ "$(run_lib 'bootstrap_on_os_vol /mnt/d /repo sDisk sRoot')" = 0 ] && pass || fail "separate disk, distinct df source → data disk"
[ "$(run_lib 'bootstrap_on_os_vol /data /repo sRoot sRoot')" = 1 ] && pass || fail "same df source as / → on OS volume"
[ "$(run_lib 'bootstrap_on_os_vol /mnt/d /repo "" sRoot')"  = 0 ] && pass || fail "empty df source is not treated as system disk"

# ---------------------------------------------------------------------------
# 3. Hand-off, AUTODETECT branch (on_os_vol=0): honest — no bogus .env step.
# ---------------------------------------------------------------------------
OUT="$(run_lib 'bootstrap_handoff /opt/val-ark 3000 0 localhost')"
echo "$OUT" | grep -q 'detected automatically'                     && pass || fail "autodetect branch states the disk was detected"
echo "$OUT" | grep -q 'VAL_ARK_DATA'                               && fail "autodetect branch must NOT tell owner to edit .env" || pass
echo "$OUT" | grep -qF 'cd /opt/val-ark && ./start.sh serve'       && pass || fail "autodetect branch prints correct start command (serve)"
echo "$OUT" | grep -qF 'http://localhost:3000'                     && pass || fail "autodetect branch prints the wizard URL"
# guard against the OLD misleading line: a bare ./start.sh billed as 'starts the web UI'
echo "$OUT" | grep -qE '\./start\.sh +\(starts the web UI\)'       && fail "old bare ./start.sh instruction resurfaced" || pass

# ---------------------------------------------------------------------------
# 4. Hand-off, OS-VOLUME branch (on_os_vol=1): correctly tells owner to set data.
# ---------------------------------------------------------------------------
OUT="$(run_lib 'bootstrap_handoff /opt/val-ark 8080 1 localhost')"
echo "$OUT" | grep -q 'VAL_ARK_DATA=/path/to/your/disk'            && pass || fail "os-volume branch tells owner to set VAL_ARK_DATA"
echo "$OUT" | grep -qF 'cd /opt/val-ark && ./start.sh serve'       && pass || fail "os-volume branch still prints correct start command"
echo "$OUT" | grep -qF 'http://localhost:8080'                     && pass || fail "os-volume branch prints wizard URL with custom port"

# ---------------------------------------------------------------------------
# 5. Idempotent formatter: repeated calls yield byte-identical output.
# ---------------------------------------------------------------------------
A="$(run_lib 'bootstrap_handoff /x 3000 0 localhost')"
B="$(run_lib 'bootstrap_handoff /x 3000 0 localhost')"
[ "$A" = "$B" ] && pass || fail "hand-off output stable across runs"

# ---------------------------------------------------------------------------
# 6. Resolver reads valark-env + threads the verdict + .env port (deterministic:
#    equal PROJECT_ROOT/DATA_ROOT forces the on-OS-volume path with no df needed).
# ---------------------------------------------------------------------------
CK="$T/ck"; mkdir -p "$CK/scripts/lib"
cat > "$CK/scripts/lib/valark-env.sh" <<EOS
PROJECT_ROOT="$CK"
DATA_ROOT="$CK"
EOS
printf 'VALARK_WEB_PORT=3970\n' > "$CK/.env"
OUT="$(run_lib "bootstrap_print_handoff '$CK' 'http://mirror.example:3000'")"
echo "$OUT" | grep -qF "cd $CK && ./start.sh serve"   && pass || fail "resolver prints correct start command"
echo "$OUT" | grep -qF 'http://localhost:3970'        && pass || fail "resolver threads the .env port"
echo "$OUT" | grep -q  'VAL_ARK_DATA'                 && pass || fail "resolver threads the on-OS-volume verdict from valark-env"
echo "$OUT" | grep -qF 'mirror.example:3000'          && pass || fail "resolver notes where content is mirrored from"

# ---------------------------------------------------------------------------
# 7. Errors handled: run with no host (not lib mode) → friendly Usage, exit 1.
# ---------------------------------------------------------------------------
OUT="$(bash "$BS" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && echo "$OUT" | grep -qi 'Usage'; } && pass || fail "missing host prints Usage and exits 1 (got rc=$RC)"

# ---------------------------------------------------------------------------
# 8. FULL FLOW idempotency (offline): stubbed checkout + stub curl/git, run twice.
# ---------------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/bin/bash\nexit 0\n' > "$BIN/git"                       # only `git pull` is used
CANARY="$T/curl-calls"; : > "$CANARY"
cat > "$BIN/curl" <<EOS                                            # canary: log any network attempt
#!/bin/bash
echo "\$*" >> "$CANARY"
exit 1
EOS
chmod +x "$BIN/git" "$BIN/curl"

FC="$T/fc"; mkdir -p "$FC/.git" "$FC/scripts/lib" "$FC/data"       # a dir that "already looks like a checkout"
printf '#!/bin/bash\necho "STUB SETUP (offline, installs nothing)"\nexit 0\n' > "$FC/scripts/setup.sh"
cat > "$FC/scripts/lib/valark-env.sh" <<EOS
PROJECT_ROOT="$FC"
DATA_ROOT="$FC/data"
EOS
printf 'VALARK_WEB_PORT=3970\n' > "$FC/.env"
printf '#!/bin/bash\necho "STUB START ($*)"\n' > "$FC/start.sh"
chmod +x "$FC/scripts/setup.sh" "$FC/start.sh"

run_flow() { PATH="$BIN:$PATH" VALARK_YES=1 bash "$BS" "mirror.example:3000" "$FC" 2>&1; }
OUT1="$(run_flow)"; RC1=$?
OUT2="$(run_flow)"; RC2=$?
{ [ "$RC1" = 0 ] && [ "$RC2" = 0 ]; }                          && pass || fail "full flow exits 0 on first + repeat run (rc1=$RC1 rc2=$RC2)"
echo "$OUT1" | grep -q 'already looks like a Val Ark checkout'  && pass || fail "re-run detects the existing checkout (idempotent branch)"
echo "$OUT1" | grep -qF "cd $FC && ./start.sh serve"           && pass || fail "full flow prints the correct start command"
echo "$OUT1" | grep -qF 'http://localhost:3970'                && pass || fail "full flow prints the wizard URL with the configured port"
[ ! -s "$CANARY" ]                                             && pass || fail "hermetic: bootstrap made no network curl calls"
[ "$OUT1" = "$OUT2" ]                                          && pass || fail "full flow output identical across idempotent re-runs"

echo "bootstrap: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
