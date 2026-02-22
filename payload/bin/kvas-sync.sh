#!/bin/sh
set -eu

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
KVAS="/opt/bin/kvas"
DIAG_LOG="${DIAG_LOG:-/opt/kvas-sync/log/diag.log}"

# Гарантия: после любых операций (в т.ч. kvas update) возвращаем DNS-шифрование.
# Это ловит кейс, когда update/импорт сбрасывает crypt в OFF.


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

log() {
  # stdout (видно при ручном запуске), основной лог и диагностический лог
  line="[$(ts)] $*"
  echo "$line"
  printf "%s
" "$line" >> "$LOG_FILE" 2>/dev/null || true
  if [ -n "${DIAG_LOG:-}" ]; then
    mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null || true
    printf "%s
" "$line" >> "$DIAG_LOG" 2>/dev/null || true
  fi
}

force_crypt_on() {
  # Принудительно включаем DNS-шифрование KVAS.
  # Важно: используем абсолютный путь, чтобы работало и из cron.
  if [ -x "$KVAS" ]; then
    log "KVAS: force crypt on"
    "$KVAS" crypt on 2>&1 | while IFS= read -r line; do log "KVAS: $line"; done || true
  else
    log "KVAS: binary not found at $KVAS (PATH=$PATH)"
  fi
}

ensure_dnscrypt_running() {
  # dnsmasq завязан на локальный dnscrypt-proxy (обычно порт 9153).
  # Если dnscrypt не слушает порт — принудительно поднимаем через `kvas crypt on`.
  # Это лечит кейс, когда после `kvas update` dnscrypt остаётся остановленным и DNS "умирает".
  port="${1:-9153}"

  if netstat -ln 2>/dev/null | grep -q ":${port}"; then
    log "DNSCRYPT: already listening on :${port}"
    return 0
  fi

  log "DNSCRYPT: not listening on :${port}, forcing start via KVAS"
  force_crypt_on

  i=0
  while [ "$i" -lt 10 ]; do
    netstat -ln 2>/dev/null | grep -q ":${port}" && { log "DNSCRYPT: up after ${i}s"; return 0; }
    sleep 1
    i=$((i+1))
  done

  log "DNSCRYPT: still NOT listening on :${port} after ${i}s"
  return 1
}

trap force_crypt_on EXIT



esc_sed() { printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'; }

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

tg_send() {
  msg="$1"

  if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
    log "TG: skip (no token/chat_id)"
    return 0
  fi
  ensure_dnscrypt_running 9153 || true
  # KVAS/DNS: перед отправкой в TG принудительно включаем DNS-шифрование и ждём восстановления резолва.
  force_crypt_on
  # Доп. проверка резолва после поднятия dnscrypt (best-effort)
  nslookup api.telegram.org >/dev/null 2>&1 && log "DNS: resolver ok (api.telegram.org)" || log "DNS: resolver still failing (api.telegram.org)"
else
  log "KVAS: not found/executable at $KVAS (PATH=$PATH)"
fi
# -------------------------------------------------------


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
