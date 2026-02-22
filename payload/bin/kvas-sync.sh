#!/bin/sh
set -eu

# =========================
# KVAS-SYNC Router Agent
# =========================

COMMON="/opt/kvas-sync/conf/common.conf"
DEVICE="/opt/kvas-sync/conf/device.conf"
SECRETS="/opt/kvas-sync/conf/secrets.conf"

[ -f "$COMMON" ] && . "$COMMON"
[ -f "$DEVICE" ] && . "$DEVICE"
[ -f "$SECRETS" ] && . "$SECRETS"

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

: "${KVAS_UPDATE_TIMEOUT:=900}"
: "${KVAS_UPDATE_RETRY:=2}"

: "${IMPORT_TIMEOUT:=2700}"

TPL_OK="$WORKDIR/conf/tg_ok.tpl"
TPL_SAME="$WORKDIR/conf/tg_same.tpl"
TPL_ERR="$WORKDIR/conf/tg_err.tpl"

NEW_RAW="$STATE_DIR/inside-kvas.new.raw.lst"
NEW_NORM="$STATE_DIR/inside-kvas.new.norm.lst"
CUR_FILE="$STATE_DIR/inside-kvas.cur.lst"
LOCK_DIR="$STATE_DIR/import.lock"

# TG / DNS
RESOLV_FILE="/opt/etc/resolv.conf"
# Можно поменять на публичные DNS, если 127.0.0.1 у вас вдруг не работает:
# RESOLV_CONTENT="nameserver 1.1.1.1\nnameserver 8.8.8.8"
RESOLV_CONTENT="nameserver 127.0.0.1"

# -------------------------
# utils
# -------------------------

ts() { date '+%Y-%m-%d %H:%M:%S'; }
dt_ru() { date '+%d.%m.%Y %H:%M:%S МСК'; }

log() {
  echo "[$(ts)] $*" >> "$LOG_FILE"
}

sha_full() {
  sha256sum "$1" | awk '{print $1}'
}

sha_show4() {
  h="$1"
  a="$(printf '%s' "$h" | cut -c1-4)"
  b="$(printf '%s' "$h" | cut -c61-64)"
  printf '%s…%s' "$a" "$b"
}

normalize_list() {
  in="$1"
  out="$2"
  # trim, remove CR, drop empty, uniq
  sed 's/\r$//' "$in" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u > "$out"
}

download_with_retry() {
  url="$1"
  out="$2"

  n=1
  while [ "$n" -le "$RETRY_COUNT" ]; do
    # ping check (helps to warm up DNS/route)
    curl -fsSL --max-time "$CURL_TIMEOUT" "$PING_URL" >/dev/null 2>&1 || true

    if curl -fsSL --max-time "$CURL_TIMEOUT" "$url" -o "$out" >/dev/null 2>&1; then
      return 0
    fi
    log "download try $n/$RETRY_COUNT failed"
    n=$((n+1))
    sleep "$RETRY_DELAY"
  done
  return 1
}

# -------------------------
# DNS fix for Entware curl
# -------------------------

ensure_resolv_for_curl() {
  # Entware curl иногда не видит /etc/resolv.conf (там бывает только options),
  # поэтому создаём /opt/etc/resolv.conf и используем через RESOLV_CONF.
  mkdir -p /opt/etc 2>/dev/null || true
  if [ ! -s "$RESOLV_FILE" ]; then
    # shell-safe write
    printf "%s\n" "$RESOLV_CONTENT" > "$RESOLV_FILE" 2>/dev/null || true
  fi
}

curl_tg() {
  # Используем RESOLV_CONF принудительно
  ensure_resolv_for_curl
  RESOLV_CONF="$RESOLV_FILE" curl "$@"
}

# -------------------------
# Telegram send (with retry)
# -------------------------

tg_send() {
  msg="$1"

  [ -n "${BOT_TOKEN:-}" ] || { log "TG: skip (no token)"; return 0; }
  [ -n "${CHAT_ID:-}" ] || { log "TG: skip (no chat_id)"; return 0; }

  # Небольшая пауза на “прогрев” DNS/маршрута (особенно сразу после install)
  sleep 2

  api="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

  t=1
  while [ "$t" -le 5 ]; do
    # пишем ответ в переменную, чтобы залогировать
    resp="$(curl_tg -sS -X POST "$api" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" 2>&1)" && rc=0 || rc=$?

    if [ "$rc" -eq 0 ]; then
      # ok:true?
      echo "$resp" | grep -q '"ok":true' && { log "TG: sent"; return 0; }
      log "TG: api error: $resp"
      return 1
    fi

    log "TG: send failed (try $t/5): $resp"
    t=$((t+1))
    sleep 6
  done

  return 1
}

# -------------------------
# template render
# -------------------------

esc_sed() {
  # escape / & \ for sed replacement
  printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'
}

render_and_send() {
  tpl="$1"
  tmp="$WORKDIR/tmp/tg_msg.txt"

  [ -f "$tpl" ] || { log "TG: template missing: $tpl"; return 1; }

  cp "$tpl" "$tmp"

  R_ESC="$(esc_sed "$ROUTER_NAME")"
  L_ESC="$(esc_sed "${LINES:-}")"
  S_ESC="$(esc_sed "${SHA_SHOW:-}")"
  D_ESC="$(esc_sed "${DT:-}")"
  E1_ESC="$(esc_sed "${ERR_TITLE:-}")"
  E2_ESC="$(esc_sed "${ERR_LINES:-}")"

  sed -i \
    -e "s/{{ROUTER_NAME}}/${R_ESC}/g" \
    -e "s/{{LINES}}/${L_ESC}/g" \
    -e "s/{{SHA}}/${S_ESC}/g" \
    -e "s/{{DT}}/${D_ESC}/g" \
    -e "s/{{ERR_TITLE}}/${E1_ESC}/g" \
    -e "s/{{ERR_LINES}}/${E2_ESC}/g" \
    "$tmp" 2>/dev/null || true

  tg_send "$(cat "$tmp")" || true
}

# -------------------------
# main
# -------------------------

[ -n "$LIST_URL" ] || { log "LIST_URL empty"; exit 1; }

mkdir -p "$STATE_DIR" "$WORKDIR/log" "$WORKDIR/tmp" 2>/dev/null || true
: > "$LOG_FILE" 2>/dev/null || true

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM" 2>/dev/null || true

if ! download_with_retry "$LIST_URL" "$NEW_RAW"; then
  log "download failed"
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• download failed"
  render_and_send "$TPL_ERR"
  exit 1
fi

# защита: если скачали HTML вместо списка
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
  ERR_LINES="• строк: $LINES"
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

# import
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
