#!/bin/bash
###############################################################################
#  抖音 → YouTube 实时转推脚本 v3
#  用法: ./restream.sh <抖音直播间链接> <YouTube推流密钥>
#
#  ⚠️ 链接必须是 live.douyin.com 格式:
#    https://live.douyin.com/745964462470
#    https://live.douyin.com/yall1102
#
#  ❌ 不支持 v.douyin.com 短链接（手机分享链接）
#
#  停止: 按 Ctrl+C，或执行 ./stop.sh
###############################################################################

set -euo pipefail

# ==================== 配置区 ====================
MAX_RETRIES=0          # 0 = 无限重试（转推中断后）
RETRY_WAIT=30          # 重试间隔（秒）
CHECK_INTERVAL=15      # 检测间隔（秒）
MAX_WAIT_CHECKS=60     # 最多等待检测次数（60次=15分钟），超过自动退出
QUALITY="best"         # best / origin / hd / sd
YOUTUBE_RTMP="rtmp://a.rtmp.youtube.com/live2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COOKIE_FILE="${SCRIPT_DIR}/cookie.txt"
# 加载控制面板配置（用于代理获取流URL）
[ -f "${SCRIPT_DIR}/.env" ] && source "${SCRIPT_DIR}/.env"
CONTROL_PANEL_URL="${CONTROL_PANEL_URL:-}"
CONTROL_PANEL_SESSION="${CONTROL_PANEL_SESSION:-}"
PROXY_API_KEY="${PROXY_API_KEY:-}"
COOKIE_ARG=""
if [ -f "$COOKIE_FILE" ] && [ -s "$COOKIE_FILE" ]; then
    # 用 --http-cookie 传递 cookie，注意引号保护空格
    COOKIE_ARG="--http-cookie"
    COOKIE_VAL="$(cat "$COOKIE_FILE" | tr -d '\n')"
