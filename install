#!/bin/sh
set -eu

# ===== CONFIG FILES =====
COMMON="/opt/kvas-sync/conf/common.conf"
DEVICE="/opt/kvas-sync/conf/device.conf"
SECRETS="/opt/kvas-sync/conf/secrets.conf"

[ -f "$COMMON" ] && . "$COMMON"
[ -f "$DEVICE" ] && . "$DEVICE"
[ -f "$SECRETS" ] && . "$SECRETS"

# ===== DEFAULTS =====
: "${WORKDIR:=/opt/kvas-sync}"
: "${STATE_DIR:=$WORKDIR/state}"
: "${LOG_FILE:=$WORKDIR/log/kvas-sync.log}"
: "${LIST_URL:=}"
: "${ROUTER_NAME:=Router}"
: "${IMPORT_CMD:=kvas import}"

: "${MIN_LINES:=200}"
: "${MAX_LINES:=3500}"

: "${CURL_TIMEOUT:=25}"
: "${PING_URL:=https://raw.githubusercontent.com/}"
: "${RETRY_COUNT:=3}"
: "${RETRY_DELAY:=8}"

: "${IMPORT_TIMEOUT:=2700}"

mkdir -p "$STATE_DIR" "$WORKDIR/log" "$WORKDIR/tmp"

LOCK_DIR="$STATE_DIR/import.lock"

NEW_RAW="$STATE_DIR/inside-kvas.new.raw.lst"
NEW_NORM="$STATE_DIR/inside-kvas.new.norm.lst"
CUR_FILE="$STATE_DIR/inside-kvas.cur.lst"

TPL_OK="$WORKDIR/conf/tg_ok.tpl"
TPL_SAME="$WORKDIR/conf/tg_same.tpl"
TPL_ERR="$WORKDIR/conf/tg_err.tpl"

ts()    { date '+%Y-%m-%d %H:%M:%S'; }
dt_ru() { date '+%d.%m.%Y %H:%M:%S МСК'; }

log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# экранирование для sed replacement: \ / &
esc_sed() { printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'; }

# ===== TELEGRAM =====
tg_send() {
  msg="$1"

  if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
    log "TG: skip (no token/chat_id)"
    return 0
  fi

  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    >/dev/null 2>&1 || log "TG: send failed"
}

sha_full() { sha256sum "$1" | awk '{print $1}'; }

sha_show4() {
  h="$1"
  printf "%s…%s" "$(printf '%s' "$h" | cut -c1-4)" "$(printf '%s' "$h" | cut -c61-64)"
}

normalize_list() {
  in="$1"; out="$2"
  sed 's/\r$//' "$in" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u > "$out"
}

download_with_retry() {
  url="$1"; out="$2"
  n=1
  while [ "$n" -le "$RETRY_COUNT" ]; do
    # ping
    curl -fsSL --max-time "$CURL_TIMEOUT" "$PING_URL" >/dev/null 2>&1 || true

    if curl -fsSL --max-time "$CURL_TIMEOUT" "$url" -o "$out"; then
      return 0
    fi
    log "download retry $n/$RETRY_COUNT failed"
    n=$((n+1))
    sleep "$RETRY_DELAY"
  done
  return 1
}

render_and_send() {
  tpl="$1"
  tmp="$WORKDIR/tmp/tg_msg.txt"

  [ -f "$tpl" ] || { log "TPL missing: $tpl"; return 0; }

  cp "$tpl" "$tmp"

  R_ESC="$(esc_sed "$ROUTER_NAME")"
  L_ESC="$(esc_sed "$LINES")"
  S_ESC="$(esc_sed "$SHA_SHOW")"
  D_ESC="$(esc_sed "$DT")"

  # ERR vars might be unused in ok/same templates but keep harmless
  E1_ESC="$(esc_sed "${ERR_TITLE:-}")"
  E2_ESC="$(esc_sed "${ERR_LINES:-}")"

  sed -i \
    -e "s/{{ROUTER_NAME}}/${R_ESC}/g" \
    -e "s/{{LINES}}/${L_ESC}/g" \
    -e "s/{{SHA}}/${S_ESC}/g" \
    -e "s/{{DT}}/${D_ESC}/g" \
    -e "s/{{ERR_TITLE}}/${E1_ESC}/g" \
    -e "s/{{ERR_LINES}}/${E2_ESC}/g" \
    "$tmp" || true

  tg_send "$(cat "$tmp")"
}

# ===== MAIN =====
[ -n "$LIST_URL" ] || { log "LIST_URL empty"; exit 1; }

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM"

if ! download_with_retry "$LIST_URL" "$NEW_RAW"; then
  log "download failed"
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• —"
  render_and_send "$TPL_ERR"
  exit 1
fi

# HTML check
head -n 2 "$NEW_RAW" | grep -qi '<!doctype\|<html' && {
  log "download returned HTML"
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• HTML вместо списка"
  render_and_send "$TPL_ERR"
  exit 1
}

normalize_list "$NEW_RAW" "$NEW_NORM"

LINES="$(wc -l < "$NEW_NORM" | tr -d ' ')"
SHA="$(sha_full "$NEW_NORM")"
SHA_SHOW="$(sha_show4 "$SHA")"

if [ "$LINES" -lt "$MIN_LINES" ] || [ "$LINES" -gt "$MAX_LINES" ]; then
  log "lines out of bounds: $LINES"
  ERR_TITLE="Некорректный размер списка"
  ERR_LINES="• строк: $LINES (ожидалось $MIN_LINES..$MAX_LINES)"
  render_and_send "$TPL_ERR"
  exit 1
fi

if [ -f "$CUR_FILE" ]; then
  SHA_CUR="$(sha_full "$CUR_FILE")"
else
  SHA_CUR=""
fi

if [ -n "$SHA_CUR" ] && [ "$SHA_CUR" = "$SHA" ]; then
  log "SAME: normalized sha matched"
  render_and_send "$TPL_SAME"
  exit 0
fi

# ===== IMPORT =====
if timeout "$IMPORT_TIMEOUT" sh -c "$IMPORT_CMD '$NEW_NORM'"; then
  cp "$NEW_NORM" "$CUR_FILE"
  log "IMPORT OK"
  render_and_send "$TPL_OK"
else
  log "IMPORT FAILED"
  ERR_TITLE="Ошибка импорта"
  ERR_LINES="• команда: $IMPORT_CMD"
  render_and_send "$TPL_ERR"
fi

exit 0
