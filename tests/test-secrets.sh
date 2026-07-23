#!/bin/bash
###############################################################################
# Test: secret / private-host leak scan (issue #130).
#
# The repo is PUBLIC (Prime Directive 1). This gate fails the build if a real
# host name, LAN/private IP, private-TLD host, or a tracked secret/key file
# lands in git — the class of miss that let `nas-5sgf` sit committed in
# tests/README.md. Fully OFFLINE. Reviewed exceptions live in
# tests/lib/secrets-allowlist.txt. See tests/lib/secret_scan.py.
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found — secret scan needs it (CI has python3)"
    exit 0
fi

python3 "${SCRIPT_DIR}/lib/secret_scan.py" "${PROJECT_ROOT}"