fi
# ================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export TZ='Asia/Shanghai'
ts() { date '+%H:%M:%S'; }
print_info()  { echo -e "${CYAN}[信息]${NC} $(ts) $*"; }
print_ok()    { echo -e "${GREEN}[成功]${NC} $(ts) $*"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $(ts) $*"; }
print_err()   { echo -e "${RED}[错误]${NC} $(ts) $*"; }

if [ $# -lt 2 ]; then
    echo ""
    echo "=========================================="
    echo "  抖音 → YouTube 实时转推工具 v3"
    echo "=========================================="
    echo ""
    echo "  用法: $0 <抖音直播间链接> <YouTube推流密钥>"
    echo ""
    echo "  示例:"
    echo "    $0 https://live.douyin.com/745964462470 abcd-efgh-ijkl-mnop"
    echo ""
    echo "  ⚠️  链接必须是 live.douyin.com 格式！"
    echo "  获取方法: 电脑浏览器打开抖音直播间，复制地址栏链接"
    echo ""
    echo "  停止: 按 Ctrl+C"
    echo "=========================================="
    echo ""
    exit 1
fi

DOUYIN_URL="$1"
YOUTUBE_KEY="$2"
TASK_ID="${3:-}"  # 可选第三个参数：任务ID
BACKUP_URLS="${4:-}"  # 可选第四个参数：备用源URL（逗号分隔）
FULL_RTMP="${YOUTUBE_RTMP}/${YOUTUBE_KEY}"
RECORD_ENABLED="${RECORD_ENABLED:-0}"
RECORDING_ID="${RECORDING_ID:-}"
RECORD_FORMAT="${RECORD_FORMAT:-ts}"
RECORD_SEGMENT_SECONDS="${RECORD_SEGMENT_SECONDS:-900}"
RECORD_OUTPUT_NAME="${RECORD_OUTPUT_NAME:-}"
RECORD_FALLBACK_ENABLED="${RECORD_FALLBACK_ENABLED:-0}"
RECORD_DIR="${RECORD_DIR:-${SCRIPT_DIR}/uploads/recordings/recording_${RECORDING_ID}}"

# 解析备用源列表
IFS=',' read -ra BACKUP_URL_ARRAY <<< "$BACKUP_URLS"
CURRENT_SOURCE_INDEX=0  # 0=主源, 1+=备用源
ALL_SOURCES=("$DOUYIN_URL" "${BACKUP_URL_ARRAY[@]}")

# PID文件：有TASK_ID用TASK_ID，没有则用KEY_HASH（兼容旧调用）
if [ -n "$TASK_ID" ]; then
    PID_FILE="/tmp/douyin2yt_task${TASK_ID}.pid"
    STOP_FILE="/tmp/douyin2yt_task${TASK_ID}.stop"
    LOG_FILE="${SCRIPT_DIR}/logs/restream_task${TASK_ID}.log"
else
    PID_FILE="/tmp/douyin2yt_$(echo "$YOUTUBE_KEY" | md5sum | cut -c1-8).pid"
    STOP_FILE="/tmp/douyin2yt_$(echo "$YOUTUBE_KEY" | md5sum | cut -c1-8).stop"
    LOG_FILE="${SCRIPT_DIR}/logs/restream_$(echo "$YOUTUBE_KEY" | md5sum | cut -c1-8).log"
fi

should_stop() {
    [ -f "$STOP_FILE" ] || { recording_enabled && [ -f "/tmp/douyin2yt_recording${RECORDING_ID}.stop" ]; }
}

interruptible_sleep() {
    local seconds="${1:-0}"
    local elapsed=0
    while [ "$elapsed" -lt "$seconds" ]; do
        if should_stop; then
            print_info "Stop flag detected, exiting retry loop."
            cleanup
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

fetch_proxy_stream_url() {
    local panel_url="${CONTROL_PANEL_URL:-http://restream.ytdeepsea.com}"
    local result
    if [ -n "$PROXY_API_KEY" ]; then
        result=$(curl -s --max-time 35 -G \
            -H "X-Proxy-Api-Key: ${PROXY_API_KEY}" \
            --data-urlencode "url=${DOUYIN_URL}" \
            "${panel_url}/api/proxy/stream-url" 2>&1)
    elif [ -n "$CONTROL_PANEL_SESSION" ]; then
        result=$(curl -s --max-time 35 -G \
            -b "session=${CONTROL_PANEL_SESSION}" \
            --data-urlencode "url=${DOUYIN_URL}" \
            "${panel_url}/api/proxy/stream-url" 2>&1)
    else
        return 1
    fi
    echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stream_url',''))" 2>/dev/null
}

fetch_douyin_web_stream_url() {
    local tmp_page
    tmp_page=$(mktemp /tmp/douyin_live_page.XXXXXX) || return 1

    local curl_args=(
        -L -sS --max-time 25
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        -H "referer: https://www.douyin.com/"
    )
    if [ -n "${COOKIE_VAL:-}" ]; then
        curl_args+=(-H "cookie: ${COOKIE_VAL}")
    fi

    curl "${curl_args[@]}" "$DOUYIN_URL" -o "$tmp_page" 2>/dev/null || {
            rm -f "$tmp_page"
            return 1
        }
    python3 - "$tmp_page" <<'PY'
import html
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore")

def normalize(raw: str) -> str:
    return html.unescape(raw).replace("\\u0026", "&").replace("\\/", "/")

urls = []
for blob in (text, normalize(text)):
    blob = normalize(blob)
    for url in re.findall(r"https?://[^\"'<>\s\\]+", blob):
        if (".flv" in url or ".m3u8" in url) and (
            "douyincdn.com" in url
            or "douyinliving.com" in url
            or "bytefcdn" in url
            or "bytevcloud" in url
        ):
            url = normalize(url)
            if "only_audio=1" not in url:
                urls.append(url)

seen = set()
deduped = []
for url in urls:
    if url not in seen:
        seen.add(url)
        deduped.append(url)

def score(url: str) -> int:
    lower = url.lower()
    value = 0
    if any(flag in lower for flag in ("h265", "hevc", "_hd5", "_sd5", "_ld5", "_or5", "_uhd5")):
        value -= 1000
    if ".flv" in lower:
        value += 100
    if "stage0t000hd" in lower:
        value += 40
    if "_uhd" in lower or "full_hd" in lower:
        value += 30
    if "_hd" in lower or "hd1" in lower:
        value += 20
    if "_sd" in lower or "sd1" in lower:
        value -= 10
    return value

if deduped:
    print(max(deduped, key=score))
PY
    local status=$?
    rm -f "$tmp_page"
    return "$status"
}

ffmpeg_log_file() {
    echo "${SCRIPT_DIR}/logs/ffmpeg_$(date +%Y%m%d).log"
}

recording_enabled() {
    [ "$RECORD_ENABLED" = "1" ] && [ -n "$RECORDING_ID" ]
}

recording_fallback_enabled() {
    recording_enabled && [ "$RECORD_FALLBACK_ENABLED" = "1" ]
}

recording_segment_format() {
    case "$RECORD_FORMAT" in
        mp4) echo "mp4" ;;
        mkv) echo "matroska" ;;
        *) echo "mpegts" ;;
    esac
}

