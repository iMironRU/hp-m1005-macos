#!/bin/bash
#
# HP LaserJet M1005 MFP на macOS (Apple Silicon и Intel) — всё в одном скрипте.
#
# Запуск одной строкой (откроется меню):
#
#   curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash
#
# Без меню (параметры после «-s --» или при запуске файла напрямую):
#   --install          установить всё (Command Line Tools, драйвер, принтер, тестовая страница)
#   --install --no-test  то же без тестовой страницы
#   --test             напечатать тестовую страницу
#   --status           показать состояние
#   --default          сделать принтером по умолчанию
#   --clear            отменить все задания в очереди
#   --uninstall        удалить драйвер и принтер
#
# Цепочка печати: приложение → PDF → cgpdftoraster (macOS) → rastertoxqx
# (дизеринг Флойда–Стейнберга в 1 бит) → foo2xqx (OpenPrinting/foo2zjs) → USB.
# Ghostscript, Homebrew и Rosetta не нужны; SIP и песочница CUPS не затрагиваются.
#
# Лицензия: GPLv2 (как foo2zjs).
#
set -euo pipefail

FOO2ZJS_REPO="https://github.com/OpenPrinting/foo2zjs.git"
FOO2ZJS_COMMIT="80499ed5bf6caa2963ad337e37cfda78a80aab1e"

FILTER_DIR="/Library/Printers/foo2xqx/Filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="HP-LaserJet-M1005-MFP-foo2xqx.ppd"
QUEUE="HP_LaserJet_M1005"
ONE_LINER="curl -fsSL https://raw.githubusercontent.com/iMironRU/hp-m1005-macos/main/install.sh | bash"

if [ -t 1 ]; then
    B=$'\033[1m'; BLUE=$'\033[1;34m'; RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YEL=$'\033[1;33m'; N=$'\033[0m'
else
    B=; BLUE=; RED=; GREEN=; YEL=; N=
