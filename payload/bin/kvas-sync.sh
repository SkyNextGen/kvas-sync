#!/bin/sh
set -eu

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =========================
# KVAS-SYNC Router Agent (weekly)
# - NO: kvas update
# - NO: kvas crypt on/off
# - YES: weekly purge of KVAS state when list CHANGED (kvas purge)
# - YES: Telegram notifications (OK / SAME / ERR)
# =========================

KVAS="/opt/bin/kvas"

COMMON="/opt/kvas-sync/conf/common.conf"
DEVICE="/opt/kvas-sync/conf/device.conf"
SECRETS="/opt/kvas-sync/conf/secrets.conf"

[ -f "$COMMON" ] && . "$COMMON"
[ -f "$DEVICE" ] && . "$DEVICE"
[ -f "$SECRETS" ] && . "$SECRETS"

: "${WORKDIR:=/opt/kvas-sync}"
: "${STATE_DIR:=$WORKDIR/state}"
: "${LOGDIR:=$WORKDIR/log}"
: "${LOG_FILE:=$LOGDIR/kvas-sync.log}"

: "${LIST_URL:=}"
: "${ROUTER_NAME:=Router}"
: "${IMPORT_CMD:=kvas import}"

: "${MIN_LINES:=200}"
: "${MAX_LINES:=3500}"
: "${CURL_TIMEOUT:=25}"
: "${RETRY_COUNT:=3}"
: "${RETRY_DELAY:=8}"
: "${IMPORT_TIMEOUT:=2700}"

TPL_OK="$WORKDIR/conf/tg_ok.tpl"
TPL_SAME="$WORKDIR/conf/tg_same.tpl"
TPL_ERR="$WORKDIR/conf/tg_err.tpl"

mkdir -p "$STATE_DIR" "$LOGDIR" "$WORKDIR/tmp"

LOCK_DIR="$STATE_DIR/import.lock"

NEW_RAW="$STATE_DIR/inside-kvas.new.raw.lst"
NEW_NORM="$STATE_DIR/inside-kvas.new.norm.lst"
CUR_FILE="$STATE_DIR/inside-kvas.cur.lst"

ts()    { date '+%Y-%m-%d %H:%M:%S'; }
dt_ru() { date '+%d.%m.%Y %H:%M:%S МСК'; }

log() {
  line="[$(ts)] $*"
  echo "$line"
  printf "%s\n" "$line" >>"$LOG_FILE" 2>/dev/null || true
}

die() { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

esc_sed() { printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'; }

sha_full() { sha256sum "$1" | awk '{print $1}'; }

count_lines() { wc -l <"$1" | tr -d ' '; }

# -------------------------
# Telegram
# -------------------------
tg_send() {
  msg="$1"
  [ -n "${BOT_TOKEN:-}" ] || { log "TG: BOT_TOKEN not set, skip"; return 0; }
  [ -n "${CHAT_ID:-}" ] || { log "TG: CHAT_ID not set, skip"; return 0; }

  i=1
  while [ "$i" -le "${TG_TRIES:-3}" ]; do
    resp="$(curl -sS -m 20 -X POST \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" 2>&1)" && {
        echo "$resp" | grep -q '"ok":true' && return 0
        log "TG: api error: $resp"
        return 0
      }

    log "TG: send failed (try ${i}/${TG_TRIES:-3}): $resp"
    i=$((i+1))
    sleep "${TG_DELAY:-3}"
  done
  return 0
}

render_and_send() {
  tpl="$1"
  tmp="$WORKDIR/tmp/tg_msg.txt"
  cp -f "$tpl" "$tmp" 2>/dev/null || { log "TG: template not found: $tpl"; return 0; }

  R_ESC="$(esc_sed "${ROUTER_NAME}")"
  L_ESC="$(esc_sed "${LINES:-}")"
  S_ESC="$(esc_sed "${SHA:-}")"
  D_ESC="$(esc_sed "${DT:-$(dt_ru)}")"
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

  tg_send "$(cat "$tmp")"
}

# -------------------------
# Lock
# -------------------------
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
    return 0
  fi

  # stale lock cleanup
  if [ -f "$LOCK_DIR/pid" ]; then
    oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && ! kill -0 "$oldpid" 2>/dev/null; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || return 1
      echo "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi
  fi

  return 1
}

