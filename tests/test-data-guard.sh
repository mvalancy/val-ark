#!/bin/bash
###############################################################################
# Test: data-disk identity guard (issue #58).
#
# When Val Ark lives on a SEPARATE disk, a late/failed mount at @reboot must NOT
# let the loop rebuild the state/content tree on the ROOT filesystem (which the
# librarian would then fill, and which forks the loop lock onto a shadowed inode
# once the real disk mounts). Guard = an on-disk sentinel id + a root-fs marker
# recording the same id; the cycle proceeds only when they match. Invariants:
#   - single-disk / dev (DATA_ROOT == PROJECT_ROOT): never marked, always allowed
#   - uncommissioned separate disk (no marker): first-run allowed so it can stamp
#   - commissioned + mounted (sentinel present, id matches): allowed
#   - commissioned + UNMOUNTED (sentinel gone): SKIP
#   - commissioned but autodetect fell back to the repo: SKIP
#   - a DIFFERENT disk mounted at the mountpoint (id mismatch): SKIP
#   - `loop.sh once` on an unmounted commissioned disk exits 0 and creates NO tree,
#     dropping a root-fs health breadcrumb instead
# All paths are redirected to a tmp dir via env overrides — the real repo is never
# touched (no repo symlinks, no marker/breadcrumb in the checkout).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
ENV="$ROOT/scripts/lib/valark-env.sh"
LOOP="$ROOT/scripts/loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
CONF="$T/empty.conf"; : > "$CONF"          # blocks loading the real repo .env
MARKER="$T/marker"                          # root-fs identity marker (overridden)
WAIT="$T/breadcrumb"                        # mount-wait health flag (overridden)

# --- 0. both scripts parse ----------------------------------------------------
bash -n "$ENV" 2>/dev/null && pass || fail "valark-env.sh must be syntactically valid"
bash -n "$LOOP" 2>/dev/null && pass || fail "loop.sh must be syntactically valid"

# Driver: source valark-env.sh (real repo functions) with a fully overridden
# data-root + marker path, then run the requested function. Fresh subshell each
# call, so the source-guard never blocks re-sourcing.
DRV="$T/drv.sh"
cat > "$DRV" <<EOF
. "$ENV"
"\$@"
EOF
drive() {   # drive <VAL_ARK_DATA> <fn...>  → prints rc on stdout
    local vad="$1"; shift
    env VAL_ARK_CONFIG="$CONF" VALARK_DATA_MARKER="$MARKER" VALARK_MOUNT_WAIT_FLAG="$WAIT" \
        VAL_ARK_DATA="$vad" bash "$DRV" "$@" >/dev/null 2>&1
    echo $?
}

# --- 1. single-disk / dev mode is never guarded (DATA_ROOT == PROJECT_ROOT) ---
rm -f "$MARKER"
[ "$(drive "$ROOT" valark_data_stamp)" = 0 ] && [ ! -e "$MARKER" ] && pass \
    || fail "single-disk stamp must be a no-op (no marker written)"
[ "$(drive "$ROOT" valark_data_mounted)" = 0 ] && pass \
    || fail "single-disk mode must always be allowed to run"

# --- 2. uncommissioned separate disk (no marker) → first-run allowed ----------
DISK="$T/disk"; mkdir -p "$DISK"
rm -f "$MARKER"
[ "$(drive "$DISK" valark_data_mounted)" = 0 ] && pass \
    || fail "an uncommissioned separate disk must be allowed (so it can stamp on first run)"

# --- 3. commission it: stamp writes matching sentinel + marker ----------------
mkdir -p "$DISK/val-ark"                     # the tree exists on the mounted disk
drive "$DISK" valark_data_stamp >/dev/null
SENT="$DISK/val-ark/.valark-data"
[ -s "$MARKER" ] && [ -s "$SENT" ] && pass || fail "stamp must write both the marker and the on-disk sentinel"
[ "$(cat "$MARKER")" = "$(cat "$SENT")" ] && pass || fail "the marker and sentinel must record the SAME id"
# stamp is one-shot: a second stamp must not change the recorded id
id1="$(cat "$MARKER")"; drive "$DISK" valark_data_stamp >/dev/null
[ "$(cat "$MARKER")" = "$id1" ] && pass || fail "stamp must be one-shot (id stable across re-runs)"

# --- 4. commissioned + mounted → allowed --------------------------------------
[ "$(drive "$DISK" valark_data_mounted)" = 0 ] && pass \
    || fail "commissioned + mounted (matching sentinel) must be allowed"