fi
say()  { printf '%s==>%s %s\n' "$BLUE" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$N" "$*"; }
warn() { printf '%sВнимание:%s %s\n' "$YEL" "$N" "$*" >&2; }
die()  { printf '%sОшибка:%s %s\n' "$RED" "$N" "$*" >&2; exit 1; }

WORK=""
KEEPALIVE_PID=""
cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK"
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

workdir() { [ -n "$WORK" ] || WORK="$(mktemp -d /tmp/m1005.XXXXXX)"; }

# --- Права администратора ----------------------------------------------------
need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    [ -n "$KEEPALIVE_PID" ] && return 0
    say "Нужен пароль администратора Mac"
    sudo -v </dev/tty || die "нужны права администратора."
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    KEEPALIVE_PID=$!
}
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# --- Встроенные файлы --------------------------------------------------------
write_filter_source() {
cat > "$1" <<'__RASTERTOXQX_C__'
/*
 * rastertoxqx — CUPS-фильтр для HP LaserJet M1005 MFP на macOS.
 *
 * Цепочка: PDF → (штатный cgpdftoraster macOS) → CUPS raster
 *          → этот фильтр: дизеринг в 1 бит, PBM → foo2xqx → XQX → принтер.
 *
 * Ghostscript не нужен: растеризацию делает сама macOS.
 * Лицензия: GPLv2 (как foo2zjs).
 */
#include <cups/cups.h>
#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FOO2XQX_PATH
#define FOO2XQX_PATH "/Library/Printers/foo2xqx/Filter/foo2xqx"
#endif

typedef struct { const char *name; int w_pt, h_pt, code, w600, h600; } paper_t;

/* Размеры из foo2xqx-wrapper (1200x600), ширина поделена на 2 для 600x600 */
static const paper_t PAPERS[] = {
  { "A4",        595,  842,  9, 4960, 7016 },
  { "Letter",    612,  792,  1, 5100, 6600 },
  { "Legal",     612, 1008,  5, 5100, 8400 },
  { "Executive", 522,  756,  7, 4350, 6300 },
  { "A5",        420,  595, 11, 3496, 4960 },
};

static int near(int a, int b) { return abs(a - b) <= 3; }

static const paper_t *find_paper(const cups_page_header2_t *h)
{
  for (size_t i = 0; i < sizeof(PAPERS) / sizeof(PAPERS[0]); i++)
    if (near((int)h->PageSize[0], PAPERS[i].w_pt) &&
        near((int)h->PageSize[1], PAPERS[i].h_pt))
      return &PAPERS[i];
  return NULL;
}

/* Яркость пикселя 0..255 (255 = белый) из строки растра */
static int luminance(const cups_page_header2_t *h, const unsigned char *row, unsigned x)
{
  switch (h->cupsBitsPerPixel) {
  case 1: {
    int bit = (row[x >> 3] >> (7 - (x & 7))) & 1;
    if (h->cupsColorSpace == CUPS_CSPACE_K) return bit ? 0 : 255;
    return bit ? 255 : 0;
  }
  case 8:
    if (h->cupsColorSpace == CUPS_CSPACE_K) return 255 - row[x];
    return row[x];                               /* W, SW */
  case 24: {
    const unsigned char *p = row + 3 * x;        /* RGB, sRGB, AdobeRGB */
    return (p[0] * 77 + p[1] * 151 + p[2] * 28) >> 8;
  }
  default:
    return 255;
  }
}

static pid_t spawn_foo2xqx(int *wfd, const paper_t *pp, int w, int h,
                           int density, const char *title, const char *user)
{
  int fds[2];
  if (pipe(fds) < 0) { perror("ERROR: pipe"); return -1; }

  char g[32], p[16], T[16];
  snprintf(g, sizeof g, "-g%dx%d", w, h);
  snprintf(p, sizeof p, "-p%d", pp ? pp->code : 9);
  snprintf(T, sizeof T, "-T%d", density);

  pid_t pid = fork();
  if (pid < 0) { perror("ERROR: fork"); return -1; }
  if (pid == 0) {
    dup2(fds[0], 0);
    close(fds[0]); close(fds[1]);
    execl(FOO2XQX_PATH, "foo2xqx", "-r600x600", g, p, "-m1", "-n1", "-d1", "-s7",
          T, "-J", title, "-U", user, (char *)NULL);
    perror("ERROR: exec foo2xqx");
    _exit(127);
  }
  close(fds[0]);
  *wfd = fds[1];
  return pid;
}

static int write_all(int fd, const void *buf, size_t n)
{
  const unsigned char *b = buf;
  while (n) {
    ssize_t r = write(fd, b, n);
    if (r < 0) { if (errno == EINTR) continue; return -1; }
    b += r; n -= (size_t)r;
  }
  return 0;
}

int main(int argc, char *argv[])
{
  if (argc < 6 || argc > 7) {
    fprintf(stderr, "Usage: %s job user title copies options [file]\n", argv[0]);
    return 1;
  }
  signal(SIGPIPE, SIG_IGN);

  int in = 0;
  if (argc == 7 && (in = open(argv[6], O_RDONLY)) < 0) {
    perror("ERROR: open input");
    return 1;
  }

  /* Опция плотности тонера из PPD: foo2Density=1..5 */
  int density = 3;
  cups_option_t *opts = NULL;
  int nopts = cupsParseOptions(argv[5], 0, &opts);
  const char *d = cupsGetOption("foo2Density", nopts, opts);
  if (d && *d >= '1' && *d <= '5' && !d[1]) density = *d - '0';

  cups_raster_t *ras = cupsRasterOpen(in, CUPS_RASTER_READ);
  cups_page_header2_t h;
  pid_t child = -1;
  int out = -1, W = 0, H = 0, page = 0, rc = 0;
  unsigned char *row = NULL, *pbm = NULL;
  int *err_cur = NULL, *err_next = NULL;

  while (cupsRasterReadHeader2(ras, &h)) {
    page++;
    if (child < 0) {
      const paper_t *pp = find_paper(&h);
      if (pp) { W = pp->w600; H = pp->h600; }
      else    { W = (int)h.cupsWidth; H = (int)h.cupsHeight; }
      fprintf(stderr, "DEBUG: rastertoxqx: %s %dx%d, raster %ux%u, %u bpp, cspace %u, density %d\n",
              pp ? pp->name : "custom(A4 code)", W, H, h.cupsWidth, h.cupsHeight,
              h.cupsBitsPerPixel, h.cupsColorSpace, density);
      child = spawn_foo2xqx(&out, pp, W, H, density, argv[3], argv[2]);
      if (child < 0) { rc = 1; break; }
      pbm = malloc((size_t)(W + 7) / 8);
      err_cur = calloc((size_t)W + 2, sizeof(int));
      err_next = calloc((size_t)W + 2, sizeof(int));
    }
    fprintf(stderr, "PAGE: %d 1\n", page);
    fprintf(stderr, "INFO: Печать страницы %d\n", page);

    free(row);
    row = malloc(h.cupsBytesPerLine ? h.cupsBytesPerLine : 1);
    memset(err_cur, 0, sizeof(int) * ((size_t)W + 2));

    char hdr[64];
    int hl = snprintf(hdr, sizeof hdr, "P4\n%d %d\n", W, H);
    if (write_all(out, hdr, (size_t)hl) < 0) { rc = 1; break; }

    /* macOS (cgpdftoraster) отдаёт растр только печатаемой области
     * (ImageableArea из PPD), без полей. Сдвигаем его на место на листе. */
    int ox = 0, oy = 0;
    if ((int)h.cupsWidth < W && h.HWResolution[0])
      ox = (int)(h.Margins[0] * h.HWResolution[0] / 72);
    if ((int)h.cupsHeight < H && h.HWResolution[1] && h.ImagingBoundingBox[3] > 0 &&
        h.PageSize[1] > h.ImagingBoundingBox[3])
      oy = (int)((h.PageSize[1] - h.ImagingBoundingBox[3]) * h.HWResolution[1] / 72);
    if (ox < 0 || ox >= W) ox = 0;
    if (oy < 0 || oy >= H) oy = 0;
    if (page == 1)
      fprintf(stderr, "DEBUG: rastertoxqx: offset %d,%d px\n", ox, oy);

    const size_t rb = (size_t)(W + 7) / 8;
    unsigned rows_read = 0;
    for (int y = 0; y < H; y++) {
      int ry = y - oy;
      int have = ry >= 0 && (unsigned)ry < h.cupsHeight;
      if (have) {
        if (cupsRasterReadPixels(ras, row, h.cupsBytesPerLine) == 0) have = 0;
        rows_read++;
      }
      memset(pbm, 0, rb);
      memset(err_next, 0, sizeof(int) * ((size_t)W + 2));
      for (int x = 0; x < W; x++) {
        int rx = x - ox;
        int v = (have && rx >= 0 && (unsigned)rx < h.cupsWidth) ? luminance(&h, row, (unsigned)rx) : 255;
        v += err_cur[x + 1] / 16;
        int black = v < 128;
        int e = v - (black ? 0 : 255);
        if (black) pbm[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
        /* Флойд–Стейнберг */
        err_cur[x + 2]  += e * 7;
        err_next[x]     += e * 3;
        err_next[x + 1] += e * 5;
        err_next[x + 2] += e * 1;
      }
      int *t = err_cur; err_cur = err_next; err_next = t;
      if (write_all(out, pbm, rb) < 0) { rc = 1; break; }
    }
    /* Дочитать хвост растра, если он длиннее бумаги */
    for (unsigned y = rows_read; y < h.cupsHeight; y++)
      cupsRasterReadPixels(ras, row, h.cupsBytesPerLine);
    if (rc) break;
  }

  cupsRasterClose(ras);
  if (in) close(in);
  if (out >= 0) close(out);
  if (child > 0) {
    int st = 0;
    waitpid(child, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
      fprintf(stderr, "ERROR: foo2xqx завершился с ошибкой (status %d)\n", st);
      rc = 1;
    }
  }
  if (page == 0) fprintf(stderr, "ERROR: Нет страниц во входных данных\n");
  free(row); free(pbm); free(err_cur); free(err_next);
  cupsFreeOptions(nopts, opts);
  return (rc || page == 0) ? 1 : 0;
}
__RASTERTOXQX_C__
}

write_ppd() {
cat > "$1" <<'__PPD__'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "M1005XQX.PPD"
*Manufacturer: "HP"
*Product: "(HP LaserJet M1005)"
*ModelName: "HP LaserJet M1005 MFP foo2xqx"
*ShortNickName: "HP LaserJet M1005 foo2xqx"
*NickName: "HP LaserJet M1005 MFP, foo2xqx (native macOS raster)"
*1284DeviceID: "MFG:Hewlett-Packard;MDL:HP LaserJet M1005;"
*PSVersion: "(3010.000) 0"
*LanguageLevel: "3"
*ColorDevice: False
*DefaultColorSpace: Gray
*FileSystem: False
*Throughput: "14"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42
*cupsVersion: 2.2
*cupsModelNumber: 0
*cupsManualCopies: True
*cupsFilter2: "application/vnd.cups-raster application/vnd.hp-xqx 100 /Library/Printers/foo2xqx/Filter/rastertoxqx"

*OpenUI *PageSize/Media Size: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: A4
*PageSize A4/A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageSize Letter/US Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*PageSize Legal/US Legal: "<</PageSize[612 1008]/ImagingBBox null>>setpagedevice"
*PageSize Executive/Executive: "<</PageSize[522 756]/ImagingBBox null>>setpagedevice"
*PageSize A5/A5: "<</PageSize[420 595]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize

*OpenUI *PageRegion/Page Region: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: A4
*PageRegion A4/A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageRegion Letter/US Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*PageRegion Legal/US Legal: "<</PageSize[612 1008]/ImagingBBox null>>setpagedevice"
*PageRegion Executive/Executive: "<</PageSize[522 756]/ImagingBBox null>>setpagedevice"
*PageRegion A5/A5: "<</PageSize[420 595]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion

*DefaultImageableArea: A4
*ImageableArea A4/A4: "12 12 583 830"
*ImageableArea Letter/US Letter: "12 12 600 780"
*ImageableArea Legal/US Legal: "12 12 600 996"
*ImageableArea Executive/Executive: "12 12 510 744"
*ImageableArea A5/A5: "12 12 408 583"

*DefaultPaperDimension: A4
*PaperDimension A4/A4: "595 842"
*PaperDimension Letter/US Letter: "612 792"
*PaperDimension Legal/US Legal: "612 1008"
*PaperDimension Executive/Executive: "522 756"
*PaperDimension A5/A5: "420 595"

*OpenUI *Resolution/Resolution: PickOne
*OrderDependency: 20 AnySetup *Resolution
*DefaultResolution: 600dpi
*Resolution 600dpi/600 DPI: "<</HWResolution[600 600]/cupsBitsPerColor 8/cupsRowCount 0/cupsRowFeed 0/cupsRowStep 0/cupsColorSpace 18/cupsColorOrder 0>>setpagedevice"
*CloseUI: *Resolution

*OpenUI *foo2Density/Toner Density: PickOne
*OrderDependency: 30 AnySetup *foo2Density
*Defaultfoo2Density: 3
*foo2Density 1/1 - Lightest: ""
*foo2Density 2/2 - Light: ""
*foo2Density 3/3 - Medium: ""
*foo2Density 4/4 - Dark: ""
*foo2Density 5/5 - Darkest: ""
*CloseUI: *foo2Density

*DefaultFont: Courier
*Font Courier: Standard "(002.004S)" Standard ROM
*Font Helvetica: Standard "(001.006S)" Standard ROM
*Font Times-Roman: Standard "(001.007S)" Standard ROM

*% End of HP-LaserJet-M1005-MFP-foo2xqx.ppd
__PPD__
}

write_test_pdf() {
base64 -D > "$1" <<'__TEST_PDF__'
JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2Jq
CjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2Jq
CjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA1OTUg
ODQyXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAw
IFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAxMTcxID4+CnN0cmVhbQpCVCAvRjEgMjgg
VGYgNjAgNzYwIFRkIChIUCBMYXNlckpldCBNMTAwNSBNRlApIFRqIEVUCkJUIC9GMSAxNCBUZiA2
MCA3MzAgVGQgKG1hY09TICsgZm9vMnhxeDogdGVzdCBwYWdlKSBUaiBFVApCVCAvRjEgMTAgVGYg
NjAgNzEyIFRkIChJZiB5b3UgY2FuIHJlYWQgdGhpcywgdGhlIGRyaXZlciB3b3Jrcy4pIFRqIEVU
CjAuNSB3IDYwIDYwMCBtIDUzNSA2MDAgbCBTCjAuMDAwIGcgNjAuMDAgNTIwIDIzLjc1IDYwIHJl
IGYKMC4wNTMgZyA4My43NSA1MjAgMjMuNzUgNjAgcmUgZgowLjEwNSBnIDEwNy41MCA1MjAgMjMu
NzUgNjAgcmUgZgowLjE1OCBnIDEzMS4yNSA1MjAgMjMuNzUgNjAgcmUgZgowLjIxMSBnIDE1NS4w
MCA1MjAgMjMuNzUgNjAgcmUgZgowLjI2MyBnIDE3OC43NSA1MjAgMjMuNzUgNjAgcmUgZgowLjMx
NiBnIDIwMi41MCA1MjAgMjMuNzUgNjAgcmUgZgowLjM2OCBnIDIyNi4yNSA1MjAgMjMuNzUgNjAg
cmUgZgowLjQyMSBnIDI1MC4wMCA1MjAgMjMuNzUgNjAgcmUgZgowLjQ3NCBnIDI3My43NSA1MjAg
MjMuNzUgNjAgcmUgZgowLjUyNiBnIDI5Ny41MCA1MjAgMjMuNzUgNjAgcmUgZgowLjU3OSBnIDMy
MS4yNSA1MjAgMjMuNzUgNjAgcmUgZgowLjYzMiBnIDM0NS4wMCA1MjAgMjMuNzUgNjAgcmUgZgow
LjY4NCBnIDM2OC43NSA1MjAgMjMuNzUgNjAgcmUgZgowLjczNyBnIDM5Mi41MCA1MjAgMjMuNzUg
NjAgcmUgZgowLjc4OSBnIDQxNi4yNSA1MjAgMjMuNzUgNjAgcmUgZgowLjg0MiBnIDQ0MC4wMCA1
MjAgMjMuNzUgNjAgcmUgZgowLjg5NSBnIDQ2My43NSA1MjAgMjMuNzUgNjAgcmUgZgowLjk0NyBn
IDQ4Ny41MCA1MjAgMjMuNzUgNjAgcmUgZgoxLjAwMCBnIDUxMS4yNSA1MjAgMjMuNzUgNjAgcmUg
ZgowIGcgNjAgMzAwIDIwMCAxNTAgcmUgZgowLjMgdyAzMDAgMzAwIG0gNTM1IDMwMCBsIFMKMC42
IHcgMzAwIDMxNSBtIDUzNSAzMTUgbCBTCjAuOSB3IDMwMCAzMzAgbSA1MzUgMzMwIGwgUwoxLjIg
dyAzMDAgMzQ1IG0gNTM1IDM0NSBsIFMKMS41IHcgMzAwIDM2MCBtIDUzNSAzNjAgbCBTCjEuOCB3
IDMwMCAzNzUgbSA1MzUgMzc1IGwgUwoyLjEgdyAzMDAgMzkwIG0gNTM1IDM5MCBsIFMKMi40IHcg
MzAwIDQwNSBtIDUzNSA0MDUgbCBTCjIuNyB3IDMwMCA0MjAgbSA1MzUgNDIwIGwgUwozLjAgdyAz
MDAgNDM1IG0gNTM1IDQzNSBsIFMKZW5kc3RyZWFtCmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9G
b250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgow
IDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAw
MDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjQxIDAwMDAwIG4gCjAwMDAwMDE0NjMg
MDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA2IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoxNTMz
CiUlRU9GCg==
__TEST_PDF__
}

# --- Command Line Tools ------------------------------------------------------
clt_ok() {
    xcode-select -p >/dev/null 2>&1 || return 1
    local sdk
    sdk="$(xcrun --show-sdk-path 2>/dev/null)" || return 1
    [ -f "$sdk/usr/include/cups/raster.h" ] && command -v git >/dev/null 2>&1 \
        && command -v cc >/dev/null 2>&1
}

ensure_clt() {
    if clt_ok; then ok "Command Line Tools: есть"; return; fi
    need_root
    say "Command Line Tools не найдены — устанавливаю (5–15 минут)"

    # Тихая установка через softwareupdate (так же делает установщик Homebrew).
    local flag="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    as_root touch "$flag"
    local label
    label="$(softwareupdate -l 2>/dev/null \
        | grep -E '^[[:space:]]*\* Label: Command Line Tools' \
        | sed -E 's/^[[:space:]]*\* Label: //' | sort -V | tail -n1 || true)"
    if [ -n "$label" ]; then
        say "Пакет: $label"
        as_root softwareupdate -i "$label" --verbose || true
    fi
    as_root rm -f "$flag"

    # Не вышло тихо — стандартное окно установки, ждём завершения.
    if ! xcode-select -p >/dev/null 2>&1; then
        say "Открываю окно установки Command Line Tools — нажмите «Установить» и дождитесь окончания"
        xcode-select --install >/dev/null 2>&1 || true
        local waited=0
        until xcode-select -p >/dev/null 2>&1; do
            sleep 10; waited=$((waited + 10))
            [ "$waited" -ge 3600 ] && die "Command Line Tools не установились за час. Запустите скрипт ещё раз после установки."
        done
    fi
    clt_ok || die "Command Line Tools установлены не полностью. Выполните: sudo rm -rf /Library/Developer/CommandLineTools — и запустите скрипт снова."
    ok "Command Line Tools установлены"
}

# --- Действия ----------------------------------------------------------------
find_usb_uri() {
    as_root lpinfo --include-schemes usb -v 2>/dev/null \
        | awk '!f && /^direct usb:\/\/.*M1005/ {print $2; f=1}' || true
}

do_install() {
    local do_test="${1:-1}"
    need_root
    ensure_clt
    workdir
    local build="$WORK/build"; mkdir -p "$build"

    say "Загружаю foo2zjs @ ${FOO2ZJS_COMMIT:0:12}"
    git -C "$build" init -q foo2zjs
    git -C "$build/foo2zjs" remote add origin "$FOO2ZJS_REPO"
    git -C "$build/foo2zjs" fetch -q --depth 1 origin "$FOO2ZJS_COMMIT"
    git -C "$build/foo2zjs" checkout -q FETCH_HEAD

    say "Собираю foo2xqx ($(uname -m))"
    ( cd "$build/foo2zjs" && cc -O2 -w -o "$build/foo2xqx" foo2xqx.c jbig.c jbig_ar.c )

    say "Собираю фильтр rastertoxqx"
    write_filter_source "$build/rastertoxqx.c"
    cc -O2 -Wall -Wno-deprecated-declarations \
       -DFOO2XQX_PATH="\"$FILTER_DIR/foo2xqx\"" \
       -o "$build/rastertoxqx" "$build/rastertoxqx.c" -lcups
    write_ppd "$build/$PPD_NAME"

    say "Устанавливаю фильтры в $FILTER_DIR"
    as_root install -d -o root -g wheel -m 755 "$FILTER_DIR"
    as_root install -o root -g wheel -m 755 "$build/foo2xqx" "$build/rastertoxqx" "$FILTER_DIR/"

    say "Устанавливаю PPD"
    as_root install -d -o root -g wheel -m 755 "$PPD_DIR"
    as_root install -o root -g wheel -m 644 "$build/$PPD_NAME" "$PPD_DIR/$PPD_NAME"

    say "Ищу принтер на USB"
    local uri; uri="$(find_usb_uri)"
    if [ -z "$uri" ]; then
        echo
        warn "драйвер установлен, но принтер на USB не найден."
        echo "Включите принтер, подключите кабель напрямую (без хаба) и запустите снова:"
        echo "  $ONE_LINER"
        return 1
    fi
    echo "    $uri"

    say "Создаю принтер $QUEUE"
    as_root lpadmin -x "$QUEUE" 2>/dev/null || true
    as_root lpadmin -p "$QUEUE" -E -v "$uri" -P "$PPD_DIR/$PPD_NAME" \
        -D "HP LaserJet M1005 MFP" -o printer-is-shared=false
    as_root cupsenable "$QUEUE"
    as_root cupsaccept "$QUEUE"

    [ "$do_test" -eq 1 ] && do_test_page
    echo
    say "${GREEN}Готово.${N} Принтер «HP LaserJet M1005 MFP» доступен во всех приложениях."
}

queue_exists() { lpstat -p "$QUEUE" >/dev/null 2>&1; }

do_test_page() {
    queue_exists || { warn "принтер $QUEUE не установлен — сначала выберите установку."; return 1; }
    workdir
    write_test_pdf "$WORK/test.pdf"
    say "Печатаю тестовую страницу"
    lp -d "$QUEUE" -t "M1005 test" "$WORK/test.pdf"
    echo "Если страница не вышла за ~30 секунд, выберите в меню «Состояние»."
}

do_status() {
    say "Состояние"
    if clt_ok; then ok "Command Line Tools"; else bad "Command Line Tools не установлены"; fi
    for f in "$FILTER_DIR/foo2xqx" "$FILTER_DIR/rastertoxqx" "$PPD_DIR/$PPD_NAME"; do
        if [ -e "$f" ]; then ok "$f"; else bad "нет $f"; fi
    done
    if queue_exists; then
        ok "принтер: $(lpstat -p "$QUEUE" 2>/dev/null | head -1)"
        local def; def="$(lpstat -d 2>/dev/null || true)"
        case "$def" in *"$QUEUE"*) ok "принтер по умолчанию" ;; *) echo "    (не по умолчанию)" ;; esac
    else
        bad "принтер $QUEUE не создан"
    fi
    local uri; uri="$(lpinfo --include-schemes usb -v 2>/dev/null \
        | awk '!f && /^direct usb:\/\/.*M1005/ {print $2; f=1}' || true)"
    if [ -n "$uri" ]; then ok "на USB: $uri"; else bad "принтер на USB не виден (или нужен пароль для проверки)"; fi
    if queue_exists; then
        local jobs; jobs="$(lpstat -W not-completed -o "$QUEUE" 2>/dev/null || true)"
        if [ -n "$jobs" ]; then echo "  Задания в очереди:"; echo "$jobs" | sed 's/^/    /'
        else ok "очередь заданий пуста"; fi
    fi
}