recording_extension() {
    case "$RECORD_FORMAT" in
        mp4|mkv) echo "$RECORD_FORMAT" ;;
        *) echo "ts" ;;
    esac
}

recording_prefix() {
    if [ -n "${RECORD_OUTPUT_NAME:-}" ]; then
        printf "%s" "$RECORD_OUTPUT_NAME"
    else
        printf "recording_%s" "$RECORDING_ID"
    fi
}

recording_tee_spec() {
    if ! recording_enabled; then
        return 0
    fi
    mkdir -p "$RECORD_DIR"
    local ext segment_format prefix pattern
    ext="$(recording_extension)"
    segment_format="$(recording_segment_format)"
    prefix="$(recording_prefix)"
    pattern="${RECORD_DIR}/${prefix}_%Y%m%d_%H%M%S.${ext}"
    echo "|[f=segment:segment_time=${RECORD_SEGMENT_SECONDS}:segment_format=${segment_format}:reset_timestamps=1:strftime=1:onfail=ignore]${pattern}"
}

youtube_record_tee_spec() {
    local suffix
    suffix="$(recording_tee_spec)"
    echo "[f=flv:flvflags=no_duration_filesize:onfail=abort]${FULL_RTMP}${suffix}"
}

stable_ffmpeg_bin() {
    if [ -x /usr/bin/ffmpeg ]; then
        echo /usr/bin/ffmpeg
    else
        command -v ffmpeg
    fi
}

stable_ffprobe_bin() {
    if [ -x /usr/bin/ffprobe ]; then
        echo /usr/bin/ffprobe
    else
        command -v ffprobe
    fi
}

detect_video_codec() {
    local input_url="$1"
    local ffprobe_bin
    ffprobe_bin="$(stable_ffprobe_bin)"
    timeout 15 "$ffprobe_bin" \
        -v error \
        -rw_timeout 10000000 \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of csv=p=0 \
        "$input_url" 2>/dev/null \
        | head -1 \
        | tr '[:upper:]' '[:lower:]' \
        | tr -d '\r' || true
}

run_ffmpeg_copy_url() {
    local input_url="$1"
    local ffmpeg_bin
    ffmpeg_bin="$(stable_ffmpeg_bin)"
    if recording_enabled; then
        print_info "同时录制已开启: ${RECORD_DIR}"
        "$ffmpeg_bin" -y -hide_banner \
            -rw_timeout 10000000 \
            -reconnect 1 \
            -reconnect_at_eof 1 \
            -reconnect_streamed 1 \
            -reconnect_delay_max 5 \
            -i "$input_url" \
            -map 0:v:0 -map 0:a:0? \
            -c copy \
            -max_muxing_queue_size 2048 \
            -f tee "$(youtube_record_tee_spec)"
    else
        "$ffmpeg_bin" -y -hide_banner \
            -rw_timeout 10000000 \
            -reconnect 1 \
            -reconnect_at_eof 1 \
            -reconnect_streamed 1 \
            -reconnect_delay_max 5 \
            -i "$input_url" \
            -c copy \
            -f flv \
            -flvflags no_duration_filesize \
            "$FULL_RTMP"
    fi
}

run_ffmpeg_transcode_url() {
    local input_url="$1"
    local ffmpeg_bin
    ffmpeg_bin="$(stable_ffmpeg_bin)"
    local output_args=(-f flv -flvflags no_duration_filesize "$FULL_RTMP")
    if recording_enabled; then
        print_info "同时录制已开启: ${RECORD_DIR}"
        output_args=(-f tee "$(youtube_record_tee_spec)")
    fi
    "$ffmpeg_bin" -y -hide_banner \
        -rw_timeout 10000000 \
        -reconnect 1 \
        -reconnect_at_eof 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -i "$input_url" \
        -map 0:v:0 \
        -map 0:a:0? \
        -c:v libx264 \
        -preset veryfast \
        -tune zerolatency \
        -pix_fmt yuv420p \
        -r 30 \
        -g 60 \
        -crf 23 \
        -c:a aac \
        -b:a 128k \
        -ar 44100 \
        -max_muxing_queue_size 1024 \
        "${output_args[@]}"
}

run_ffmpeg_transcode_pipe() {
    local ffmpeg_bin
    ffmpeg_bin="$(stable_ffmpeg_bin)"
    local output_args=(-f flv -flvflags no_duration_filesize "$FULL_RTMP")
    if recording_enabled; then
        print_info "同时录制已开启: ${RECORD_DIR}"
        output_args=(-f tee "$(youtube_record_tee_spec)")
    fi
    "$ffmpeg_bin" -y -hide_banner \
        -i pipe:0 \
        -map 0:v:0 \
        -map 0:a:0? \
        -c:v libx264 \
        -preset veryfast \
        -tune zerolatency \
        -pix_fmt yuv420p \
        -r 30 \
        -g 60 \
        -crf 23 \
        -c:a aac \
        -b:a 128k \
        -ar 44100 \
        -max_muxing_queue_size 1024 \
        "${output_args[@]}"
}

