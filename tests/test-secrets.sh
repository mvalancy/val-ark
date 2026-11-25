#!/bin/bash
###############################################################################
# Test: secret / private-host leak scan (issue #130).
#
# The repo is PUBLIC (Prime Directive 1). This gate fails the build if a real
# host name, LAN/private IP, private-TLD host, or a tracked secret/key file
# lands in git — the class of miss that let a real host name sit committed in a
# tests/ README example (scrubbed in #129). Fully OFFLINE. Reviewed exceptions in
# tests/lib/secrets-allowlist.txt. See tests/lib/secret_scan.py.
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Skips locally without python3; fails under CI so the gate can't switch itself off (#255).
. "${SCRIPT_DIR}/lib/require-cmd.sh"
require_python3 "secret scan"

python3 "${SCRIPT_DIR}/lib/secret_scan.py" "${PROJECT_ROOT}"
