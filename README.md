# HP LaserJet M1005 MFP на macOS (M1/M2/M3/M4 и Intel)

Печать через open-source драйвер **foo2xqx** (OpenPrinting/foo2zjs), собранный локально.
Растеризацию PDF делает сама macOS, поэтому Ghostscript, Homebrew и Rosetta не нужны.
Каталоги SIP и песочница CUPS не затрагиваются.

## Установка одной строкой

Включите принтер, подключите его по USB, откройте «Терминал» и вставьте:

```bash
curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash
```

Скрипт спросит пароль администратора и сам сделает всё остальное: при необходимости
установит Command Line Tools, соберёт драйвер, создаст принтер и напечатает тестовую страницу.

Варианты:

```bash
# без тестовой страницы
curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash -s -- --no-test

# удаление
curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash -s -- --uninstall
```

## Установка из клона

```bash
git clone https://github.com/iMironRU/hp-m1005-macos.git
cd hp-m1005-macos
sudo ./setup.sh
```

## Что ставится

| Файл | Куда |
|---|---|
| `foo2xqx` (собирается из foo2zjs @ 80499ed) | `/Library/Printers/foo2xqx/Filter/` |
| `rastertoxqx` (собирается из `rastertoxqx.c`) | `/Library/Printers/foo2xqx/Filter/` |
| `HP-LaserJet-M1005-MFP-foo2xqx.ppd` | `/Library/Printers/PPDs/Contents/Resources/` |

Цепочка печати: приложение → PDF → `cgpdftoraster` (macOS) → `rastertoxqx`
(дизеринг Флойда–Стейнберга в 1 бит) → `foo2xqx` → USB.

## Настройки в диалоге печати

Размер бумаги: A4, Letter, Legal, Executive, A5. Плотность тонера: 1–5.

## Удаление

```bash
sudo ./uninstall.sh
```

## Ограничения

Поддерживается только печать, сканер не поддерживается. Разрешение 600×600 dpi.

## Лицензия

GPLv2, как и [foo2zjs](https://github.com/OpenPrinting/foo2zjs).
