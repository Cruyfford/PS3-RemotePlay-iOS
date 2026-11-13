/*
 * premo - PS3 Remote Play (PREMO) client core.
 * Protocol logic follows Open Remote Play (GPLv2). This file is GPLv2 as well.
 */
#ifndef PREMO_H
#define PREMO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct premo premo_t;

enum { PREMO_IDLE = 0, PREMO_CONNECTING = 1, PREMO_STREAMING = 2, PREMO_ENDED = 3, PREMO_FAILED = 4 };
enum { PREMO_VIDEO = 0, PREMO_AUDIO = 1 };

/* pad button codes: high byte = offset in the pad state, low byte = bit mask */
enum {
    PREMO_BTN_SELECT = 0x0501, PREMO_BTN_L3 = 0x0502, PREMO_BTN_R3 = 0x0504, PREMO_BTN_START = 0x0508,
    PREMO_BTN_UP = 0x0510, PREMO_BTN_RIGHT = 0x0520, PREMO_BTN_DOWN = 0x0540, PREMO_BTN_LEFT = 0x0580,
    PREMO_BTN_R2 = 0x0701, PREMO_BTN_L2 = 0x0702, PREMO_BTN_L1 = 0x0704, PREMO_BTN_R1 = 0x0708,
    PREMO_BTN_TRIANGLE = 0x0710, PREMO_BTN_CIRCLE = 0x0720, PREMO_BTN_CROSS = 0x0740, PREMO_BTN_SQUARE = 0x0780
};
/* analog axis offsets, value 0..255 (128 = centre) */
enum { PREMO_AXIS_RX = 0x08, PREMO_AXIS_RY = 0x0a, PREMO_AXIS_LX = 0x0c, PREMO_AXIS_LY = 0x0e };

typedef struct {
    char host[128];
    int port;               /* 0 = 9293 */
    uint8_t psp_id[16];
    uint8_t pkey[16];
    uint8_t psp_mac[6];
    char nickname[64];
    int bitrate;            /* 0 = 1024000 */
} premo_config;

typedef struct {
    char video_codec[16];   /* "AVC" or "M4V" */
    char audio_codec[16];   /* "M4A" or "AT3" */
    int audio_rate, audio_channels, audio_bitrate, video_fps;
    char exec_mode[16];
    char ps3_name[128];
} premo_info;

typedef struct {
    void *ctx;
    /* session thread, every time a session (re)starts and before any packet of it */
    void (*on_session)(void *ctx, const premo_info *info);
    /* stream threads; data is decrypted and only valid during the call */
    void (*on_packet)(void *ctx, int kind, uint8_t magic, uint32_t clock, const uint8_t *data, int len);
} premo_sink;

premo_t *premo_start(const premo_config *cfg, const premo_sink *sink);
void premo_stop(premo_t *p);                    /* ends the session, joins threads, frees p */
int premo_state(premo_t *p);
void premo_status(premo_t *p, char *out, int cap);
void premo_button(premo_t *p, int code, int down);
void premo_axis(premo_t *p, int offset, int value);
void premo_home(premo_t *p);                    /* PS button */

/* helpers */
int premo_hex(const char *hex, uint8_t *out, int len);   /* 0 on success; ':' '-' and spaces are skipped */
void premo_aes_cbc(const uint8_t key[16], const uint8_t iv[16], uint8_t *data, int len, int encrypt);

#ifdef __cplusplus
}
#endif
#endif
