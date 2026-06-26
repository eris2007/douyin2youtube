#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ $# -ge 1 ]; then
    KEY_HASH=$(echo "$1" | md5sum | cut -c1-8)
    LOG_FILE="${SCRIPT_DIR}/logs/restream_${KEY_HASH}.log"
else
    LOG_FILE=$(ls -t "$SCRIPT_DIR"/logs/restream_*.log 2>/dev/null | head -1)
fi
[ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && { echo "暂无日志"; exit 0; }
echo "  日志: $LOG_FILE"; echo "  按 Ctrl+C 退出"; echo ""
tail -f "$LOG_FILE"
