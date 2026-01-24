#!/bin/bash
###############################################################################
# Retry failed downloads from a previous session
###############################################################################

MODEL_ROOT="/home/uat-admin/models"
FAILED_FILE="${MODEL_ROOT}/logs/failed_downloads.txt"

if [ ! -f "$FAILED_FILE" ] || [ ! -s "$FAILED_FILE" ]; then
    echo "No failed downloads to retry."
    exit 0
fi

echo "Retrying $(wc -l < "$FAILED_FILE") failed downloads..."
echo ""

# Just re-run the main script - it skips already-downloaded files
exec "$(dirname "$0")/download-models.sh" all
