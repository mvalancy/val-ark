#!/bin/bash
###############################################################################
# Retry failed downloads from a previous session
###############################################################################

_RF_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "${_RF_DIR}/lib/valark-env.sh" ] && . "${_RF_DIR}/lib/valark-env.sh"
MODEL_ROOT="${MODELS_DIR:-${HOME}/models}"
FAILED_FILE="${MODEL_ROOT}/logs/failed_downloads.txt"

if [ ! -f "$FAILED_FILE" ] || [ ! -s "$FAILED_FILE" ]; then
    echo "No failed downloads to retry."
    exit 0
fi

echo "Retrying $(wc -l < "$FAILED_FILE") failed downloads..."
echo ""

# Just re-run the main script - it skips already-downloaded files
exec "$(dirname "$0")/download-models.sh" all
