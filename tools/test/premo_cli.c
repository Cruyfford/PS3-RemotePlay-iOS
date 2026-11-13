/* Linux/macOS test client for Core/premo.c: dumps decrypted packets and presses a few buttons. */
#include "premo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *vf, *af;
static int vn, an;

static void on_session(void *ctx, const premo_info *i) {
    (void)ctx;
    printf("session: video=%s audio=%s rate=%d ch=%d fps=%d mode=%s ps3=%s\n", i->video_codec, i->audio_codec,
           i->audio_rate, i->audio_channels, i->video_fps, i->exec_mode, i->ps3_name);
}
static void on_packet(void *ctx, int kind, uint8_t magic, uint32_t clock, const uint8_t *d, int len) {
    (void)ctx; (void)magic; (void)clock;
    if (kind == PREMO_VIDEO) { fwrite(d, 1, (size_t)len, vf); vn++; }
    else { fwrite(d, 1, (size_t)len, af); an++; }
}

int main(int argc, char **argv) {
    premo_config c;
    premo_sink s = {NULL, on_session, on_packet};
    char st[256];
    if (argc < 6) { fprintf(stderr, "usage: premo_cli host psp_id pkey mac seconds\n"); return 2; }
    memset(&c, 0, sizeof c);
    snprintf(c.host, sizeof c.host, "%s", argv[1]);
    if (premo_hex(argv[2], c.psp_id, 16) || premo_hex(argv[3], c.pkey, 16) || premo_hex(argv[4], c.psp_mac, 6)) {
        fprintf(stderr, "bad hex\n"); return 2;
    }
    vf = fopen("c_video.bin", "wb"); af = fopen("c_audio.bin", "wb");
    premo_t *p = premo_start(&c, &s);
    int secs = atoi(argv[5]);
    for (int i = 0; i < secs * 10; i++) {
        usleep(100000);
        if (i == 15) premo_button(p, PREMO_BTN_RIGHT, 1);
        if (i == 16) premo_button(p, PREMO_BTN_RIGHT, 0);
        if (i == 20) premo_axis(p, PREMO_AXIS_LX, 255);
        if (i == 21) premo_axis(p, PREMO_AXIS_LX, 128);
        if (i == 25) premo_home(p);
        if (i >= 30 && i < 30 + 70 && argc > 6) premo_button(p, PREMO_BTN_CROSS, i & 1);
        if (premo_state(p) == PREMO_FAILED || premo_state(p) == PREMO_ENDED) break;
    }
    premo_status(p, st, sizeof st);
    printf("state=%d status=%s\nvideo packets=%d audio packets=%d\n", premo_state(p), st, vn, an);
    premo_stop(p);
    fclose(vf); fclose(af);
    return 0;
}