do_default() {
    queue_exists || { warn "принтер $QUEUE не установлен."; return 1; }
    lpoptions -d "$QUEUE" >/dev/null && ok "$QUEUE — принтер по умолчанию"
}

do_clear() {
    queue_exists || { warn "принтер $QUEUE не установлен."; return 1; }
    need_root
    as_root cancel -a "$QUEUE" && ok "все задания отменены"
    as_root cupsenable "$QUEUE" 2>/dev/null || true
}

do_uninstall() {
    need_root
    say "Удаляю драйвер и принтер"
    as_root lpadmin -x "$QUEUE" 2>/dev/null || true
    as_root rm -rf /Library/Printers/foo2xqx
    as_root rm -f "$PPD_DIR/$PPD_NAME"
    ok "драйвер и принтер $QUEUE удалены"
}

# Выполнить пункт в подоболочке с set -e: ошибка прерывает только этот пункт,
# меню продолжает работать.
run() {
    set +e
    ( trap cleanup EXIT; set -e; "$@" )
    local rc=$?
    set -e
    [ "$rc" -eq 0 ] || warn "действие завершилось с ошибкой (код $rc)."
    return 0
}

usage() {
    cat <<__USAGE__
Использование:
  $ONE_LINER                     — меню
  $ONE_LINER -s -- --install     — установить всё
  $ONE_LINER -s -- --install --no-test
  $ONE_LINER -s -- --test | --status | --default | --clear | --uninstall
__USAGE__
}

