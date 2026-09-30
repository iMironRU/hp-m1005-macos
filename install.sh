#!/bin/bash
#
# HP LaserJet M1005 MFP — установка одной строкой (всё в одном):
#
#   curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash
#
# Что делает:
#   1. Если нет Command Line Tools — ставит их через softwareupdate
#      (без окон; если так не вышло — открывает стандартный установщик и ждёт).
#   2. Скачивает этот репозиторий во временный каталог.
#   3. Запускает setup.sh от root (пароль спросит sudo один раз).
#
# Параметры передаются после «-s --»:
#   ... | bash -s -- --no-test     — без тестовой страницы
#   ... | bash -s -- --uninstall   — удалить драйвер и очередь
#
set -euo pipefail

REPO="iMironRU/hp-m1005-macos"
REF="${M1005_REF:-main}"
RAW_URL="https://raw.githubusercontent.com/$REPO/$REF/install.sh"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# Выполнить от root: напрямую, если уже root, иначе через sudo.
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

clt_ok() {
    xcode-select -p >/dev/null 2>&1 || return 1
    local sdk
    sdk="$(xcrun --show-sdk-path 2>/dev/null)" || return 1
    [ -f "$sdk/usr/include/cups/raster.h" ] && command -v git >/dev/null 2>&1 \
        && command -v cc >/dev/null 2>&1
}

install_clt() {
    say "Command Line Tools не найдены — устанавливаю (это может занять 5–15 минут)"

    # Тихая установка через softwareupdate (как делает установщик Homebrew).
    local flag="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    as_root touch "$flag"
    local label
    label="$(softwareupdate -l 2>/dev/null \
        | grep -E '^[[:space:]]*\* Label: Command Line Tools' \
        | sed -E 's/^[[:space:]]*\* Label: //' \
        | sort -V | tail -n1 || true)"
    if [ -n "$label" ]; then
        say "Пакет: $label"
        as_root softwareupdate -i "$label" --verbose || true
    fi
    as_root rm -f "$flag"

    # Если тихо не получилось — стандартное окно установки, ждём завершения.
    if ! xcode-select -p >/dev/null 2>&1; then
        say "Открываю окно установки Command Line Tools — нажмите «Установить» и дождитесь окончания"
        xcode-select --install >/dev/null 2>&1 || true
        local waited=0
        until xcode-select -p >/dev/null 2>&1; do
            sleep 10; waited=$((waited + 10))
            [ "$waited" -ge 3600 ] && die "Command Line Tools не установились за час. Повторите команду после установки."
        done
    fi

    clt_ok || die "Command Line Tools установлены не полностью. Выполните: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install — и повторите команду."
    say "Command Line Tools установлены"
}

# Всё тело в функции: при оборванной загрузке через curl | bash
# ничего не выполнится частично.
main() {
    [ "$(uname -s)" = "Darwin" ] || die "скрипт только для macOS."

    local action="setup.sh" args=()
    for a in "$@"; do
        case "$a" in
            --uninstall) action="uninstall.sh" ;;
            *)           args+=("$a") ;;
        esac
    done

    if [ "$(id -u)" -ne 0 ]; then
        say "Понадобится пароль администратора Mac"
        sudo -v </dev/tty || die "нужны права администратора."
        # держим sudo активным, пока идёт установка
        ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    fi

    if [ "$action" = "setup.sh" ]; then
        if clt_ok; then say "Command Line Tools: есть"; else install_clt; fi
    fi

    local tmp
    tmp="$(mktemp -d /tmp/m1005-install.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    say "Загружаю $REPO@$REF"
    curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" \
        | tar -xz -C "$tmp" --strip-components 1 \
        || die "не удалось скачать https://github.com/$REPO"

    as_root env M1005_RERUN="curl -fsSL $RAW_URL | bash -s --" \
        bash "$tmp/$action" ${args[@]+"${args[@]}"}
}

main "$@"
