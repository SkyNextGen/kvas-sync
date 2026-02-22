#!/bin/sh

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
KVAS="${KVAS:-/opt/bin/kvas}"
DIAG_LOG="${DIAG_LOG:-/opt/kvas-sync/log/diag.log}"
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
  # Пишем в консоль (SSH), в основной лог и в диагностический лог.
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="[$ts] $*"

  # stdout (видно при ручном запуске через SSH)
  echo "$line"

  # основной лог (если задан)
  if [ -n "${LOG_FILE:-}" ]; then
    printf "%s\n" "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # диагностический лог (для диагностики)
  if [ -n "${DIAG_LOG:-}" ]; then
    mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null || true
    printf "%s\n" "$line" >> "$DIAG_LOG" 2>/dev/null || true
  fi
}
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


  # KVAS: после kvas update иногда ломается DNS-резолв (что бьёт отправку в TG).
  # 1) Принудительно включаем шифрование DNS (если бинарник доступен)
  # 2) Ждём восстановления резолва до 30 секунд (выходим раньше при успехе)
  # 3) Если локальный резолв не поднялся, используем аварийный nameserver ТОЛЬКО для curl в TG
  if [ -x "$KVAS" ]; then
    log "KVAS: crypt on (before TG)"
    "$KVAS" crypt on 2>&1 | while IFS= read -r line; do log "KVAS: $line"; done
  else
    log "KVAS: not found/executable at $KVAS (PATH=$PATH)"
  fi

  t=0
  while [ "$t" -lt 30 ]; do
    nslookup api.telegram.org >/dev/null 2>&1 && break
    sleep 1
    t=$((t+1))
  done

  if nslookup api.telegram.org >/dev/null 2>&1; then
    log "DNS: ok after ${t}s"
  else
    log "DNS: still broken after ${t}s, trying fallback resolvers for TG"
    # Пробуем публичные DNS, чтобы хотя бы уведомление ушло
    fallback=""
    nslookup api.telegram.org 1.1.1.1 >/dev/null 2>&1 && fallback="1.1.1.1"
    [ -z "$fallback" ] && nslookup api.telegram.org 8.8.8.8 >/dev/null 2>&1 && fallback="8.8.8.8"

    if [ -n "$fallback" ]; then
      TG_RESOLV="/tmp/kvas-sync.tg-resolv.conf"
      printf "nameserver %s
" "$fallback" > "$TG_RESOLV"
      RESOLV_CONF="$TG_RESOLV"
      export RESOLV_CONF
      log "DNS: using fallback nameserver ${fallback} via RESOLV_CONF=${TG_RESOLV} for TG curl"
    else
      log "DNS: fallback resolvers also failed"
    fi
  fi


# KVAS: после kvas update иногда падает DNS-шифрование.
# Принудительно включаем перед отправкой в TG и даём время примениться.
if command -v kvas >/dev/null 2>&1; then
  kvas crypt on || true
fi

# Таймаут перед отправкой (по требованию)
# Ставим ДО ретраев, чтобы не умножать задержку на каждую попытку.
# Ожидание восстановления DNS после kvas update/crypt on.
# Ждём до 30 секунд, выходим раньше при успешном резолве.
t=0
while [ "$t" -lt 30 ]; do
  nslookup api.telegram.org >/dev/null 2>&1 && break
  sleep 1
  t=$((t+1))
done

  # Для Entware: иногда curl берёт не тот resolv.conf
  if [ -f /opt/etc/resolv.conf ]; then
    RESOLV_CONF="/opt/etc/resolv.conf"
    export RESOLV_CONF
  fi

  # После чистой установки сеть/DNS могут подняться не сразу → ретраи + warm-up
  tries=5
  delay=6

  i=1
  while [ "$i" -le "$tries" ]; do
    nslookup api.telegram.org >/dev/null 2>&1 || true

    resp="$(curl -sS -m 20 -X POST \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" 2>&1)" && {
        echo "$resp" | grep -q '"ok":true' && return 0
        log "TG: api error: $resp"
        return 0
      }

    log "TG: send failed (try ${i}/${tries}): $resp"
    i=$((i+1))
    sleep "$delay"
  done

  return 0
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

[ -n "$LIST_URL" ] || { log "LIST_URL empty"; exit 1; }

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM"

if ! download_with_retry "$LIST_URL" "$NEW_RAW"; then
  log "download failed"
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• download failed"
  render_and_send "$TPL_ERR"
  exit 1
fi

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
