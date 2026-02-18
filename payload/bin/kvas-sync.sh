#!/bin/sh
# KVAS Sync Router Agent (BusyBox/Entware)
# - Telegram alerts: OK import, SAME (no changes), ERR (download/validation/update/import failure)
# - Always runs `kvas update` before import when the list has changed
set -eu

COMMON="/opt/kvas-sync/conf/common.conf"
DEVICE="/opt/kvas-sync/conf/device.conf"
SECRETS="/opt/kvas-sync/conf/secrets.conf"

# ---- load configs ----
[ -f "$COMMON" ]  && . "$COMMON"
[ -f "$DEVICE" ]  && . "$DEVICE"
[ -f "$SECRETS" ] && . "$SECRETS"

# Defaults (if not set in common.conf / device.conf)
: "${WORKDIR:=/opt/kvas-sync}"
: "${STATE_DIR:=$WORKDIR/state}"
: "${LOG_FILE:=$WORKDIR/log/kvas-sync.log}"
: "${LIST_URL:=}"
: "${ROUTER_NAME:=Keenetic}"
: "${IMPORT_CMD:=kvas import}"

: "${CURL_TIMEOUT:=25}"
: "${RETRY_COUNT:=3}"
: "${RETRY_DELAY:=8}"
: "${PING_URL:=https://raw.githubusercontent.com/}"

: "${KVAS_UPDATE_TIMEOUT:=900}"
: "${KVAS_UPDATE_RETRY:=2}"
: "${IMPORT_TIMEOUT:=2700}"

# Validation thresholds (used to decide ERR vs OK/SAME)
: "${MIN_LINES:=200}"
: "${MAX_LINES:=3500}"

# Templates
TPL_OK="${WORKDIR}/conf/tg_ok.tpl"
TPL_SAME="${WORKDIR}/conf/tg_same.tpl"
TPL_ERR="${WORKDIR}/conf/tg_err.tpl"

# State files
NEW_RAW="${STATE_DIR}/inside-kvas.new.raw.lst"
NEW_NORM="${STATE_DIR}/inside-kvas.new.norm.lst"
CUR_FILE="${STATE_DIR}/inside-kvas.cur.lst"
LOCK_DIR="${STATE_DIR}/import.lock"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" "$WORKDIR/tmp"

# ---- helpers ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }
dt_ru() { date '+%d.%m.%Y %H:%M:%S МСК'; }

log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

esc() { printf '%s' "$1" | sed 's/[\\/&]/\\&/g'; }  # escape for sed replacement

sha_full() { sha256sum "$1" | awk '{print $1}'; }

sha_show4() { printf '%s…%s' "$(printf '%s' "$1" | cut -c1-4)" "$(printf '%s' "$1" | cut -c61-64)"; }

normalize_list() {
  in="$1"; out="$2"
  sed 's/\r$//' "$in" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u > "$out"
}

wait_dns() {
  i=0
  while [ "$i" -lt 20 ]; do
    if nslookup api.telegram.org 127.0.0.1 >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 1
  done
  return 1
}

tg_send() {
  msg="$1"
  if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
    log "TG: skip (no token/chat_id)"
    return 0
  fi

  first_line="$(printf '%s' "$msg" | head -n 1 | tr -d '\r')"
  log "TG: send -> $first_line"

  wait_dns || log "TG: warn (dns not ready)"

  curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    -d "disable_web_page_preview=true" >/dev/null 2>&1

  log "TG: sent"
}

render_and_send() {
  tpl="$1"
  tmp="${WORKDIR}/tmp/tg_msg.txt"

  cp "$tpl" "$tmp"

  : "${DT:=$(dt_ru)}"
  : "${LINES:=—}"
  : "${SHA_SHOW:=—}"
  : "${ERR_TITLE:=Ошибка загрузки}"
  : "${ERR_LINES:=• —}"

  sed -i \
    -e "s/{{ROUTER_NAME}}/$(esc "$ROUTER_NAME")/g" \
    -e "s/{{LINES}}/$(esc "$LINES")/g" \
    -e "s/{{SHA}}/$(esc "$SHA_SHOW")/g" \
    -e "s/{{DT}}/$(esc "$DT")/g" \
    -e "s/{{ERR_TITLE}}/$(esc "$ERR_TITLE")/g" \
    -e "s/{{ERR_LINES}}/$(esc "$ERR_LINES")/g" \
    "$tmp"

  tg_send "$(cat "$tmp")"
}

