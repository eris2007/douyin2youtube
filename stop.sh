#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

stop_by_key() {
    local KEY="$1"
    local TASK_ID="${2:-}"
    local KEY_HASH=$(echo "$KEY" | md5sum | cut -c1-8)
    local KILLED=0

    _kill_tree() {
        local pid=$1
        [ -n "$pid" ] || return 0
        for cpid in $(pgrep -P "$pid" 2>/dev/null); do
            _kill_tree "$cpid"
        done
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.2
        ps -p "$pid" &>/dev/null && kill -9 "$pid" 2>/dev/null || true
    }

    # 确定PID文件和STOP文件路径
    if [ -n "$TASK_ID" ]; then
        local PID_FILE="/tmp/douyin2yt_task${TASK_ID}.pid"
        local STOP_FILE="/tmp/douyin2yt_task${TASK_ID}.stop"
    else
        local PID_FILE="/tmp/douyin2yt_${KEY_HASH}.pid"
        local STOP_FILE="/tmp/douyin2yt_${KEY_HASH}.stop"
    fi

    # 1. Create stop flag file so restream.sh exits retry loop
    touch "$STOP_FILE"

    # 2. Kill the bash main process (restream.sh) and ALL its children
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" &>/dev/null; then
            # 先杀整个进程组（如果PID是leader）
            kill -TERM -- "-$PID" 2>/dev/null || true
            # 再杀主进程本身
            kill -TERM "$PID" 2>/dev/null || true
            KILLED=$((KILLED+1))
            sleep 1
            _kill_tree "$PID"
        fi
        rm -f "$PID_FILE"
    fi

    # 3. Fallback: find and kill any restream.sh process for this task
    #    用 task_id 匹配（最可靠），不用 key（因为 key 可能已变）
    if [ -n "$TASK_ID" ]; then
        for PID in $(pgrep -f "restream\\.sh|start\\.sh" 2>/dev/null); do
            [ "$PID" = "$$" ] && continue
            CMDLINE=$(cat /proc/${PID}/cmdline 2>/dev/null | tr '\0' ' ')
            if echo " $CMDLINE " | grep -Eq "[[:space:]]${TASK_ID}([[:space:]]|$)"; then
                _kill_tree "$PID"
                KILLED=$((KILLED+1))
            fi
        done
    fi

    # 4. Fallback: kill any ffmpeg whose cmdline contains this YouTube key
    for PID in $(pgrep -f "ffmpeg" 2>/dev/null); do
        CMDLINE=$(cat /proc/${PID}/cmdline 2>/dev/null | tr '\0' ' ')
        if echo "$CMDLINE" | grep -q "$KEY"; then
            kill -9 "$PID" 2>/dev/null
            KILLED=$((KILLED+1))
        fi
    done

    # 5. Nuclear fallback: if task_id, kill by PID file pattern
    if [ -n "$TASK_ID" ]; then
        for f in /tmp/douyin2yt_task${TASK_ID}*.pid; do
            [ -f "$f" ] || continue
            PID=$(cat "$f" 2>/dev/null)
            [ -n "$PID" ] && ps -p "$PID" &>/dev/null && kill -9 "$PID" 2>/dev/null
            rm -f "$f"
        done
    fi

    # Clean up PID only. Keep STOP_FILE until the next start clears it, so a
    # surviving restream retry loop can still observe the stop request.
    rm -f "$PID_FILE"

    if [ $KILLED -gt 0 ]; then
        echo -e "${GREEN}[成功]${NC} 已停止 $KILLED 个进程"
    else
        echo -e "${RED}[提示]${NC} 未找到运行中的任务"
    fi
}

if [ $# -ge 1 ]; then
    stop_by_key "$1" "$2"
else
    count=0
    for f in /tmp/douyin2yt_*.pid; do
        [ -f "$f" ] || continue
        touch "${f%.pid}.stop"
        PID=$(cat "$f")
        kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
        sleep 0.5
        ps -p "$PID" &>/dev/null && kill -9 "$PID" 2>/dev/null
        for CPID in $(pgrep -P "$PID" 2>/dev/null); do
            kill -9 "$CPID" 2>/dev/null
        done
        rm -f "$f"
        count=$((count + 1))
    done
    [ $count -gt 0 ] && echo -e "${GREEN}[成功]${NC} 已停止 $count 个进程" || echo "没有运行中的任务"
fi
