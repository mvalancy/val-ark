#!/bin/bash
###############################################################################
# Val Ark - fresh-VM setup matrix (host side).
#
# Launches a clean Ubuntu VM per version (22.04 / 24.04 / 26.04) with multipass,
# unpacks the current Val Ark source, runs the real setup + a web-UI/API smoke
# test inside each, and folds every step into the unified HTML report — surfacing
# the setup issues a brand-new user would hit on each OS. Reusable and offline
# once the images are cached.
#
# Env:
#   VALARK_VM_VERSIONS="24.04"   run a subset (default: "22.04 24.04 26.04")
#   VALARK_VM_KEEP=1             keep the VMs afterwards (for debugging)
#   VALARK_VM_CPUS=2  VALARK_VM_MEM=4G  VALARK_VM_DISK=12G
###############################################################################
set -o pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${_DIR}/../.." && pwd)"
. "${_DIR}/../lib/results.sh"

VERSIONS="${VALARK_VM_VERSIONS:-22.04 24.04 26.04}"
CPUS="${VALARK_VM_CPUS:-2}"; MEM="${VALARK_VM_MEM:-4G}"; DISK="${VALARK_VM_DISK:-12G}"

if ! command -v multipass >/dev/null 2>&1; then
    results_init "vm-setup" "Fresh-VM setup (Ubuntu)"
    results_case "multipass available" skip 0 "install multipass to run the fresh-VM matrix"
    results_finish; exit 0
fi

# Package the current committed source (what we'd ship) as the "download".
# NOTE: multipass is snap-confined — its `home` interface can read only NON-hidden
# files under $HOME (a /tmp path or any dot-dir like ~/.cache fails with
# "sftp cannot access / permission denied"). Stage inside the repo (non-hidden,
# git-ignored under tests/results/).
mkdir -p "${PROJECT_ROOT}/tests/results" 2>/dev/null
SRC="${PROJECT_ROOT}/tests/results/vm-src.tar.gz"
if ! git -C "$PROJECT_ROOT" archive --format=tar.gz --prefix=val-ark/ -o "$SRC" HEAD 2>/dev/null; then
    tar --exclude=./.git --exclude=./tools --exclude=./content --exclude=./models \
        --exclude=./sources --exclude=./assets --exclude=./installers --exclude=node_modules \
        -czf "$SRC" -C "$PROJECT_ROOT" . 2>/dev/null
fi
echo "  source package: $(du -h "$SRC" | cut -f1)"

results_init "vm-setup" "Fresh-VM setup (Ubuntu ${VERSIONS// /, })"

for v in $VERSIONS; do
    name="valark-vm-$(echo "$v" | tr -d '.')"
    echo -e "\n  === Ubuntu ${v} (${name}) ==="
    multipass delete --purge "$name" >/dev/null 2>&1

    s=$(date +%s%3N 2>/dev/null || echo 0)
    if ! timeout 600 multipass launch "$v" --name "$name" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" >/dev/null 2>&1; then
        e=$(date +%s%3N 2>/dev/null || echo 0)
        results_case "[${v}] VM launch" fail "$((e-s))" "multipass launch $v failed (image unavailable or host resources)"
        continue
    fi
    e=$(date +%s%3N 2>/dev/null || echo 0)
    results_case "[${v}] VM launch" pass "$((e-s))"

    # Transfer into the default user's HOME (reliably writable; multipass' scp to an
    # absolute /tmp path is flaky across versions). Verify it landed before running.
    terr="$(multipass transfer "$SRC" "${name}:val-ark-src.tar.gz" 2>&1)"; trc=$?
    multipass transfer "${_DIR}/provision.sh" "${name}:provision.sh" >/dev/null 2>&1
    if [ "$trc" -ne 0 ] || ! multipass exec "$name" -- test -f val-ark-src.tar.gz 2>/dev/null; then
        results_case "[${v}] source transfer" fail 0 "multipass transfer failed: $(printf '%s' "$terr" | tr '\n' ' ' | cut -c1-160)"
        [ "${VALARK_VM_KEEP:-0}" != "1" ] && multipass delete --purge "$name" >/dev/null 2>&1
        continue
    fi
    results_case "[${v}] source transfer" pass 0

    out="$(timeout 900 multipass exec "$name" -- bash ./provision.sh ./val-ark-src.tar.gz 2>&1)"
    # Parse STEP|name|status|ms|detail lines into report cases.
    got_steps=0
    while IFS='|' read -r tag sname sstatus sms sdetail; do
        [ "$tag" = "STEP" ] || continue
        got_steps=1
        results_case "[${v}] ${sname}" "$sstatus" "${sms:-0}" "$sdetail"
    done <<< "$out"
    [ "$got_steps" = 1 ] || results_case "[${v}] provision ran" fail 0 "no STEP output: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"

    if [ "${VALARK_VM_KEEP:-0}" != "1" ]; then multipass delete --purge "$name" >/dev/null 2>&1; fi
done

rm -f "$SRC" 2>/dev/null
results_finish
