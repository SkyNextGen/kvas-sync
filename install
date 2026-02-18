#!/bin/sh
set -eu

# ===== Repo defaults =====
ORG="SkyNextGen"
REPO="kvas-sync"
BRANCH="main"

BASE="/opt/kvas-sync"
TMPROOT="/opt/tmp"
WORK="${TMPROOT}/kvas-sync-install.$$"
ARCHIVE="${TMPROOT}/kvas-sync-${BRANCH}.zip"

need_cmd() { command -v "$1" >/dev/null 2>&1; }
say() { echo "$*" >&2; }

ask() {
  # visible input (token is visible as requested)
  printf "%s: " "$1" >&2
  IFS= read -r ans || true
  printf "%s" "$ans"
}

cleanup() { rm -rf "$WORK" >/dev/null 2>&1 || true; }
trap cleanup EXIT

install_pkgs() {
  # Usage: install_pkgs pkg1 pkg2 ...
  for p in "$@"; do
    opkg install "$p" >/dev/null 2>&1 || true
  done
}

ensure_deps() {
  if ! need_cmd opkg; then
    say "❌ Entware (opkg) не найден. Установите Entware и убедитесь, что /opt смонтирован."
    exit 1
  fi

  say "Проверка зависимостей Entware..."
  opkg update >/dev/null 2>&1 || true

  # Base deps
  install_pkgs curl ca-bundle unzip coreutils-timeout

  # cron package name differs across feeds; try common variants
  install_pkgs cron vixie-cron cronie

  # find is usually in BusyBox, but ensure it's available
  if ! need_cmd find; then
    install_pkgs findutils
  fi

  # Hard checks
  need_cmd curl  || { say "❌ Не найден curl (/opt/bin/curl)."; exit 1; }
  need_cmd unzip || { say "❌ Не найден unzip."; exit 1; }
  need_cmd timeout || { say "❌ Не найден timeout (coreutils-timeout)."; exit 1; }
  need_cmd crontab || { say "❌ Не найден crontab (пакет cron/vixie-cron)."; exit 1; }

  # crond may be /opt/sbin/crond; check explicitly
  if [ ! -x /opt/sbin/crond ] && ! need_cmd crond; then
    say "❌ Не найден crond (демон cron). Проверьте пакет cron/vixie-cron."
    exit 1
  fi
}

start_cron_now() {
  # 1) Prefer init script if present
  if [ -x /opt/etc/init.d/S10cron ]; then
    /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
  fi

  # 2) Fallback: run daemon directly
  if ! ps | grep -q '[/]opt/sbin/crond'; then
    if [ -x /opt/sbin/crond ]; then
      /opt/sbin/crond >/dev/null 2>&1 || true
    fi
  fi
}

ensure_cron_autostart() {
  # Universal hook for Keenetic+Entware: /opt/etc/rc.local (executed when /opt is ready on boot on many setups)
  RC="/opt/etc/rc.local"
  MARK_BEGIN="# kvas-sync: ensure crond (begin)"
  MARK_END="# kvas-sync: ensure crond (end)"

  mkdir -p /opt/etc

  if [ ! -f "$RC" ]; then
    cat > "$RC" <<'EOF'
#!/bin/sh
EOF
    chmod +x "$RC"
  else
    chmod +x "$RC" >/dev/null 2>&1 || true
  fi

  # Remove old block if any (safe idempotency)
  if grep -q "$MARK_BEGIN" "$RC" 2>/dev/null; then
    # delete from begin to end
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$RC" 2>/dev/null || true
  fi

  cat >> "$RC" <<'EOF'

# kvas-sync: ensure crond (begin)
if ! ps | grep -q '[/]opt/sbin/crond'; then
  if [ -x /opt/etc/init.d/S10cron ]; then
    /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
  elif [ -x /opt/sbin/crond ]; then
    /opt/sbin/crond >/dev/null 2>&1 || true
  fi
fi
# kvas-sync: ensure crond (end)
EOF
}

download_and_unpack() {
  mkdir -p "$TMPROOT"
  mkdir -p "$WORK"

  # Use github.com (not codeload.github.com) to avoid DNS issues
  ARCHIVE_URL="https://github.com/${ORG}/${REPO}/archive/refs/heads/${BRANCH}.zip"

  say "Загрузка архива репозитория: ${ORG}/${REPO}@${BRANCH}"
  curl -fsSLo "$ARCHIVE" "$ARCHIVE_URL"

  [ -s "$ARCHIVE" ] || { say "❌ Архив не скачался или пустой."; exit 1; }
  head -c 2 "$ARCHIVE" | grep -q "PK" || { say "❌ Скачанное не похоже на ZIP."; exit 1; }

  say "Распаковка архива..."
  unzip -qo "$ARCHIVE" -d "$WORK"

  # Locate payload
  KS_PATH="$(find "$WORK" -type f -path '*/payload/bin/kvas-sync.sh' -print -quit 2>/dev/null || true)"
  if [ -z "$KS_PATH" ]; then
    say "❌ Не найден payload/bin/kvas-sync.sh в архиве."
    exit 1
  fi

  PAYLOAD_DIR="$(dirname "$(dirname "$KS_PATH")")"
  say "Найден payload: $PAYLOAD_DIR"
  echo "$PAYLOAD_DIR"
}

deploy_payload() {
  payload_dir="$1"

  say "Развёртывание в $BASE ..."

  mkdir -p "$BASE"
  rm -rf "$BASE/bin" "$BASE/conf"
  cp -R "$payload_dir/bin"  "$BASE/bin"
  cp -R "$payload_dir/conf" "$BASE/conf"

  chmod +x "$BASE/bin/kvas-sync.sh"

  mkdir -p "$BASE/log" "$BASE/state" "$BASE/tmp"
}

write_configs() {
  echo ""
  echo "Введите данные Telegram"

  BOT_TOKEN="$(ask "Токен бота")"
  [ -n "$BOT_TOKEN" ] || { say "❌ Токен не может быть пустым"; exit 1; }

  CHAT_ID="$(ask "ID чата")"
  [ -n "$CHAT_ID" ] || { say "❌ ID чата не может быть пустым"; exit 1; }

  ROUTER_NAME="$(ask "Введите имя роутера")"
  [ -n "$ROUTER_NAME" ] || { say "❌ Имя роутера не может быть пустым"; exit 1; }

  umask 077
  cat > "$BASE/conf/secrets.conf" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
EOF
  chmod 600 "$BASE/conf/secrets.conf"

  cat > "$BASE/conf/device.conf" <<EOF
ROUTER_NAME="$ROUTER_NAME"
IMPORT_CMD="kvas import"
EOF
  chmod 644 "$BASE/conf/device.conf"
}

setup_cron() {
  CRON_LINE="15 3 * * 3 /opt/kvas-sync/bin/kvas-sync.sh >> /opt/kvas-sync/log/cron.log 2>&1"
  say "Настройка cron: каждую среду 03:15 (очистка и запись заново)"
  printf "%s\n" "$CRON_LINE" | crontab -
}

main() {
  say "Установка kvas-sync в $BASE"
  ensure_deps

  payload_dir="$(download_and_unpack)"
  deploy_payload "$payload_dir"
  write_configs
  setup_cron

  say "Запуск cron-демона..."
  start_cron_now
  ensure_cron_autostart

  say "Пробный запуск..."
  if /opt/kvas-sync/bin/kvas-sync.sh; then
    say "✅ Установка завершена."
  else
    say "⚠️ Установка завершена, но пробный запуск с ошибкой. Смотрите: /opt/kvas-sync/log/kvas-sync.log"
  fi
}

main "$@"
