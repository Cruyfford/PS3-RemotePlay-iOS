/* Linux/macOS test for Core/rp_player.c: decodes the stream, writes the last frame as PPM, reports audio level. */
#include "rp_player.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: player_cli host psp_id pkey mac seconds\n"); return 2; }
    rp_player *p = rp_start(argv[1], argv[2], argv[3], argv[4], "test", 0);
    if (!p) { fprintf(stderr, "bad parameters\n"); return 2; }
    static uint8_t frame[1920 * 1088 * 4];
    static float l[480], r[480];
    int w = 0, h = 0, shown = 0, ticks = atoi(argv[5]) * 100;
    unsigned serial = 0;
    double energy = 0; long samples = 0, nonzero = 0;
    char st[256];
    for (int i = 0; i < ticks; i++) {
        usleep(10000);
        if (rp_video_copy(p, frame, sizeof frame, &w, &h, &serial)) shown++;
        rp_audio_read(p, l, r, 480);
        for (int k = 0; k < 480; k++) { energy += l[k] * l[k]; samples++; if (l[k] != 0) nonzero++; }
        if (rp_state(p) == PREMO_FAILED || rp_state(p) == PREMO_ENDED) break;
    }
    int vf, af, er;
    rp_stats(p, &vf, &af, &er);
    rp_status(p, st, sizeof st);
    printf("state=%d status=%s\nsize=%dx%d decoded video=%d shown=%d audio frames=%d errors=%d\n", rp_state(p), st, w, h, vf, shown, af, er);
    printf("audio rms=%.4f played=%.0f%%\n", sqrt(energy / (samples ? samples : 1)), samples ? 100.0 * nonzero / samples : 0);
    if (w > 0) {
        FILE *f = fopen("c_frame.ppm", "wb");
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (int i = 0; i < w * h; i++) { fputc(frame[i * 4 + 2], f); fputc(frame[i * 4 + 1], f); fputc(frame[i * 4], f); }
        fclose(f);
    }
    rp_stop(p);
    return 0;
}