push_url_to_youtube() {
    local input_url="$1"
    local codec
    local log_file
    codec="$(detect_video_codec "$input_url")"
    log_file="$(ffmpeg_log_file)"

    if [ -n "$codec" ] && [ "$codec" != "h264" ]; then
        print_warn "Detected ${codec} stream, transcoding to H.264/AAC for YouTube RTMP..."
        local transcode_tmp
        transcode_tmp="$(mktemp /tmp/restream_ffmpeg_transcode.XXXXXX)"
        set +e
        run_ffmpeg_transcode_url "$input_url" 2>&1 | tee -a "$log_file" | tee "$transcode_tmp"
        local transcode_status=${PIPESTATUS[0]}
        set -e
        if [ "$transcode_status" -ne 0 ] && grep -Eiq "Connection timed out|Connection refused|No route to host" "$transcode_tmp"; then
            print_warn "VPS 无法直连抖音 CDN（转码模式），尝试通过代理获取流URL..."
            local proxy_stream
            proxy_stream="$(fetch_proxy_stream_url || true)"
            if [ -n "$proxy_stream" ] && echo "$proxy_stream" | grep -Eq "^https?://"; then
                print_ok "代理获取到流URL，使用代理中转推流..."
                local proxy_codec
                proxy_codec="$(detect_video_codec "$proxy_stream")"
                if [ -n "$proxy_codec" ] && [ "$proxy_codec" != "h264" ]; then
                    run_ffmpeg_transcode_url "$proxy_stream" 2>&1 | tee -a "$log_file" || true
                else
                    run_ffmpeg_copy_url "$proxy_stream" 2>&1 | tee -a "$log_file" || true
                fi
            else
                print_warn "代理也未获取到可用流URL"
            fi
        fi
        rm -f "$transcode_tmp"
        return 0
    fi

    local tmp_log
    local copy_status
    tmp_log="$(mktemp /tmp/restream_ffmpeg_copy.XXXXXX)"
    set +e
    run_ffmpeg_copy_url "$input_url" 2>&1 | tee -a "$log_file" | tee "$tmp_log"
    copy_status=${PIPESTATUS[0]}
    set -e

    # CDN 连接超时 → 尝试通过控制面板代理获取流URL
    if [ "$copy_status" -ne 0 ] && grep -Eiq "Connection timed out|Connection refused|No route to host" "$tmp_log"; then
        print_warn "VPS 无法直连抖音 CDN，尝试通过控制面板代理获取流URL..."
        local proxy_stream
        proxy_stream="$(fetch_proxy_stream_url || true)"
        if [ -n "$proxy_stream" ] && echo "$proxy_stream" | grep -Eq "^https?://"; then
            print_ok "代理获取到流URL，使用代理中转推流..."
            local proxy_codec
            proxy_codec="$(detect_video_codec "$proxy_stream")"
            if [ -n "$proxy_codec" ] && [ "$proxy_codec" != "h264" ]; then
                run_ffmpeg_transcode_url "$proxy_stream" 2>&1 | tee -a "$log_file" || true
            else
                run_ffmpeg_copy_url "$proxy_stream" 2>&1 | tee -a "$log_file" || true
            fi
        else
            print_warn "代理也未获取到可用流URL，保持当前状态等待重试"
        fi
        rm -f "$tmp_log"
        return 0
    fi

    if [ "$copy_status" -ne 0 ] && grep -Eiq "Video codec .*not implemented|dimensions not set|Could not write header|Could not find codec parameters|Invalid argument" "$tmp_log"; then
        print_warn "Copy mode failed on stream metadata, retrying with H.264/AAC transcode..."
        run_ffmpeg_transcode_url "$input_url" 2>&1 | tee -a "$log_file" || true
    fi

    rm -f "$tmp_log"
}

latest_recording_file() {
    if ! recording_fallback_enabled || [ ! -d "$RECORD_DIR" ]; then
        return 1
    fi
    find "$RECORD_DIR" -maxdepth 1 -type f \( -name "*.ts" -o -name "*.mp4" -o -name "*.mkv" \) \
        -size +1024c -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | head -n 1 \
        | sed 's/^[^ ]* //'
}

