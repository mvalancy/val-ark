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

# Skips locally without python3; fails under CI so the gate can't switch itself off (#255).
. "${SCRIPT_DIR}/lib/require-cmd.sh"
require_python3 "internal-link check"

python3 "${SCRIPT_DIR}/lib/md_link_check.py" "${PROJECT_ROOT}"
