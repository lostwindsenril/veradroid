#include <stdio.h>
/* FBInk stand-in for the native veradroid-epd test (tests/epd-test.sh): no panel, every refresh is logged by epd.c
   itself; fbink_wait_for_complete sleeps like a PW6 panel (DU 135 ms, the rest 205 ms) so PACE / busy logic runs. */
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "fbink.h"
static uint32_t last_marker = 0;
static int last_slow = 0;
int fbink_open(void) { return open("/dev/null", O_RDWR); }
int fbink_close(int fd) { return close(fd); }
int fbink_init(int fd, const FBInkConfig *restrict c) { (void)fd; (void)c; return 0; }
void fbink_get_state(const FBInkConfig *restrict c, FBInkState *restrict s)
{
    (void)c; memset(s, 0, sizeof(*s));
    s->is_mtk = 1; s->screen_width = 1272; s->screen_height = 1696; s->bpp = 8;
}
int fbink_print_raw_data(int fd, const unsigned char *restrict d, const int w, const int h, const size_t len, short x, short y,
                         const FBInkConfig *restrict c)
{
    (void)fd; (void)d; (void)w; (void)h; (void)len; (void)x; (void)y;
    last_marker++; last_slow = c->wfm_mode != WFM_DU && c->wfm_mode != WFM_A2;
    fprintf(stderr, "stub: wfm=%d dither=%d full=%d\n", (int)c->wfm_mode, (int)c->dithering_mode, (int)c->is_flashing);   /* text dithering / CLEAN checks */
    return 0;
}
int fbink_wait_for_complete(int fd, uint32_t m) { (void)fd; (void)m; usleep(last_slow ? 205000 : 135000); return 0; }
uint32_t fbink_get_last_marker(void) { return last_marker; }
int fbink_mtk_set_swipe_data(MTK_SWIPE_DIRECTION_INDEX_T d, uint8_t s) { (void)d; (void)s; return 0; }