push_recorded_file_to_youtube() {
    local media_file="$1"
    local ffmpeg_bin log_file tmp_log copy_status
    ffmpeg_bin="$(stable_ffmpeg_bin)"
    log_file="$(ffmpeg_log_file)"
    tmp_log="$(mktemp /tmp/restream_record_fallback.XXXXXX)"

    print_warn "Pushing recorded fallback file in loop: $(basename "$media_file")"
    set +e
    "$ffmpeg_bin" -hide_banner -re -stream_loop -1 -fflags +genpts \
        -i "$media_file" \
        -map 0:v:0 -map 0:a:0? \
        -c copy \
        -max_muxing_queue_size 2048 \
        -f flv \
        -flvflags no_duration_filesize \
        "$FULL_RTMP" 2>&1 | tee -a "$log_file" | tee "$tmp_log"
    copy_status=${PIPESTATUS[0]}
    set -e

    if [ "$copy_status" -ne 0 ] && grep -Eiq "Could not write header|Invalid argument|codec .*not compatible|Video codec .*not implemented|dimensions not set|Could not find codec parameters" "$tmp_log"; then
        print_warn "Recorded fallback copy mode failed, retrying with H.264/AAC transcode..."
        set +e
        "$ffmpeg_bin" -hide_banner -re -stream_loop -1 -fflags +genpts \
            -i "$media_file" \
            -map 0:v:0 -map 0:a:0? \
            -c:v libx264 \
            -preset veryfast \
            -tune zerolatency \
            -pix_fmt yuv420p \
            -r 30 \
            -g 60 \
            -crf 23 \
            -c:a aac \
            -b:a 128k \
            -ar 44100 \
            -max_muxing_queue_size 2048 \
            -f flv \
            -flvflags no_duration_filesize \
            "$FULL_RTMP" 2>&1 | tee -a "$log_file"
        copy_status=${PIPESTATUS[0]}
        set -e
    fi

    rm -f "$tmp_log"
    return "$copy_status"
}

# 检查链接格式
if echo "$DOUYIN_URL" | grep -q "v.douyin.com"; then
    print_err "不支持 v.douyin.com 短链接！"
    echo ""
    echo "  请使用电脑浏览器打开抖音直播间，复制地址栏里的链接"
    echo "  正确格式: https://live.douyin.com/数字房间号"
    echo ""
    exit 1
fi

if ! echo "$DOUYIN_URL" | grep -q "live.douyin.com"; then
    print_warn "链接不是 live.douyin.com 格式，可能无法正常工作"
fi

rm -f "$STOP_FILE"
if recording_enabled; then
    rm -f "/tmp/douyin2yt_recording${RECORDING_ID}.stop"
fi
echo $$ > "$PID_FILE"
if recording_enabled; then
    echo $$ > "/tmp/douyin2yt_recording${RECORDING_ID}.pid"
fi

# 创建新进程组，方便一次性杀掉所有子进程（ffmpeg、streamlink、tee等）
set -m

