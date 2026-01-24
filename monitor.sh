#!/bin/bash
###############################################################################
# Monitor download progress - run in a separate terminal
###############################################################################

MODEL_ROOT="/home/uat-admin/models"

while true; do
    clear
    echo "=================================================================="
    echo "  AI Model Download Monitor - $(date)"
    echo "=================================================================="
    echo ""

    # Total size
    if [ -d "$MODEL_ROOT" ]; then
        total=$(du -sh "$MODEL_ROOT" 2>/dev/null | cut -f1)
        echo "Total downloaded: $total"
        echo ""

        # Per-category breakdown
        echo "Category breakdown:"
        for dir in llm tts stt vlm image-gen nvidia-special; do
            if [ -d "${MODEL_ROOT}/${dir}" ]; then
                size=$(du -sh "${MODEL_ROOT}/${dir}" 2>/dev/null | cut -f1)
                count=$(find "${MODEL_ROOT}/${dir}" -type f 2>/dev/null | wc -l)
                printf "  %-20s %8s (%d files)\n" "$dir" "$size" "$count"
            fi
        done
        echo ""

        # Disk space
        echo "Disk space:"
        df -h "$MODEL_ROOT" | tail -1 | awk '{printf "  Used: %s / %s (Available: %s)\n", $3, $2, $4}'
        echo ""

        # Active downloads
        echo "Active wget processes:"
        pgrep -a wget 2>/dev/null | tail -5 || echo "  (none)"
        echo ""

        # Failed downloads
        if [ -f "${MODEL_ROOT}/logs/failed_downloads.txt" ] && [ -s "${MODEL_ROOT}/logs/failed_downloads.txt" ]; then
            echo "Failed downloads:"
            cat "${MODEL_ROOT}/logs/failed_downloads.txt" | while read line; do
                echo "  - $line"
            done
        fi

        # Latest log entry
        echo ""
        echo "Latest log entries:"
        local latest_log=$(ls -t ${MODEL_ROOT}/logs/download_*.log 2>/dev/null | head -1)
        if [ -n "$latest_log" ]; then
            tail -3 "$latest_log"
        fi
    else
        echo "No downloads started yet. Run: ./download-all-models.sh all"
    fi

    sleep 10
done