cleanup() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# -------------------------
# Purge (only if list changed)
# -------------------------
purge_kvas_state() {
  # In your environment KVAS provides 'kvas purge' and ipset table is 'unblock'
  log "PURGE: running 'kvas purge'"
  "$KVAS" purge </dev/null >/dev/null 2>&1 || true
}

# -------------------------
# Normalize list
# -------------------------
normalize_list() {
  in="$1"
  out="$2"
  # remove comments/blank, trim, lowercase
  sed \
    -e 's/\r$//' \
    -e 's/[ \t]\+$//' \
    -e 's/^[ \t]\+//' \
    -e '/^$/d' \
    -e '/^[#;]/d' \
    "$in" \
  | tr '[:upper:]' '[:lower:]' \
  > "$out"
}

# -------------------------
# Main
# -------------------------
log "start"

[ -x "$KVAS" ] || die "KVAS binary not found: $KVAS"
[ -n "$LIST_URL" ] || die "LIST_URL is empty (check conf)"

if ! acquire_lock; then
  die "another run is in progress (lock: $LOCK_DIR)"
fi

# download with retries
i=1
ok=0
while [ "$i" -le "$RETRY_COUNT" ]; do
  log "download try ${i}/${RETRY_COUNT}"
  if curl -fsSL -m "$CURL_TIMEOUT" "$LIST_URL" -o "$NEW_RAW" 2>/dev/null; then
    ok=1
    break
  fi
  i=$((i+1))
  sleep "$RETRY_DELAY"
done

if [ "$ok" -ne 1 ]; then
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• download failed"
  render_and_send "$TPL_ERR"
  exit 1
fi

# HTML guard
head -n 2 "$NEW_RAW" | grep -qi '<!doctype\|<html' && {
  ERR_TITLE="Ошибка загрузки"
  ERR_LINES="• HTML вместо списка"
  render_and_send "$TPL_ERR"
  exit 1
}

normalize_list "$NEW_RAW" "$NEW_NORM"

LINES="$(count_lines "$NEW_NORM" 2>/dev/null || echo 0)"
if [ "$LINES" -lt "$MIN_LINES" ] || [ "$LINES" -gt "$MAX_LINES" ]; then
  ERR_TITLE="Ошибка списка"
  ERR_LINES="• Некорректное число строк: ${LINES} (ожидалось ${MIN_LINES}-${MAX_LINES})"
  render_and_send "$TPL_ERR"
  exit 1
fi

SHA="$(sha_full "$NEW_NORM")"
DT="$(dt_ru)"

# SAME: if hash matches current — no purge, no import
if [ -f "$CUR_FILE" ]; then
  CUR_SHA="$(sha_full "$CUR_FILE" 2>/dev/null || echo "")"
  if [ -n "$CUR_SHA" ] && [ "$CUR_SHA" = "$SHA" ]; then
    log "SAME: list unchanged (sha=$SHA, lines=$LINES)"
    render_and_send "$TPL_SAME"
    exit 0
  fi
fi

# CHANGED: purge + import
purge_kvas_state

log "IMPORT: running '$IMPORT_CMD' (timeout=${IMPORT_TIMEOUT}s)"
if need_cmd timeout; then
  timeout "$IMPORT_TIMEOUT" sh -c "$IMPORT_CMD \"$NEW_NORM\"" >/dev/null 2>&1 || {
    ERR_TITLE="Ошибка импорта"
    ERR_LINES="• kvas import failed (timeout/exit)"
    render_and_send "$TPL_ERR"
    exit 1
  }
else
  sh -c "$IMPORT_CMD \"$NEW_NORM\"" >/dev/null 2>&1 || {
    ERR_TITLE="Ошибка импорта"
    ERR_LINES="• kvas import failed"
    render_and_send "$TPL_ERR"
    exit 1
  }
fi

# Save current list
cp -f "$NEW_NORM" "$CUR_FILE" 2>/dev/null || true

log "OK: imported new list (sha=$SHA, lines=$LINES)"
render_and_send "$TPL_OK"
exit 0
