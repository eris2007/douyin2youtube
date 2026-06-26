#!/bin/bash
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <douyin live url> <recording id> [backup_urls_csv]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "${SCRIPT_DIR}/.env" ] && source "${SCRIPT_DIR}/.env"

SOURCE_URL="$1"
RECORDING_ID="$2"
BACKUP_URLS="${3:-}"
QUALITY="${RECORD_QUALITY:-best}"
RECORD_FORMAT="${RECORD_FORMAT:-ts}"
SEGMENT_SECONDS="${RECORD_SEGMENT_SECONDS:-900}"
MAX_RECORD_SECONDS="${RECORD_MAX_SECONDS:-0}"
RECORD_OUTPUT_NAME="${RECORD_OUTPUT_NAME:-}"
CONTROL_PANEL_URL="${CONTROL_PANEL_URL:-}"
PROXY_API_KEY="${PROXY_API_KEY:-}"
COOKIE_FILE="${SCRIPT_DIR}/cookie.txt"
COOKIE_VAL=""
if [ -f "$COOKIE_FILE" ] && [ -s "$COOKIE_FILE" ]; then
  COOKIE_VAL="$(cat "$COOKIE_FILE" | tr -d '\n')"
fi

PID_ID="recording${RECORDING_ID}"
PID_FILE="/tmp/douyin2yt_${PID_ID}.pid"
STOP_FILE="/tmp/douyin2yt_${PID_ID}.stop"
LOG_FILE="${SCRIPT_DIR}/logs/recording_${RECORDING_ID}.log"
OUTPUT_DIR="${SCRIPT_DIR}/uploads/recordings/recording_${RECORDING_ID}"
mkdir -p "${SCRIPT_DIR}/logs" "$OUTPUT_DIR"
rm -f "$STOP_FILE"

if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && ps -p "$OLD_PID" >/dev/null 2>&1; then
    echo "recording already running PID: $OLD_PID"
    exit 0
  fi
fi

nohup bash -c '
set -euo pipefail
export TZ=Asia/Shanghai
SCRIPT_DIR="$1"
SOURCE_URL="$2"
RECORDING_ID="$3"
BACKUP_URLS="$4"
QUALITY="$5"
RECORD_FORMAT="$6"
SEGMENT_SECONDS="$7"
CONTROL_PANEL_URL="$8"
PROXY_API_KEY="$9"
COOKIE_VAL="${10}"
MAX_RECORD_SECONDS="${11:-0}"
RECORD_OUTPUT_NAME="${12:-}"
case "$MAX_RECORD_SECONDS" in
  ""|*[!0-9]*) MAX_RECORD_SECONDS=0 ;;
esac
START_EPOCH="$(date +%s)"
PID_ID="recording${RECORDING_ID}"
PID_FILE="/tmp/douyin2yt_${PID_ID}.pid"
STOP_FILE="/tmp/douyin2yt_${PID_ID}.stop"
OUTPUT_DIR="${SCRIPT_DIR}/uploads/recordings/recording_${RECORDING_ID}"
LOG_FILE="${SCRIPT_DIR}/logs/recording_${RECORDING_ID}.log"
CHECK_INTERVAL=15
MAX_WAIT_CHECKS=120
FALLBACK_AFTER_UNAVAILABLE_CHECKS="${FALLBACK_AFTER_UNAVAILABLE_CHECKS:-2}"
echo $$ > "$PID_FILE"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
recording_prefix() {
  if [ -n "${RECORD_OUTPUT_NAME:-}" ]; then
    printf "%s" "$RECORD_OUTPUT_NAME"
  else
    printf "recording_%s" "$RECORDING_ID"
  fi
}
max_duration_reached() {
  [ "$MAX_RECORD_SECONDS" -gt 0 ] && [ $(( $(date +%s) - START_EPOCH )) -ge "$MAX_RECORD_SECONDS" ]
}
remaining_seconds() {
  if [ "$MAX_RECORD_SECONDS" -le 0 ]; then
    echo 0
    return
  fi
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  local remain=$(( MAX_RECORD_SECONDS - elapsed ))
  [ "$remain" -gt 0 ] && echo "$remain" || echo 0
}
should_stop() { [ -f "$STOP_FILE" ] || max_duration_reached; }
cleanup() {
  set +e
  pkill -TERM -P $$ 2>/dev/null || true
  sleep 1
  pkill -9 -P $$ 2>/dev/null || true
  rm -f "$PID_FILE"
  log "recording stopped"
  exit 0
}
trap cleanup INT TERM EXIT

fetch_proxy_stream_url() {
  local panel_url="${CONTROL_PANEL_URL:-http://restream.ytdeepsea.com}"
  [ -n "$PROXY_API_KEY" ] || return 1
  curl -s --max-time 35 -G \
    -H "X-Proxy-Api-Key: ${PROXY_API_KEY}" \
    --data-urlencode "url=${SOURCE_URL}" \
    "${panel_url}/api/proxy/stream-url" |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"stream_url\", \"\"))" 2>/dev/null
}

