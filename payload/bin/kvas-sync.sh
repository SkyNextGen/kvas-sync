#!/bin/sh
set -eu

# ===== CONFIG FILES =====
COMMON="/opt/kvas-sync/conf/common.conf"
DEVICE="/opt/kvas-sync/conf/device.conf"
SECRETS="/opt/kvas-sync/conf/secrets.conf"

[ -f "$COMMON" ] && . "$COMMON"
[ -f "$DEVICE" ] && . "$DEVICE"
[ -f "$SECRETS" ] && . "$SECRETS"

# ===== DEFAULTS SAFETY =====
: "${WORKDIR:=/opt/kvas-sync}"
: "${STATE_DIR:=$WORKDIR/state}"
: "${LOG_FILE:=$WORKDIR/log/kvas-sync.log}"
: "${LIST_URL:=}"
: "${ROUTER_NAME:=Router}"
: "${IMPORT_CMD:=kvas import}"

mkdir -p "$STATE_DIR" "$WORKDIR/log" "$WORKDIR/tmp"

LOCK_DIR="$STATE_DIR/import.lock"
NEW_RAW="$STATE_DIR/inside-kvas.new.raw.lst"
NEW_NORM="$STATE_DIR/inside-kvas.new.norm.lst"
CUR_FILE="$STATE_DIR/inside-kvas.cur.lst"

TPL_OK="$WORKDIR/conf/tg_ok.tpl"
TPL_SAME="$WORKDIR/conf/tg_same.tpl"
TPL_ERR="$WORKDIR/conf/tg_err.tpl"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
dt_ru() { date '+%d.%m.%Y %H:%M:%S МСК'; }

log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# ===== TELEGRAM SEND =====
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

# ===== SHA =====
sha_full() {
    sha256sum "$1" | awk '{print $1}'
}

sha_show4() {
    printf "%s…%s" "$(printf '%s' "$1" | cut -c1-4)" "$(printf '%s' "$1" | cut -c61-64)"
}

# ===== NORMALIZE =====
normalize_list() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$1" \
    | sed '/^$/d' \
    | sed 's/\r$//' \
    | sort -u > "$2"
}

# ===== DOWNLOAD =====
download_list() {
    curl -fsSL --max-time "${CURL_TIMEOUT:-25}" "$LIST_URL" -o "$NEW_RAW"
}

# ===== MAIN =====
[ -z "$LIST_URL" ] && { log "LIST_URL empty"; exit 1; }

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "start"
DT="$(dt_ru)"

rm -f "$NEW_RAW" "$NEW_NORM"

if ! download_list; then
    log "download failed"
    [ -f "$TPL_ERR" ] && tg_send "$(cat "$TPL_ERR")"
    exit 1
fi

normalize_list "$NEW_RAW" "$NEW_NORM"

LINES="$(wc -l < "$NEW_NORM" | tr -d ' ')"
SHA="$(sha_full "$NEW_NORM")"
SHA_SHOW="$(sha_show4 "$SHA")"

if [ "$LINES" -lt "${MIN_LINES:-1}" ] || [ "$LINES" -gt "${MAX_LINES:-999999}" ]; then
    log "lines out of bounds"
    [ -f "$TPL_ERR" ] && tg_send "$(cat "$TPL_ERR")"
    exit 1
fi

if [ -f "$CUR_FILE" ]; then
    SHA_CUR="$(sha_full "$CUR_FILE")"
else
    SHA_CUR=""
fi

if [ -n "$SHA_CUR" ] && [ "$SHA_CUR" = "$SHA" ]; then
    log "SAME: normalized sha matched"

    if [ -f "$TPL_SAME" ]; then
        MSG="$(cat "$TPL_SAME")"
        MSG="$(printf "%s" "$MSG" \
            | sed "s/{{ROUTER_NAME}}/$ROUTER_NAME/g" \
            | sed "s/{{LINES}}/$LINES/g" \
            | sed "s/{{SHA}}/$SHA_SHOW/g" \
            | sed "s/{{DT}}/$DT/g")"
        tg_send "$MSG"
    fi

    exit 0
fi

# ===== IMPORT =====
if timeout "${IMPORT_TIMEOUT:-2700}" sh -c "$IMPORT_CMD '$NEW_NORM'"; then
    cp "$NEW_NORM" "$CUR_FILE"
    log "IMPORT OK"

    if [ -f "$TPL_OK" ]; then
        MSG="$(cat "$TPL_OK")"
        MSG="$(printf "%s" "$MSG" \
            | sed "s/{{ROUTER_NAME}}/$ROUTER_NAME/g" \
            | sed "s/{{LINES}}/$LINES/g" \
            | sed "s/{{SHA}}/$SHA_SHOW/g" \
            | sed "s/{{DT}}/$DT/g")"
        tg_send "$MSG"
    fi
else
    log "IMPORT FAILED"

    if [ -f "$TPL_ERR" ]; then
        tg_send "$(cat "$TPL_ERR")"
    fi
fi

exit 0
