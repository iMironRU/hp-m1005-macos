# HP LaserJet M1005 MFP на macOS (M1/M2/M3/M4 и Intel)

Печать через open-source драйвер **foo2xqx** (OpenPrinting/foo2zjs), собранный локально.
Растеризацию PDF делает сама macOS, поэтому Ghostscript, Homebrew и Rosetta не нужны.
Каталоги SIP и песочница CUPS не затрагиваются.

Всё — один файл [`install.sh`](install.sh): внутри встроены исходник фильтра, PPD и тестовая страница.

## Установка одной строкой

Включите принтер, подключите его по USB, откройте «Терминал» и вставьте:

```bash
curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash
```

Откроется меню:

```
  1) Установить (всё необходимое + принтер + тестовая страница)
  2) Установить без тестовой страницы
  3) Напечатать тестовую страницу
  4) Состояние
  5) Сделать принтером по умолчанию
  6) Отменить все задания в очереди
  7) Удалить драйвер и принтер
  8) Диагностика (тест + подробный журнал в файл)
  0) Выход
```

Пароль администратора скрипт спросит сам. Если нет Command Line Tools, он их установит
(тихо через `softwareupdate`, а если не выйдет — откроет стандартное окно установки и дождётся).

### Без меню

```bash
curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash -s -- --install
```

Параметры: `--install`, `--install --no-test`, `--test`, `--status`, `--default`, `--clear`, `--diag`, `--uninstall`, `--help`.

## Что ставится

| Файл | Куда |
|---|---|
| `foo2xqx` (собирается из foo2zjs @ 80499ed) | `/Library/Printers/foo2xqx/Filter/` |
| `rastertoxqx` (встроенный в скрипт исходник) | `/Library/Printers/foo2xqx/Filter/` |
| `HP-LaserJet-M1005-MFP-foo2xqx.ppd` | `/Library/Printers/PPDs/Contents/Resources/` |

Цепочка печати: приложение → PDF → `cgpdftoraster` (macOS) → `rastertoxqx`
(дизеринг Флойда–Стейнберга в 1 бит) → `foo2xqx` → USB.

## Настройки в диалоге печати

Размер бумаги: A4, Letter, Legal, Executive, A5. Плотность тонера: 1–5.
Разрешение: 1200×600 (по умолчанию, как в штатном foo2zjs) или 600×600.

## Если печатает не то

Выберите в меню пункт 8 «Диагностика»: скрипт напечатает тест с подробным журналом CUPS
и сохранит отчёт `m1005-diag.txt` на Рабочий стол.

## Ограничения

Поддерживается только печать, сканер не поддерживается.

## Лицензия

GPLv2, как и [foo2zjs](https://github.com/OpenPrinting/foo2zjs).