# --- 5. commissioned + UNMOUNTED (sentinel gone) → SKIP -----------------------
rm -f "$SENT"                                 # real disk not mounted → mountpoint empty
[ "$(drive "$DISK" valark_data_mounted)" = 1 ] && pass \
    || fail "commissioned disk with a missing sentinel (unmounted) must be SKIPPED"

# --- 6. commissioned but autodetect fell back to the repo → SKIP --------------
[ "$(drive "$ROOT" valark_data_mounted)" = 1 ] && pass \
    || fail "commissioned box that fell back to DATA_ROOT==PROJECT_ROOT (disk gone) must be SKIPPED"

# --- 7. a DIFFERENT disk mounted at the mountpoint (id mismatch) → SKIP --------
printf 'some-other-disk-id\n' > "$SENT"
[ "$(drive "$DISK" valark_data_mounted)" = 1 ] && pass \
    || fail "a different disk mounted at the mountpoint (sentinel id mismatch) must be SKIPPED"
rm -f "$SENT"                                 # back to unmounted for the loop test

# --- 8. `loop.sh once` on an unmounted commissioned disk: exit 0, NO tree -----
DISK2="$T/disk2"; mkdir -p "$DISK2"           # mountpoint present, disk NOT mounted
rm -f "$WAIT"
env VAL_ARK_CONFIG="$CONF" VALARK_DATA_MARKER="$MARKER" VALARK_MOUNT_WAIT_FLAG="$WAIT" \
    VALARK_MOUNT_WAIT_TRIES=0 VAL_ARK_DATA="$DISK2" FORCE_COLOR=0 \
    bash "$LOOP" once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && pass || fail "loop.sh once must SKIP cleanly (exit 0) when the data disk isn't mounted (got $rc)"
[ ! -e "$DISK2/val-ark" ] && pass || fail "loop.sh once must NOT build the state/content tree on the wrong fs when unmounted"
[ -s "$WAIT" ] && pass || fail "loop.sh once must drop a root-fs health breadcrumb when it skips for a missing disk"
# the breadcrumb must NOT have been written into the (missing) data tree
[ ! -e "$DISK2/val-ark/state" ] && pass || fail "no state dir may be seeded on the unmounted mountpoint"

# --- 9. data_disk_guard itself: skip writes breadcrumb, pass clears it --------
# Drive the real extracted guard (a full loop.sh once is otherwise heavy).
GH="$T/guard.sh"
{
    echo ". \"$ENV\""
    echo 'RED=""; GREEN=""; YELLOW=""; NC=""; log(){ :; }'
    echo 'DATA_WAIT_FLAG="$VALARK_MOUNT_WAIT_FLAG"'
    awk '/^data_disk_guard\(\) \{/,/^\}/' "$LOOP"
    echo '"$@"'
} > "$GH"
grep -q 'valark_data_mounted' "$GH" && pass || fail "harness must contain the real data_disk_guard"
# 9a: mounted → returns 0 AND removes a stale breadcrumb
touch "$WAIT"
env VAL_ARK_CONFIG="$CONF" VALARK_DATA_MARKER="$MARKER" VALARK_MOUNT_WAIT_FLAG="$WAIT" \
    VAL_ARK_DATA="$DISK" bash -c 'printf "%s\n" "$(cat "'"$MARKER"'")" > "'"$DISK"'/val-ark/.valark-data"'  # re-mount
env VAL_ARK_CONFIG="$CONF" VALARK_DATA_MARKER="$MARKER" VALARK_MOUNT_WAIT_FLAG="$WAIT" \
    VAL_ARK_DATA="$DISK" bash "$GH" data_disk_guard >/dev/null 2>&1; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$WAIT" ]; } && pass || fail "data_disk_guard on a mounted disk must return 0 and clear the breadcrumb (rc=$rc)"
# 9b: unmounted → returns 1 AND writes the breadcrumb (tries=0 so no wait)
rm -f "$DISK/val-ark/.valark-data" "$WAIT"
env VAL_ARK_CONFIG="$CONF" VALARK_DATA_MARKER="$MARKER" VALARK_MOUNT_WAIT_FLAG="$WAIT" \
    VALARK_MOUNT_WAIT_TRIES=0 VAL_ARK_DATA="$DISK" bash "$GH" data_disk_guard >/dev/null 2>&1; rc=$?
{ [ "$rc" = 1 ] && [ -s "$WAIT" ]; } && pass || fail "data_disk_guard on an unmounted disk must return 1 and write the breadcrumb (rc=$rc)"

echo "data-guard: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
