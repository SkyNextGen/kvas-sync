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
: "${IMPORT_TIMEOUT:=2700}"

TPL_OK="$WORKDIR/conf/tg_ok.tpl"
TPL_SAME="$WORKDIR/conf/tg_same.tpl"
TPL_ERR="$WORKDIR/conf/tg_err.tpl"

NEW_RAW="$STATE_DIR/inside-kvas.new.raw.lst"
NEW_NORM="$STATE_DIR/inside-kvas.new.norm.lst"
CUR_FILE="$STATE_DIR/inside-kvas.cur.lst"
LOCK_DIR="$STATE_DIR/import.lock"

RESOLV_FILE="/opt/etc/resolv.conf"
RESOLV_CONTENT="nameserver 127.0.0.1"

# -------------------------
# Utils
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
  sed 's/\r$//' "$1" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u > "$2"
}

# -------------------------
# DNS / KVAS Recovery
# -------------------------

ensure_resolv_for_curl() {
  mkdir -p /opt/etc 2>/dev/null || true
  if [ ! -s "$RESOLV_FILE" ]; then
    printf "%s\n" "$RESOLV_CONTENT" > "$RESOLV_FILE" 2>/dev/null || true
  fi
}

curl_tg() {
  ensure_resolv_for_curl
  RESOLV_CONF="$RESOLV_FILE" curl "$@"
}

kvas_crypt_is_off() {
  kvas crypt 2>/dev/null | grep -qi 'ОТКЛЮЧЕНО'
}

ensure_kvas_crypt_on() {
  command -v kvas >/dev/null 2>&1 || return 0
  if kvas_crypt_is_off; then
    log "KVAS: DNS crypt OFF -> enabling"
    kvas crypt on >/dev/null 2>&1 || true
    sleep 2
  fi
}

dns_ok() {
  nslookup api.telegram.org >/dev/null 2>&1 && return 0
  curl -fsSL --max-time 10 "$PING_URL" >/dev/null 2>&1 && return 0
  return 1
}

post_kvas_dns_recover() {
  ensure_kvas_crypt_on
  i=1
  while [ "$i" -le 5 ]; do
    dns_ok && { log "DNS: ok (try $i/5)"; return 0; }
    log "DNS: still bad (try $i/5)"
    ensure_kvas_crypt_on
    sleep 3
    i=$((i+1))
  done
  return 1
}

# -------------------------
# Telegram send
# -------------------------

tg_send() {
  msg="$1"

  [ -n "${BOT_TOKEN:-}" ] || { log "TG: no token"; return 0; }
  [ -n "${CHAT_ID:-}" ] || { log "TG: no chat_id"; return 0; }

  post_kvas_dns_recover || log "DNS: recovery failed before TG"

  api="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

  t=1
  while [ "$t" -le 5 ]; do
    resp="$(curl_tg -sS -X POST "$api" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" 2>&1)" && rc=0 || rc=$?

    if [ "$rc" -eq 0 ]; then
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
# Template
# -------------------------

esc_sed() {
  printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'
}

render_and_send() {
  tpl="$1"
  tmp="$WORKDIR/tmp/tg_msg.txt"

  [ -f "$tpl" ] || { log "TG: template missing"; return 1; }

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
# Main
# -------------------------

[ -n "$LIST_URL" ] || { log "LIST_URL empty"; exit 1; }

mkdir -p "$STATE_DIR" "$WORKDIR/log" "$WORKDIR/tmp" 2>/dev/null || true

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM" 2>/dev/null || true

# download
n=1
while [ "$n" -le "$RETRY_COUNT" ]; do
  curl -fsSL --max-time "$CURL_TIMEOUT" "$LIST_URL" -o "$NEW_RAW" && break
  log "download try $n failed"
  n=$((n+1))
  sleep "$RETRY_DELAY"
done

[ -f "$NEW_RAW" ] || {
  log "download failed"
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• download failed"
  render_and_send "$TPL_ERR"
  exit 1
}

normalize_list "$NEW_RAW" "$NEW_NORM"

LINES="$(wc -l < "$NEW_NORM" | tr -d ' ')"
SHA="$(sha_full "$NEW_NORM")"
SHA_SHOW="$(sha_show4 "$SHA")"

if [ "$LINES" -lt "$MIN_LINES" ] || [ "$LINES" -gt "$MAX_LINES" ]; then
  log "lines out of bounds"
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
  log "SAME"
  render_and_send "$TPL_SAME"
  exit 0
fi

# import
if timeout "$IMPORT_TIMEOUT" sh -c "$IMPORT_CMD '$NEW_NORM'"; then
  cp "$NEW_NORM" "$CUR_FILE"
  log "IMPORT OK"
else
  log "IMPORT FAILED"
  ERR_TITLE="Ошибка импорта"
  ERR_LINES="• команда: $IMPORT_CMD"
  render_and_send "$TPL_ERR"
  exit 1
fi

# после импорта – восстановить DNS, если kvas update его уронил
post_kvas_dns_recover || log "DNS: recovery failed after import"

render_and_send "$TPL_OK"

exit 0
