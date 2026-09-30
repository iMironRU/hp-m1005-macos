#!/bin/bash
#
# Сквозной тест цепочки печати без принтера:
#   test.pdf → cgpdftoraster (macOS) → rastertoxqx → foo2xqx → XQX → xqxdecode → PBM
# и проверка, что рисунок стоит на листе там, где он в PDF.
#
# Запуск: tests/pipeline.sh   (нужны macOS и Command Line Tools)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/m1005-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# Встроенные файлы из install.sh (без вызова main).
[ "$(tail -n1 "$ROOT/install.sh")" = 'main "$@"' ] || { echo "install.sh: последняя строка должна быть main \"\$@\"" >&2; exit 1; }
sed '$d' "$ROOT/install.sh" > "$T/lib.sh"
# shellcheck disable=SC1091
( source "$T/lib.sh"
  write_filter_source "$T/rastertoxqx.c"
  write_ppd "$T/m1005.ppd"
  write_test_pdf "$T/test.pdf" )

# shellcheck disable=SC1091
FOO2ZJS_COMMIT="$(source "$T/lib.sh"; echo "$FOO2ZJS_COMMIT")"
echo "==> foo2zjs @ ${FOO2ZJS_COMMIT:0:12}"
git -C "$T" init -q foo2zjs
git -C "$T/foo2zjs" remote add origin https://github.com/OpenPrinting/foo2zjs.git
git -C "$T/foo2zjs" fetch -q --depth 1 origin "$FOO2ZJS_COMMIT"
git -C "$T/foo2zjs" checkout -q FETCH_HEAD
( cd "$T/foo2zjs"
  cc -O2 -w -o "$T/foo2xqx"   foo2xqx.c   jbig.c jbig_ar.c
  cc -O2 -w -o "$T/xqxdecode" xqxdecode.c jbig.c jbig_ar.c )

echo "==> rastertoxqx"
cc -O2 -Wall -Werror -Wno-deprecated-declarations \
   -DFOO2XQX_PATH="\"$T/foo2xqx\"" -o "$T/rastertoxqx" "$T/rastertoxqx.c" -lcups

# Проверка положения: левый край рисунка в test.pdf — 60 pt, верх ~62 pt от края,
# правый край 535 pt, низ 542 pt. foo2xqx обрезает поля (-u/-l) для A4:
# 176 px по X при 1200 dpi (88 при 600) и 84 px по Y.
check() {
    local res="$1" xres="$2" clipx="$3"
    echo "==> $res"
    cupsfilter -p "$T/m1005.ppd" -m application/vnd.cups-raster -o Resolution="$res" \
        "$T/test.pdf" > "$T/$res.ras" 2>/dev/null
    "$T/rastertoxqx" 1 ci test 1 "" "$T/$res.ras" > "$T/$res.xqx" 2> "$T/$res.log"
    grep -E 'rastertoxqx:' "$T/$res.log" | sed 's/^/    /'
    if grep -q '^ERROR' "$T/$res.log"; then cat "$T/$res.log"; return 1; fi
    ( cd "$T" && ./xqxdecode -d "dec-$res" < "$res.xqx" > /dev/null )
    local pages; pages="$(find "$T" -name "dec-$res-*.pbm" | wc -l | tr -d ' ')"
    [ "$pages" -eq 1 ] || { echo "ожидалась 1 страница, получено $pages" >&2; return 1; }
    python3 - "$(find "$T" -name "dec-$res-*.pbm")" "$xres" "$clipx" <<'PY'
import sys
path, xres, clipx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, 'rb').read()
parts = data.split(maxsplit=3)
assert parts[0] == b'P4', parts[0]
w, h = int(parts[1]), int(parts[2]); bits = parts[3]
bpl = (w + 7) // 8
x0 = y0 = 10**9; x1 = y1 = -1
for y in range(h):
    row = bits[y*bpl:(y+1)*bpl]
    if not any(row): continue
    y0 = min(y0, y); y1 = max(y1, y)
    first = next(i for i, b in enumerate(row) if b)
    last = max(i for i, b in enumerate(row) if b)
    x0 = min(x0, first*8 + 8 - row[first].bit_length())
    x1 = max(x1, last*8 + 8 - (row[last] & -row[last]).bit_length())
assert x1 >= 0, "страница пустая"
exp = (round(60*xres/72) - clipx, round(62*600/72) - 84,
       round(535*xres/72) - clipx, round(542*600/72) - 84)
got = (x0, y0, x1, y1)
print(f"    лист {w}x{h}, рисунок {got}, ожидалось ≈{exp}")
tol = (xres//600*3, 30, xres//600*3, 5)   # по Y верх — это кегль шрифта, допуск больше
bad = [i for i in range(4) if abs(got[i]-exp[i]) > tol[i]]
assert not bad, f"рисунок смещён: {got} vs {exp}"
PY
}

check 1200x600dpi 1200 176
check 600dpi       600  88
echo "==> OK"