fetch_web_stream_url() {
  local tmp_page
  tmp_page=$(mktemp /tmp/douyin_record_page.XXXXXX) || return 1
  local curl_args=(-L -sS --max-time 25 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36" -H "referer: https://www.douyin.com/")
  if [ -n "${COOKIE_VAL:-}" ]; then
    curl_args+=(-H "cookie: ${COOKIE_VAL}")
  fi
  curl "${curl_args[@]}" "$SOURCE_URL" -o "$tmp_page" 2>/dev/null || { rm -f "$tmp_page"; return 1; }
  python3 - "$tmp_page" <<'"'"'PY'"'"'
import html, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
def norm(raw): return html.unescape(raw).replace("\\u0026", "&").replace("\\/", "/")
urls = []
for blob in (text, norm(text)):
    blob = norm(blob)
    for url in re.findall(r"https?://[^\"<>\s\\]+", blob):
        lower = url.lower()
        if (".flv" in lower or ".m3u8" in lower) and ("douyin" in lower or "byte" in lower):
            if "only_audio=1" not in lower:
                urls.append(norm(url))
seen, deduped = set(), []
for url in urls:
    if url not in seen:
        seen.add(url)
        deduped.append(url)
def score(url):
    lower = url.lower()
    value = 100 if ".flv" in lower else 0
    if any(x in lower for x in ("h265", "hevc", "_hd5", "_sd5", "_or5")):
        value -= 1000
    if "_uhd" in lower or "full_hd" in lower:
        value += 30
    if "_hd" in lower:
        value += 20
    return value
if deduped:
    print(max(deduped, key=score))
PY
  local status=$?
  rm -f "$tmp_page"
  return "$status"
}

record_url() {
  local input_url="$1"
  local remain
  remain="$(remaining_seconds)"
  if [ "$MAX_RECORD_SECONDS" -gt 0 ] && [ "$remain" -le 0 ]; then
    cleanup
  fi
  local duration_args=()
  if [ "$MAX_RECORD_SECONDS" -gt 0 ]; then
    duration_args=(-t "$remain")
  fi
  local ext="$RECORD_FORMAT"
  local segment_format="mpegts"
  if [ "$ext" = "mkv" ]; then
    segment_format="matroska"
  elif [ "$ext" = "mp4" ]; then
    segment_format="mp4"
  else
    ext="ts"
    segment_format="mpegts"
  fi
  local prefix pattern
  prefix="$(recording_prefix)"
  pattern="${OUTPUT_DIR}/${prefix}_%Y%m%d_%H%M%S.${ext}"
  log "recording stream to ${pattern}, segment=${SEGMENT_SECONDS}s, quality=${QUALITY}"
  ffmpeg -y -hide_banner \
    -rw_timeout 10000000 \
    -reconnect 1 \
    -reconnect_at_eof 1 \
    -reconnect_streamed 1 \
    -reconnect_delay_max 5 \
    -i "$input_url" \
    "${duration_args[@]}" \
    -map 0:v:0 -map 0:a:0? \
    -c copy \
    -f segment \
    -segment_time "$SEGMENT_SECONDS" \
    -segment_format "$segment_format" \
    -reset_timestamps 1 \
    -strftime 1 \
    "$pattern" 2>&1 | tee -a "$LOG_FILE" || true
}

IFS="," read -ra BACKUPS <<< "$BACKUP_URLS"
SOURCES=("$SOURCE_URL" "${BACKUPS[@]}")
source_index=0
wait_count=0
while true; do
  should_stop && cleanup
  SOURCE_URL="${SOURCES[$source_index]:-}"
  [ -n "$SOURCE_URL" ] || cleanup
  log "checking source: ${SOURCE_URL}"
  if [ -n "${COOKIE_VAL:-}" ]; then
    STREAM_INFO=$(streamlink --http-cookie "$COOKIE_VAL" "$SOURCE_URL" "$QUALITY" --stream-url 2>&1) || true
  else
    STREAM_INFO=$(streamlink "$SOURCE_URL" "$QUALITY" --stream-url 2>&1) || true
  fi
  STREAM_URL=$(printf "%s\n" "$STREAM_INFO" | grep -E "^https?://" | tail -1 || true)
  if [ -z "$STREAM_URL" ]; then
    STREAM_URL=$(fetch_web_stream_url || true)
  fi
  if [ -z "$STREAM_URL" ]; then
    STREAM_URL=$(fetch_proxy_stream_url || true)
  fi
  if [ -n "$STREAM_URL" ]; then
    wait_count=0
    log "stream found, recording started"
    record_url "$STREAM_URL"
    should_stop && cleanup
    sleep "$CHECK_INTERVAL"
    continue
  fi
  wait_count=$((wait_count + 1))
  if [ "$wait_count" -ge "$FALLBACK_AFTER_UNAVAILABLE_CHECKS" ] && [ $((source_index + 1)) -lt "${#SOURCES[@]}" ]; then
    source_index=$((source_index + 1))
    wait_count=0
    log "source unavailable, switching to backup source #${source_index}"
  elif [ "$wait_count" -ge "$MAX_WAIT_CHECKS" ]; then
    source_index=$((source_index + 1))
    wait_count=0
    if [ "$source_index" -ge "${#SOURCES[@]}" ]; then
      log "no source available, exiting"
      cleanup
    fi
    log "switching to backup source #${source_index}"
  else
    log "no stream, retrying in ${CHECK_INTERVAL}s [${wait_count}/${MAX_WAIT_CHECKS}]"
    sleep "$CHECK_INTERVAL"
  fi
done
' _ "$SCRIPT_DIR" "$SOURCE_URL" "$RECORDING_ID" "$BACKUP_URLS" "$QUALITY" "$RECORD_FORMAT" "$SEGMENT_SECONDS" "${CONTROL_PANEL_URL:-}" "${PROXY_API_KEY:-}" "${COOKIE_VAL:-}" "$MAX_RECORD_SECONDS" "$RECORD_OUTPUT_NAME" >> "$LOG_FILE" 2>&1 &

sleep 1
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  echo "recording started | PID: $PID"
  echo "output: $OUTPUT_DIR"
else
  echo "recording start failed, check log: $LOG_FILE"
  exit 1
fi
