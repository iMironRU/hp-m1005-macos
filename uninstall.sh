#!/bin/bash
# Удаление драйвера HP LaserJet M1005 (foo2xqx) и очереди печати.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo: sudo $0" >&2; exit 1; }
lpadmin -x HP_LaserJet_M1005 2>/dev/null || true
rm -rf /Library/Printers/foo2xqx
rm -f  /Library/Printers/PPDs/Contents/Resources/HP-LaserJet-M1005-MFP-foo2xqx.ppd
echo "Драйвер и очередь HP_LaserJet_M1005 удалены."