fail() {
  ERR_TITLE="$1"
  ERR_LINES="$2"
  DT="$(dt_ru)"
  log "ERR: $ERR_TITLE"
  render_and_send "$TPL_ERR"
  exit 1
}

download_with_retry() {
  url="$1"; out="$2"
  n=1
  while [ "$n" -le "$RETRY_COUNT" ]; do
    curl -fsSL --max-time "$CURL_TIMEOUT" "$PING_URL" >/dev/null 2>&1 || true
    if curl -fsSL --max-time "$CURL_TIMEOUT" "$url" -o "$out" >/dev/null 2>&1; then
      return 0
    fi
    log "download failed (try $n/$RETRY_COUNT)"
    n=$((n+1))
    sleep "$RETRY_DELAY"
  done
  return 1
}

run_kvas_update() {
  n=1
  while [ "$n" -le "$KVAS_UPDATE_RETRY" ]; do
    log "RUN: kvas update (try $n/$KVAS_UPDATE_RETRY)"
    if timeout "$KVAS_UPDATE_TIMEOUT" kvas update >>"$LOG_FILE" 2>&1; then
      return 0
    fi
    log "kvas update failed (try $n/$KVAS_UPDATE_RETRY)"
    n=$((n+1))
    sleep 3
  done
  return 1
}

run_import() {
  log "RUN: import"
  timeout "$IMPORT_TIMEOUT" sh -c "$IMPORT_CMD \"${NEW_NORM}\"" >>"$LOG_FILE" 2>&1
}

# ---- lock ----
if mkdir "$LOCK_DIR" 2>/dev/null; then
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
else
  log "skip: lock exists"
  exit 0
fi

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM" 2>/dev/null || true

if [ -z "$LIST_URL" ]; then
  fail "Ошибка загрузки" "• LIST_URL не задан в common.conf"
fi

if ! download_with_retry "$LIST_URL" "$NEW_RAW"; then
  fail "Ошибка загрузки" "• Не удалось скачать inside-kvas.lst\n• URL: $LIST_URL"
fi

if head -n 2 "$NEW_RAW" | grep -qi '<!doctype\|<html'; then
  fail "Ошибка загрузки" "• Получен HTML вместо списка\n• Проверь URL/доступ к GitHub"
fi

normalize_list "$NEW_RAW" "$NEW_NORM"

LINES="$(wc -l < "$NEW_NORM" | tr -d ' ')"
SHA="$(sha_full "$NEW_NORM")"
SHA_SHOW="$(sha_show4 "$SHA")"

if [ "$LINES" -lt "$MIN_LINES" ]; then
  fail "Ошибка загрузки" "• Слишком мало строк: $LINES\n• Ожидание: >= $MIN_LINES"
fi
if [ "$LINES" -gt "$MAX_LINES" ]; then
  fail "Ошибка загрузки" "• Слишком много строк: $LINES\n• Лимит: <= $MAX_LINES"
fi

if [ -f "$CUR_FILE" ]; then
  SHA_CUR="$(sha_full "$CUR_FILE")" || SHA_CUR=""
  if [ -n "$SHA_CUR" ] && [ "$SHA_CUR" = "$SHA" ]; then
    log "SAME: normalized sha matched"
    render_and_send "$TPL_SAME"
    exit 0
  fi
fi

# changed -> update + import
if ! run_kvas_update; then
  fail "Ошибка загрузки" "• kvas update не выполнился\n• Проверь логи: $LOG_FILE"
fi

if ! run_import; then
  fail "Ошибка загрузки" "• Импорт не выполнен\n• Команда: $IMPORT_CMD"
fi

mv -f "$NEW_NORM" "$CUR_FILE"
rm -f "$NEW_RAW" 2>/dev/null || true

log "OK: import done | lines=$LINES | sha=$(printf '%s' "$SHA" | cut -c1-8)"
render_and_send "$TPL_OK"
exit 0
