#!/bin/bash
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
echo ""; echo "========== 转推状态 =========="
found=0
for f in /tmp/douyin2yt_*.pid; do
    [ -f "$f" ] || continue; PID=$(cat "$f")
    if ps -p "$PID" &>/dev/null; then
        found=$((found + 1))
        CMD=$(ps -p "$PID" -o args= 2>/dev/null | sed 's|.*restream.sh ||')
        UPTIME=$(ps -p "$PID" -o etime= 2>/dev/null)
        echo -e "  ${GREEN}●${NC} PID:$PID  运行:$UPTIME"
        echo "    $CMD"; echo ""
    else rm -f "$f"; fi
done
[ "$found" -eq 0 ] && echo -e "  ${YELLOW}没有运行中的任务${NC}"
echo "=============================="
