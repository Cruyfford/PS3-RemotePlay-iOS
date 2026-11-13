/*
 * rp_player - PREMO session + FFmpeg decoding, with a polling API that is easy to call from Swift.
 */
#ifndef RP_PLAYER_H
#define RP_PLAYER_H

#include <stdint.h>
#include "premo.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rp_player rp_player;

#define RP_AUDIO_RATE 48000

/* hex strings: psp_id (32 digits), pkey (32 digits), mac (12 digits, ':' allowed). Returns NULL on bad input. */
rp_player *rp_start(const char *host, const char *psp_id_hex, const char *pkey_hex, const char *mac_hex,
                    const char *nickname, int bitrate);
void rp_stop(rp_player *p);

int rp_state(rp_player *p);                               /* PREMO_* state */
void rp_status(rp_player *p, char *out, int cap);

/* Copies the newest frame (BGRA, stride = width * 4) if it differs from *serial. Returns 1 when copied. */
int rp_video_copy(rp_player *p, uint8_t *dst, int cap, int *width, int *height, unsigned *serial);

/* Fills exactly `frames` float samples per channel at RP_AUDIO_RATE (silence when nothing is buffered). */
void rp_audio_read(rp_player *p, float *left, float *right, int frames);

void rp_button(rp_player *p, int code, int down);
void rp_axis(rp_player *p, int offset, int value);
void rp_home(rp_player *p);

void rp_stats(rp_player *p, int *video_frames, int *audio_frames, int *decode_errors);

#ifdef __cplusplus
}
#endif
#endif