# --- Меню --------------------------------------------------------------------
menu() {
    while true; do
        echo
        echo "${B}HP LaserJet M1005 MFP — драйвер для macOS${N}"
        echo "  1) Установить (всё необходимое + принтер + тестовая страница)"
        echo "  2) Установить без тестовой страницы"
        echo "  3) Напечатать тестовую страницу"
        echo "  4) Состояние"
        echo "  5) Сделать принтером по умолчанию"
        echo "  6) Отменить все задания в очереди"
        echo "  7) Удалить драйвер и принтер"
        echo "  0) Выход"
        printf "Выберите пункт: "
        local c; IFS= read -r c </dev/tty || exit 0
        case "$c" in
            1) run do_install 1 ;;
            2) run do_install 0 ;;
            3) run do_test_page ;;
            4) run do_status ;;
            5) run do_default ;;
            6) run do_clear ;;
            7) printf "Точно удалить? [y/N] "; local y; IFS= read -r y </dev/tty
               case "$y" in y|Y|д|Д) run do_uninstall ;; *) echo "Отменено." ;; esac ;;
            0|q|Q|"") exit 0 ;;
            *) warn "нет такого пункта: $c" ;;
        esac
    done
}

# Всё тело в main: при оборванной загрузке через curl | bash
# ничего не выполнится частично.
main() {
    [ "$(uname -s)" = "Darwin" ] || die "скрипт только для macOS."

    if [ $# -eq 0 ]; then
        if { : </dev/tty; } 2>/dev/null; then menu; else do_install 1; fi
        return
    fi

    local action="" test=1
    for a in "$@"; do
        case "$a" in
            --install)   action=install ;;
            --no-test)   test=0; action="${action:-install}" ;;
            --test)      action=test ;;
            --status)    action=status ;;
            --default)   action=default ;;
            --clear)     action=clear ;;
            --uninstall) action=uninstall ;;
            -h|--help)   usage; return ;;
            *) die "неизвестный параметр: $a (см. --help)" ;;
        esac
    done
    [ -n "$action" ] || { usage; return 1; }
    case "$action" in
        install)   do_install "$test" ;;
        test)      do_test_page ;;
        status)    do_status ;;
        default)   do_default ;;
        clear)     do_clear ;;
        uninstall) do_uninstall ;;
    esac
}

main "$@"
