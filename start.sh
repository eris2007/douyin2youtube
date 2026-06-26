#!/bin/bash
if [ $# -lt 2 ]; then
    echo ""; echo "  用法: $0 <抖音直播间链接> <YouTube推流密钥>"
    echo "  示例: $0 https://live.douyin.com/745964462470 abcd-efgh-ijkl"
    echo ""; echo "  其他命令:"
    echo "    ./status.sh     查看运行状态"
    echo "    ./log.sh        查看实时日志"
    echo "    ./stop.sh       停止所有转推"
    echo "    ./stop.sh 密钥  停止指定转推"; echo ""; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOUYIN_URL="$1"; YOUTUBE_KEY="$2"
TASK_ID="${3:-}"
BACKUP_URLS="${4:-}"
KEY_HASH=$(echo "$YOUTUBE_KEY" | md5sum | cut -c1-8)
if [ -n "$TASK_ID" ]; then
    PID_ID="task${TASK_ID}"
else
    PID_ID="${KEY_HASH}"
fi
LOG_FILE="${SCRIPT_DIR}/logs/restream_${PID_ID}.log"
mkdir -p "${SCRIPT_DIR}/logs"
PID_FILE="/tmp/douyin2yt_${PID_ID}.pid"
STOP_FILE="/tmp/douyin2yt_${PID_ID}.stop"
rm -f "$STOP_FILE"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" &>/dev/null; then
        echo ""; echo "⚠️  该推流密钥已有任务运行 (PID: $OLD_PID)"
        echo "   先停止: ./stop.sh $YOUTUBE_KEY"; echo ""; exit 1
    fi
fi
nohup bash "${SCRIPT_DIR}/restream.sh" "$DOUYIN_URL" "$YOUTUBE_KEY" "$TASK_ID" "$BACKUP_URLS" > "$LOG_FILE" 2>&1 &
sleep 1
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    echo ""; echo "  ✅ 转推已启动 | PID: $PID"
    echo "  抖音: $DOUYIN_URL"
    echo "  日志: $LOG_FILE"
    echo "  可以安全关闭 Termius 了 ✌️"; echo ""
else
    echo ""; echo "❌ 启动失败，检查日志: $LOG_FILE"; echo ""; exit 1
fi
