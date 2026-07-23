#!/bin/bash
###############################################################################
# Test: internal Markdown link & anchor integrity (issue #130).
#
# Keeps the .md hierarchy actually interconnected — every internal link and
# #anchor across all tracked .md files must resolve. Motivated by the #129 doc
# cleanup: a renamed heading or moved file silently breaks navigation, and CI
# never noticed. Fully OFFLINE (repo-internal only); external URLs are out of
# scope here (see test-urls.sh). See tests/lib/md_link_check.py.
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

if ! command -v python3 >/dev/null 2>&1; then
    # Match the suite's degrade-gracefully posture (cf. run-all.sh node fallback):
    # skip locally without python3, but CI always has it, so the gate holds there.
    echo "SKIP: python3 not found — internal-link check needs it (CI has python3)"
    exit 0
fi

python3 "${SCRIPT_DIR}/lib/md_link_check.py" "${PROJECT_ROOT}"
