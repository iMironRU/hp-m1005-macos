#!/bin/bash
#
# HP LaserJet M1005 MFP — установка одной строкой:
#
#   curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | sudo bash
#
# Параметры передаются после «-s --»:
#   ... | sudo bash -s -- --no-test     — без тестовой страницы
#   ... | sudo bash -s -- --uninstall   — удалить драйвер и очередь
#
# Скрипт скачивает архив репозитория во временный каталог и запускает
# setup.sh (или uninstall.sh) оттуда.
#
set -euo pipefail

REPO="iMironRU/hp-m1005-macos"
REF="${M1005_REF:-main}"
RAW_URL="https://raw.githubusercontent.com/$REPO/$REF/install.sh"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# Всё тело в функции: при оборванной загрузке через curl | bash
# ничего не выполнится частично.
main() {
    [ "$(uname -s)" = "Darwin" ] || die "скрипт только для macOS."
    [ "$(id -u)" -eq 0 ] || die "нужен sudo: curl -fsSL $RAW_URL | sudo bash"

    local action="setup.sh" args=()
    for a in "$@"; do
        case "$a" in
            --uninstall) action="uninstall.sh" ;;
            *)           args+=("$a") ;;
        esac
    done

    if [ "$action" = "setup.sh" ] && ! xcode-select -p >/dev/null 2>&1; then
        die "нужны Command Line Tools. Выполните (без sudo): xcode-select --install — дождитесь окончания установки и повторите команду."
    fi

    local tmp
    tmp="$(mktemp -d /tmp/m1005-install.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    say "Загружаю $REPO@$REF"
    curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" \
        | tar -xz -C "$tmp" --strip-components 1 \
        || die "не удалось скачать https://github.com/$REPO"

    export M1005_RERUN="curl -fsSL $RAW_URL | sudo bash -s --"
    bash "$tmp/$action" ${args[@]+"${args[@]}"}
}

main "$@"
