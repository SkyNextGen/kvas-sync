#!/bin/sh
set -eu

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =========================
# KVAS-SYNC Router Agent (weekly, v8)
# Goals:
# - NO: kvas update
# - NO: kvas crypt on/off
# - YES: Telegram notifications (OK / SAME / ERR) using existing templates
# - If list SAME: do nothing (unless ipset overflow protection triggers rebuild)
# - If list CHANGED: kvas import + rebuild ipset (flush unblock + run ipset.kvas)
# - Always avoid race with KVAS cron.5mins/ipset.kvas by pausing Entware cron around rebuild.
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

# KVAS ipset set name (from your router output)
: "${KVAS_IPSET_NAME:=unblock}"

# Overflow protection: rebuild ipset even if list SAME when entry count exceeds this threshold
: "${IPSET_OVERFLOW_THRESHOLD:=60000}"

# Cron pause around rebuild (seconds)
: "${CRON_PAUSE_SLEEP:=3}"
: "${POST_REBUILD_SLEEP:=2}"

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
# Cron control (Entware) to avoid race with /opt/etc/cron.5mins/ipset.kvas
# -------------------------
find_cron_init() {
  for f in /opt/etc/init.d/*cron* /opt/etc/init.d/*crond*; do
    [ -x "$f" ] || continue
    echo "$f"
    return 0
  done
  return 1
}

CRON_INIT=""

stop_entware_cron() {
  CRON_INIT="$(find_cron_init 2>/dev/null || true)"
  if [ -n "$CRON_INIT" ]; then
    log "CRON: stopping via $CRON_INIT stop"
    "$CRON_INIT" stop >/dev/null 2>&1 || true
  else
    log "CRON: init script not found, killing crond"
    killall crond >/dev/null 2>&1 || true
    killall /opt/sbin/crond >/dev/null 2>&1 || true
  fi
  sleep "$CRON_PAUSE_SLEEP"
}

start_entware_cron() {
  if [ -z "$CRON_INIT" ]; then
    CRON_INIT="$(find_cron_init 2>/dev/null || true)"
  fi
  if [ -n "$CRON_INIT" ]; then
    log "CRON: starting via $CRON_INIT start"
    "$CRON_INIT" start >/dev/null 2>&1 || true
  else
    log "CRON: init script not found, starting /opt/sbin/crond"
    /opt/sbin/crond >/dev/null 2>&1 || true
  fi
}

kill_kvas_ipset_jobs() {
  for pat in "/opt/etc/cron.5mins/ipset.kvas" "/opt/apps/kvas/bin/main/ipset"; do
    pids="$(ps | grep -F "$pat" | grep -v grep | awk '{print $1}' || true)"
    if [ -n "$pids" ]; then
      log "CRON: killing running job(s) for $pat: $pids"
      for p in $pids; do kill "$p" >/dev/null 2>&1 || true; done
      sleep 1
      for p in $pids; do kill -9 "$p" >/dev/null 2>&1 || true; done
    fi
  done
}

# -------------------------
# KVAS helpers
# -------------------------
ipset_count() {
  ipset list "$KVAS_IPSET_NAME" 2>/dev/null | grep -E '^[[:space:]]*[0-9]' | wc -l | tr -d ' '
}

rebuild_ipset() {
  stop_entware_cron
  kill_kvas_ipset_jobs

  log "IPSET: flush $KVAS_IPSET_NAME"
  ipset flush "$KVAS_IPSET_NAME" >/dev/null 2>&1 || true

  if [ -x /opt/etc/cron.5mins/ipset.kvas ]; then
    log "IPSET: rebuild via /opt/etc/cron.5mins/ipset.kvas start"
    /opt/etc/cron.5mins/ipset.kvas start >/dev/null 2>&1 || true
  else
    log "IPSET: ipset.kvas not found at /opt/etc/cron.5mins/ipset.kvas"
  fi

  start_entware_cron
  sleep "$POST_REBUILD_SLEEP"
}

import_list() {
  log "IMPORT: running '$IMPORT_CMD' (timeout=${IMPORT_TIMEOUT}s)"
  if need_cmd timeout; then
    timeout "$IMPORT_TIMEOUT" sh -c "$IMPORT_CMD \"$NEW_NORM\"" >/dev/null 2>&1
  else
    sh -c "$IMPORT_CMD \"$NEW_NORM\"" >/dev/null 2>&1
  fi
  return $?
}

# -------------------------
# Normalize list
# -------------------------
normalize_list() {
  in="$1"
  out="$2"
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
need_cmd ipset || die "ipset not found"
[ -x /opt/etc/cron.5mins/ipset.kvas ] || log "WARN: /opt/etc/cron.5mins/ipset.kvas not executable"

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

LIST_CHANGED=1
if [ -f "$CUR_FILE" ]; then
  CUR_SHA="$(sha_full "$CUR_FILE" 2>/dev/null || echo "")"
  if [ -n "$CUR_SHA" ] && [ "$CUR_SHA" = "$SHA" ]; then
    LIST_CHANGED=0
  fi
fi

CNT="$(ipset_count || echo 0)"
log "IPSET: current entries=${CNT} (threshold=${IPSET_OVERFLOW_THRESHOLD})"
OVERFLOW_REBUILD=0
if [ "$CNT" -ge "$IPSET_OVERFLOW_THRESHOLD" ]; then
  OVERFLOW_REBUILD=1
fi

if [ "$LIST_CHANGED" -eq 0 ] && [ "$OVERFLOW_REBUILD" -eq 0 ]; then
  log "SAME: list unchanged and no overflow (sha=$SHA, lines=$LINES)"
  render_and_send "$TPL_SAME"
  exit 0
fi

if [ "$LIST_CHANGED" -eq 1 ]; then
  if import_list; then
    cp -f "$NEW_NORM" "$CUR_FILE" 2>/dev/null || true
    log "IMPORT: done"
  else
    rc=$?
    ERR_TITLE="Ошибка импорта"
    ERR_LINES="• kvas import failed (exit=${rc})"
    render_and_send "$TPL_ERR"
    exit 1
  fi
else
  log "SAME: list unchanged, but overflow protection requires rebuild"
fi

rebuild_ipset

CNT2="$(ipset_count || echo 0)"
log "IPSET: entries after rebuild=${CNT2}"

log "OK: list sha=$SHA, lines=$LINES, ipset=${CNT2}"
render_and_send "$TPL_OK"
exit 0