cleanup() {
    # 关闭 set -e，确保清理一定执行完
    set +e
    print_info "正在停止转推..."
    # 先杀所有子进程（递归）
    pkill -TERM -P $$ 2>/dev/null
    sleep 1
    # 强杀残留
    pkill -9 -P $$ 2>/dev/null
    # 杀整个进程组
    kill -- -$$ 2>/dev/null
    rm -f "$PID_FILE"
    if recording_enabled; then
        rm -f "/tmp/douyin2yt_recording${RECORDING_ID}.pid"
    fi
    print_info "已停止。"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

for cmd in streamlink ffmpeg; do
    if ! command -v $cmd &>/dev/null; then
        print_err "缺少依赖: $cmd，请先安装"
        exit 1
    fi
done

mkdir -p "${SCRIPT_DIR}/logs"

echo ""
echo "=========================================="
echo "  抖音 → YouTube 实时转推 v3"
echo "=========================================="
echo ""
print_info "抖音直播间: $DOUYIN_URL"
print_info "YouTube推流: ${YOUTUBE_RTMP}/****"
print_info "画质: $QUALITY"
if recording_enabled; then
    print_info "同时录制: 开启 (${RECORD_FORMAT}, 每 ${RECORD_SEGMENT_SECONDS}s 分段)"
fi
echo ""

retry_count=0
wait_check_count=0
had_stream=false  # 标记是否曾经成功获取过流
recorded_fallback_used=false
consecutive_failures=0  # 连续失败次数（验证码/网络错误等非"主播未开播"的失败）
no_stream_count=0  # 连续"无流"次数，用于检测IP被封
MAX_CONSECUTIVE_FAILURES=8  # 连续失败8次（约2分钟）直接停止

# VPS级请求锁：同一VPS的任务串行请求，避免同时打Douyin
VPS_LOCK="/tmp/douyin2yt_vps.lock"

FALLBACK_AFTER_UNAVAILABLE_CHECKS="${FALLBACK_AFTER_UNAVAILABLE_CHECKS:-2}"  # 2 * 15s = 30s

has_backup_sources() {
    [ "${#BACKUP_URL_ARRAY[@]}" -gt 0 ] && [ -n "${BACKUP_URL_ARRAY[0]:-}" ]
}

switch_to_recorded_fallback() {
    if [ "$recorded_fallback_used" = true ]; then
        return 1
    fi
    if ! recording_fallback_enabled; then
        return 1
    fi
    if [ "$had_stream" != true ]; then
        return 1
    fi

    local media_file
    media_file="$(latest_recording_file || true)"
    if [ -z "$media_file" ] || [ ! -s "$media_file" ]; then
        print_warn "Recorded fallback is enabled, but no completed recording segment is available yet."
        return 1
    fi

    recorded_fallback_used=true
    print_warn "Live source is unavailable; switching to the current recording file loop."
    set +e
    push_recorded_file_to_youtube "$media_file"
    local fallback_status=$?
    set -e
    if [ "$fallback_status" -ne 0 ]; then
        print_warn "Recorded fallback stream ended with status ${fallback_status}; stopping task."
    fi
    cleanup
}

switch_to_next_backup() {
    CURRENT_SOURCE_INDEX=$((CURRENT_SOURCE_INDEX + 1))
    while [ "$CURRENT_SOURCE_INDEX" -lt "${#ALL_SOURCES[@]}" ]; do
        NEW_SOURCE="${ALL_SOURCES[$CURRENT_SOURCE_INDEX]:-}"
        if [ -n "$NEW_SOURCE" ]; then
            print_warn "Switching to backup source #${CURRENT_SOURCE_INDEX}: ${NEW_SOURCE:0:50}..."
            DOUYIN_URL="$NEW_SOURCE"
            wait_check_count=0
            no_stream_count=0
            retry_count=0
            had_stream=false
            interruptible_sleep 5
            return 0
        fi
        CURRENT_SOURCE_INDEX=$((CURRENT_SOURCE_INDEX + 1))
    done

    print_err "All backup sources have been tried. No available source remains."
    if switch_to_recorded_fallback; then
        return 0
    fi
    exit 0
}

try_backup_after_unavailable() {
    if ! has_backup_sources; then
        if [ "$wait_check_count" -ge "$FALLBACK_AFTER_UNAVAILABLE_CHECKS" ] || \
           [ "$no_stream_count" -ge "$FALLBACK_AFTER_UNAVAILABLE_CHECKS" ]; then
            if switch_to_recorded_fallback; then
                return 0
            fi
        fi
        return 1
    fi
    if [ "$no_stream_count" -lt "$FALLBACK_AFTER_UNAVAILABLE_CHECKS" ] && \
       [ "$wait_check_count" -lt "$FALLBACK_AFTER_UNAVAILABLE_CHECKS" ]; then
        return 1
    fi

    print_warn "Current source unavailable for ${wait_check_count} wait checks/${no_stream_count} no-stream checks; trying backup source..."
    switch_to_next_backup
}

while true; do
    if should_stop; then
        print_info "Stop flag detected, exiting."
        cleanup
    fi

    # 等待VPS锁（同一VPS的任务排队，避免同时请求）
    for _wait in $(seq 1 30); do
        if [ ! -f "$VPS_LOCK" ] || [ $(( $(date +%s) - $(stat -c %Y "$VPS_LOCK" 2>/dev/null || echo 0) )) -gt 10 ]; then
            break
        fi
        sleep 0.5
    done
    touch "$VPS_LOCK"
    # 随机延迟0-3秒，打散同一VPS的请求时间
    RANDOM_DELAY=$(awk "BEGIN{srand(); printf \"%.1f\", rand()*3}")
    sleep "$RANDOM_DELAY"

    print_info "正在检测主播是否在线..."

    # 用 --stream-url 获取真实流地址
    if [ -n "$COOKIE_ARG" ]; then
        STREAM_INFO=$(streamlink $COOKIE_ARG "$COOKIE_VAL" "$DOUYIN_URL" "$QUALITY" --stream-url 2>&1) || true
    else
        STREAM_INFO=$(streamlink "$DOUYIN_URL" "$QUALITY" --stream-url 2>&1) || true
    fi

    # 释放VPS锁
    rm -f "$VPS_LOCK"

    # 检测验证码/反爬（Douyin返回验证码中间页或无流）
    # 当VPS被封时，streamlink可能返回"No playable streams"而非验证码
    # 连续多次"No playable streams"也视为被封
    if echo "$STREAM_INFO" | grep -q "验证码中间页\|captcha\|verify" || \
       echo "$STREAM_INFO" | grep -q "No plugin can handle"; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            print_err "连续${consecutive_failures}次被拦截（疑似IP被封），自动停止。"
            exit 0
        fi
        # 尝试通过控制面板代理获取流URL
        print_warn "本机被封，尝试通过控制面板获取流URL..."
        PROXY_STREAM=$(fetch_proxy_stream_url || true)
        if [ -n "$PROXY_STREAM" ] && echo "$PROXY_STREAM" | grep -Eq "^https?://"; then
            print_ok "控制面板获取到流URL，直接推流..."
            push_url_to_youtube "$PROXY_STREAM"
            consecutive_failures=0
        else
            print_warn "代理获取失败，${CHECK_INTERVAL}秒后重试... [${consecutive_failures}/${MAX_CONSECUTIVE_FAILURES}]"
        fi
        interruptible_sleep "$CHECK_INTERVAL"
        continue
    fi

    if echo "$STREAM_INFO" | grep -q "currently offline"; then
        no_stream_count=$((no_stream_count + 1))
        consecutive_failures=0  # 主播未开播不算失败
        wait_check_count=$((wait_check_count + 1))
        if [ "$had_stream" = true ]; then
            # 曾经推流成功过，给更多耐心（主播可能临时下播）
            max_wait=120  # 30分钟
        else
            max_wait=$MAX_WAIT_CHECKS  # 15分钟
        fi
        if [ "$wait_check_count" -ge "$max_wait" ]; then
            print_err "等待超时（${wait_check_count}次检测无流），自动退出。"
            if switch_to_recorded_fallback; then
                continue
            fi
            exit 0
        fi
        print_warn "主播当前未开播，${CHECK_INTERVAL}秒后重试... [${wait_check_count}/${max_wait}]"
        if try_backup_after_unavailable; then
            continue
        fi
        interruptible_sleep "$CHECK_INTERVAL"
        continue
    fi

    if echo "$STREAM_INFO" | grep -q "No playable streams"; then
        # 可能是主播未开播，也可能是IP被封（被封时streamlink返回"No playable streams"而非验证码）
        # 先尝试网页直取：有些抖音直播 streamlink 会误报无流，但网页SSR里仍有可用FLV/HLS。
        no_stream_count=$((no_stream_count + 1))
        print_warn "streamlink 未发现可用流，尝试从抖音网页数据直取..."
        WEB_STREAM=$(fetch_douyin_web_stream_url || true)
        if [ -n "$WEB_STREAM" ] && echo "$WEB_STREAM" | grep -q "^https\\?://"; then
            print_ok "网页数据获取到直播流，直接推流..."
            had_stream=true
            wait_check_count=0
            no_stream_count=0
            push_url_to_youtube "$WEB_STREAM"
            interruptible_sleep "$CHECK_INTERVAL"
            continue
        fi
        # 连续多次无流时，尝试代理验证是否被封
        if [ "$no_stream_count" -ge 3 ] && [ -n "${CONTROL_PANEL_URL:-}" ]; then
            print_warn "连续${no_stream_count}次无流，尝试通过控制面板验证..."
            PROXY_STREAM=$(fetch_proxy_stream_url || true)
            if [ -n "$PROXY_STREAM" ] && echo "$PROXY_STREAM" | grep -Eq "^https?://"; then
                print_ok "控制面板获取到流URL（本机被封），直接推流..."
                had_stream=true
                wait_check_count=0
                no_stream_count=0
                push_url_to_youtube "$PROXY_STREAM"
                # ffmpeg结束后重新检测
                interruptible_sleep "$CHECK_INTERVAL"
                continue
            else
                # 控制面板也可能被抖音验证码拦截，不能直接断言主播未开播。
                no_stream_count=0
                print_warn "控制面板也未取到流，可能是源未开播或抖音取流被拦截。"
            fi
        fi
        wait_check_count=$((wait_check_count + 1))
        if [ "$had_stream" = true ]; then
            max_wait=120
        else
            max_wait=$MAX_WAIT_CHECKS
        fi
        if [ "$wait_check_count" -ge "$max_wait" ]; then
            print_err "等待超时（${wait_check_count}次检测无流），自动退出。"
            if switch_to_recorded_fallback; then
                continue
            fi
            exit 0
        fi
        print_warn "未找到可用的流，${CHECK_INTERVAL}秒后重试... [${wait_check_count}/${max_wait}]"
        if try_backup_after_unavailable; then
            continue
        fi
        interruptible_sleep "$CHECK_INTERVAL"
        continue
    fi

    if echo "$STREAM_INFO" | grep -q "No plugin can handle"; then
        print_err "streamlink 无法识别该链接: $DOUYIN_URL"
        print_err "请使用 https://live.douyin.com/房间号 格式"
        exit 1
    fi

    # 提取流URL。grep 没命中时不能触发 set -e 退出，否则会被 EXIT trap 伪装成“已停止”。
    STREAM_URL=$(printf '%s\n' "$STREAM_INFO" | grep -E "^https?://" | tail -1 || true)

    if [ -z "$STREAM_URL" ]; then
        print_warn "streamlink 未返回可用流地址，尝试从抖音网页数据直取..."
        WEB_STREAM=$(fetch_douyin_web_stream_url || true)
        if [ -n "$WEB_STREAM" ] && echo "$WEB_STREAM" | grep -q "^https\\?://"; then
            STREAM_URL="$WEB_STREAM"
            print_ok "网页数据获取到直播流"
        else
            print_warn "网页数据未取到流地址，尝试通过控制面板代理获取..."
            PROXY_STREAM=$(fetch_proxy_stream_url || true)
            if [ -n "$PROXY_STREAM" ] && echo "$PROXY_STREAM" | grep -Eq "^https?://"; then
                STREAM_URL="$PROXY_STREAM"
                print_ok "控制面板代理获取到直播流"
            fi
            if [ -z "$STREAM_URL" ]; then
                print_warn "网页数据也未取到流地址，保留重试队列。streamlink输出: $(echo "$STREAM_INFO" | head -c 180)"
            fi
        fi
    fi

    if [ -n "$STREAM_URL" ]; then
        print_ok "主播在线！获取到直播流"
        print_info "流地址: ${STREAM_URL:0:60}..."
        print_info "开始推流到 YouTube..."
        echo ""
        had_stream=true
        wait_check_count=0
        no_stream_count=0

        # ffmpeg 直接拉抖音流 → 推到 YouTube RTMP
        # -c copy = 不重新编码，延迟低、CPU占用极低
        push_url_to_youtube "$STREAM_URL"
    else
        if echo "$STREAM_INFO" | grep -Eiq "ValidationError|Unable to validate|error:"; then
            print_warn "streamlink 返回的是错误信息而不是媒体流，保持等待，避免向 YouTube 推送无效数据..."
            if try_backup_after_unavailable; then
                continue
            fi
            interruptible_sleep "$CHECK_INTERVAL"
            continue
        fi
        # fallback: pipe 模式
        print_ok "主播在线！使用管道模式转推..."
        echo ""

        if [ -n "$COOKIE_ARG" ]; then
            streamlink $COOKIE_ARG "$COOKIE_VAL" "$DOUYIN_URL" "$QUALITY" -O \
                --retry-streams "$CHECK_INTERVAL" \
                --retry-max 5 \
                --stream-timeout 120 \
                2>>"${SCRIPT_DIR}/logs/streamlink_$(date +%Y%m%d).log" | \
            run_ffmpeg_transcode_pipe 2>&1 | tee -a "$(ffmpeg_log_file)" || true
        else
            streamlink "$DOUYIN_URL" "$QUALITY" -O \
                --retry-streams "$CHECK_INTERVAL" \
                --retry-max 5 \
                --stream-timeout 120 \
                2>>"${SCRIPT_DIR}/logs/streamlink_$(date +%Y%m%d).log" | \
            run_ffmpeg_transcode_pipe 2>&1 | tee -a "$(ffmpeg_log_file)" || true
        fi
    fi

    if should_stop; then
        print_info "Stop flag detected after stream command, exiting."
        cleanup
    fi

    # ffmpeg/streamlink 结束后（推流中断）
    echo ""
    retry_count=$((retry_count + 1))

    if [ "$MAX_RETRIES" -gt 0 ] && [ "$retry_count" -ge "$MAX_RETRIES" ]; then
        print_err "已达到最大重试次数 ($MAX_RETRIES)，退出。"
        break
    fi

    if [ "$had_stream" = true ] && has_backup_sources; then
        print_warn "Current stream command ended after successful push; rechecking the current source before trying backup..."
    fi

    if [ "$had_stream" = true ]; then
        if switch_to_recorded_fallback; then
            continue
        fi
    fi

    print_warn "转推中断，${RETRY_WAIT}秒后重新检测..."
    interruptible_sleep "$RETRY_WAIT"
done

cleanup
