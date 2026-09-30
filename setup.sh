#!/bin/bash
#
# HP LaserJet M1005 MFP — установка драйвера на macOS (Apple Silicon и Intel).
#
# Что делает:
#   1. Собирает foo2xqx из исходников OpenPrinting/foo2zjs (закреплённый коммит).
#   2. Собирает CUPS-фильтр rastertoxqx из rastertoxqx.c (лежит рядом).
#   3. Ставит оба бинарника в /Library/Printers/foo2xqx/Filter, PPD — в
#      /Library/Printers/PPDs/Contents/Resources.
#   4. Находит принтер на USB и создаёт очередь печати.
#
# Ghostscript и Homebrew не нужны: растеризацию PDF делает сама macOS
# (cgpdftoraster). Системные каталоги (/usr/...) и SIP не трогаются,
# песочница CUPS не ослабляется.
#
# Запуск:  sudo ./setup.sh           — сборка, установка, очередь, тестовая страница
#          sudo ./setup.sh --no-test — без тестовой страницы
#
set -euo pipefail

FOO2ZJS_REPO="https://github.com/OpenPrinting/foo2zjs.git"
FOO2ZJS_COMMIT="80499ed5bf6caa2963ad337e37cfda78a80aab1e"

FILTER_DIR="/Library/Printers/foo2xqx/Filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="HP-LaserJet-M1005-MFP-foo2xqx.ppd"
QUEUE="HP_LaserJet_M1005"
HERE="$(cd "$(dirname "$0")" && pwd)"

DO_TEST=1
[ "${1:-}" = "--no-test" ] && DO_TEST=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Проверки ----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "скрипт только для macOS."
[ "$(id -u)" -eq 0 ] || die "запустите через sudo: sudo $0"
for f in rastertoxqx.c "$PPD_NAME"; do
    [ -f "$HERE/$f" ] || die "не найден $f рядом со скриптом."
done

if ! xcode-select -p >/dev/null 2>&1; then
    die "нужны Command Line Tools. Выполните (без sudo): xcode-select --install — и запустите скрипт снова."
fi
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] && [ -f "$SDK/usr/include/cups/raster.h" ] \
    || die "в SDK нет заголовков CUPS ($SDK). Переустановите Command Line Tools."

# --- Сборка ------------------------------------------------------------------
BUILD="$(mktemp -d /tmp/m1005-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

say "Загружаю foo2zjs @ ${FOO2ZJS_COMMIT:0:12}"
git -C "$BUILD" init -q foo2zjs
git -C "$BUILD/foo2zjs" remote add origin "$FOO2ZJS_REPO"
git -C "$BUILD/foo2zjs" fetch -q --depth 1 origin "$FOO2ZJS_COMMIT"
git -C "$BUILD/foo2zjs" checkout -q FETCH_HEAD

say "Собираю foo2xqx ($(uname -m))"
( cd "$BUILD/foo2zjs" && cc -O2 -w -o "$BUILD/foo2xqx" foo2xqx.c jbig.c jbig_ar.c )

say "Собираю фильтр rastertoxqx"
cc -O2 -Wall -Wno-deprecated-declarations \
   -DFOO2XQX_PATH="\"$FILTER_DIR/foo2xqx\"" \
   -o "$BUILD/rastertoxqx" "$HERE/rastertoxqx.c" -lcups

"$BUILD/foo2xqx" -V >/dev/null 2>&1 || true   # просто убедиться, что запускается

# --- Установка ---------------------------------------------------------------
say "Устанавливаю фильтры в $FILTER_DIR"
install -d -o root -g wheel -m 755 "$FILTER_DIR"
install -o root -g wheel -m 755 "$BUILD/foo2xqx" "$BUILD/rastertoxqx" "$FILTER_DIR/"

say "Устанавливаю PPD"
install -d -o root -g wheel -m 755 "$PPD_DIR"
install -o root -g wheel -m 644 "$HERE/$PPD_NAME" "$PPD_DIR/$PPD_NAME"

# --- Очередь печати ----------------------------------------------------------
say "Ищу принтер на USB"
URI="$(lpinfo -v 2>/dev/null | awk '/^direct usb:\/\/.*M1005/ {print $2; exit}')"
if [ -z "$URI" ]; then
    echo
    echo "Драйвер установлен, но принтер на USB не найден."
    echo "Включите принтер, подключите кабель напрямую (без хаба) и выполните:"
    echo "  ${M1005_RERUN:-sudo $0} --no-test"
    exit 1
fi
echo "    $URI"

say "Создаю очередь $QUEUE"
lpadmin -x "$QUEUE" 2>/dev/null || true
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/$PPD_NAME" \
        -D "HP LaserJet M1005 MFP" -o printer-is-shared=false
cupsenable "$QUEUE"
cupsaccept "$QUEUE"

# --- Тест ----------------------------------------------------------------------
if [ "$DO_TEST" -eq 1 ] && [ -f "$HERE/test.pdf" ]; then
    say "Печатаю тестовую страницу"
    lp -d "$QUEUE" -t "M1005 test" "$HERE/test.pdf"
    echo
    echo "Если страница не вышла за ~30 секунд, посмотрите статус:"
    echo "  lpstat -W not-completed -o $QUEUE"
    echo "  log show --last 5m --predicate 'process == \"cupsd\"' | grep -i -E 'rastertoxqx|foo2xqx|sandbox'"
fi

echo
say "Готово. Принтер «HP LaserJet M1005 MFP» доступен во всех приложениях."
echo "    Сделать принтером по умолчанию:  lpadmin -d $QUEUE"
