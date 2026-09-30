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

    const size_t rb = (size_t)(W + 7) / 8;
    for (int y = 0; y < H; y++) {
      int have = (unsigned)y < h.cupsHeight;
      if (have && cupsRasterReadPixels(ras, row, h.cupsBytesPerLine) == 0) have = 0;
      memset(pbm, 0, rb);
      memset(err_next, 0, sizeof(int) * ((size_t)W + 2));
      for (int x = 0; x < W; x++) {
        int v = (have && (unsigned)x < h.cupsWidth) ? luminance(&h, row, (unsigned)x) : 255;
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
    for (unsigned y = (unsigned)H; y < h.cupsHeight; y++)
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
