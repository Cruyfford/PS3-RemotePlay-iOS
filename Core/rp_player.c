/*
 * rp_player - PREMO session + FFmpeg decoding. GPLv2.
 */
#include "rp_player.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#define RING_FRAMES RP_AUDIO_RATE           /* 1 s of capacity */
#define RING_HIGH (RP_AUDIO_RATE * 3 / 10)  /* above 300 ms: drop to keep latency low */
#define RING_KEEP (RP_AUDIO_RATE * 12 / 100)
#define RING_PRIME (RP_AUDIO_RATE * 6 / 100)

struct rp_player {
    premo_t *premo;
    pthread_mutex_t vmu, amu;

    AVCodecContext *vctx;
    AVFrame *vframe;
    AVPacket *vpkt;
    struct SwsContext *sws;
    uint8_t *frame;
    int fw, fh, fcap;
    unsigned serial;

    AVCodecContext *actx;
    AVFrame *aframe;
    AVPacket *apkt;
    SwrContext *swr;
    int swr_rate, swr_fmt, swr_ch;
    int audio_is_aac;
    float *conv;
    int conv_cap;
    float *ring;                /* interleaved stereo */
    int rhead, rlen, primed;

    int vframes, aframes, errors;
};

static void free_decoders(rp_player *p) {
    avcodec_free_context(&p->vctx);
    avcodec_free_context(&p->actx);
    if (p->sws) { sws_freeContext(p->sws); p->sws = NULL; }
    swr_free(&p->swr);
    p->swr_rate = p->swr_fmt = p->swr_ch = 0;
}

static void on_session(void *ctx, const premo_info *info) {
    rp_player *p = ctx;
    const AVCodec *vc, *ac;
    int ch = info->audio_channels > 0 && info->audio_channels <= 2 ? info->audio_channels : 2;
    int rate = info->audio_rate > 0 ? info->audio_rate : 48000;

    free_decoders(p);

    vc = avcodec_find_decoder(strcasecmp(info->video_codec, "M4V") == 0 ? AV_CODEC_ID_MPEG4 : AV_CODEC_ID_H264);
    if (vc && (p->vctx = avcodec_alloc_context3(vc))) {
        p->vctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        p->vctx->thread_count = 1;
        if (avcodec_open2(p->vctx, vc, NULL) < 0) avcodec_free_context(&p->vctx);
    }

    p->audio_is_aac = strcasecmp(info->audio_codec, "AT3") != 0;
    ac = avcodec_find_decoder(p->audio_is_aac ? AV_CODEC_ID_AAC : AV_CODEC_ID_ATRAC3);
    if (ac && (p->actx = avcodec_alloc_context3(ac))) {
        static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000};
        uint8_t *ed = av_mallocz(16 + AV_INPUT_BUFFER_PADDING_SIZE);
        p->actx->sample_rate = rate;
        av_channel_layout_default(&p->actx->ch_layout, ch);
        if (ed && p->audio_is_aac) {
            int idx = 3;
            for (int i = 0; i < 12; i++) if (rates[i] == rate) idx = i;
            ed[0] = (uint8_t)((2 << 3) | (idx >> 1));          /* AAC-LC AudioSpecificConfig */
            ed[1] = (uint8_t)(((idx & 1) << 7) | (ch << 3));
            p->actx->extradata = ed;
            p->actx->extradata_size = 2;
        } else if (ed) {
            /* same 14-byte ATRAC3 header the reference client uses */
            static const uint8_t at3[14] = {1, 0, 0, 4, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0};
            memcpy(ed, at3, 14);
            p->actx->extradata = ed;
            p->actx->extradata_size = 14;
            p->actx->block_align = 192 * ch;
            p->actx->bit_rate = info->audio_bitrate > 0 ? info->audio_bitrate : 128000;
        }
        if (avcodec_open2(p->actx, ac, NULL) < 0) avcodec_free_context(&p->actx);
    }

    pthread_mutex_lock(&p->amu);
    p->rhead = p->rlen = p->primed = 0;
    pthread_mutex_unlock(&p->amu);
}

static void present(rp_player *p, AVFrame *f) {
    int w = f->width, h = f->height;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return;
    p->sws = sws_getCachedContext(p->sws, w, h, (enum AVPixelFormat)f->format, w, h, AV_PIX_FMT_BGRA,
                                  SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!p->sws) return;
    pthread_mutex_lock(&p->vmu);
    if (p->fcap < w * h * 4) {
        uint8_t *nb = realloc(p->frame, (size_t)w * h * 4);
        if (nb) { p->frame = nb; p->fcap = w * h * 4; }
    }
    if (p->fcap >= w * h * 4) {
        uint8_t *dst[4] = {p->frame, NULL, NULL, NULL};
        int stride[4] = {w * 4, 0, 0, 0};
        sws_scale(p->sws, (const uint8_t *const *)f->data, f->linesize, 0, h, dst, stride);
        p->fw = w;
        p->fh = h;
        p->serial++;
        p->vframes++;
    }
    pthread_mutex_unlock(&p->vmu);
}

static void push_audio(rp_player *p, AVFrame *f) {
    int ch = f->ch_layout.nb_channels;
    if (ch <= 0 || f->nb_samples <= 0) return;
    if (!p->swr || p->swr_rate != f->sample_rate || p->swr_fmt != f->format || p->swr_ch != ch) {
        AVChannelLayout out;
        av_channel_layout_default(&out, 2);
        swr_free(&p->swr);
        if (swr_alloc_set_opts2(&p->swr, &out, AV_SAMPLE_FMT_FLT, RP_AUDIO_RATE, &f->ch_layout,
                                (enum AVSampleFormat)f->format, f->sample_rate, 0, NULL) < 0 || swr_init(p->swr) < 0) {
            swr_free(&p->swr);
            return;
        }
        p->swr_rate = f->sample_rate; p->swr_fmt = f->format; p->swr_ch = ch;
    }
    int max = swr_get_out_samples(p->swr, f->nb_samples);
    if (max <= 0) return;
    if (p->conv_cap < max) {
        float *nb = realloc(p->conv, sizeof(float) * 2 * (size_t)max);
        if (!nb) return;
        p->conv = nb;
        p->conv_cap = max;
    }
    uint8_t *out[1] = {(uint8_t *)p->conv};
    int n = swr_convert(p->swr, out, max, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n <= 0) return;

    pthread_mutex_lock(&p->amu);
    if (n > RING_FRAMES) n = RING_FRAMES;
    if (p->rlen + n > RING_FRAMES) {                       /* overflow: drop oldest */
        int drop = p->rlen + n - RING_FRAMES;
        p->rhead = (p->rhead + drop) % RING_FRAMES;
        p->rlen -= drop;
    }
    for (int i = 0; i < n; i++) {
        int w = (p->rhead + p->rlen + i) % RING_FRAMES;
        p->ring[w * 2] = p->conv[i * 2];
        p->ring[w * 2 + 1] = p->conv[i * 2 + 1];
    }
    p->rlen += n;
    if (p->rlen > RING_HIGH) {                             /* fell behind: jump forward */
        int drop = p->rlen - RING_KEEP;
        p->rhead = (p->rhead + drop) % RING_FRAMES;
        p->rlen -= drop;
    }
    p->aframes++;
    pthread_mutex_unlock(&p->amu);
}

static void on_packet(void *ctx, int kind, uint8_t magic, uint32_t clock, const uint8_t *data, int len) {
    rp_player *p = ctx;
    (void)magic; (void)clock;
    if (kind == PREMO_VIDEO) {
        if (!p->vctx || len <= 0) return;
        av_packet_unref(p->vpkt);
        if (av_new_packet(p->vpkt, len) < 0) return;
        memcpy(p->vpkt->data, data, (size_t)len);
        if (avcodec_send_packet(p->vctx, p->vpkt) < 0) { p->errors++; return; }
        while (avcodec_receive_frame(p->vctx, p->vframe) == 0) present(p, p->vframe);
    } else {
        if (!p->actx) return;
        if (p->audio_is_aac && len > 7 && data[0] == 0xFF && (data[1] & 0xF6) == 0xF0) {   /* ADTS header */
            int hl = (data[1] & 1) ? 7 : 9;
            data += hl;
            len -= hl;
        }
        if (len <= 0) return;
        av_packet_unref(p->apkt);
        if (av_new_packet(p->apkt, len) < 0) return;
        memcpy(p->apkt->data, data, (size_t)len);
        if (avcodec_send_packet(p->actx, p->apkt) < 0) { p->errors++; return; }
        while (avcodec_receive_frame(p->actx, p->aframe) == 0) push_audio(p, p->aframe);
    }
}

rp_player *rp_start(const char *host, const char *psp_id_hex, const char *pkey_hex, const char *mac_hex,
                    const char *nickname, int bitrate) {
    premo_config cfg;
    premo_sink sink;
    rp_player *p;
    memset(&cfg, 0, sizeof cfg);
    if (!host || !host[0] || strlen(host) >= sizeof cfg.host) return NULL;
    if (premo_hex(psp_id_hex, cfg.psp_id, 16) || premo_hex(pkey_hex, cfg.pkey, 16) || premo_hex(mac_hex, cfg.psp_mac, 6))
        return NULL;
    strcpy(cfg.host, host);
    if (nickname) strncpy(cfg.nickname, nickname, sizeof cfg.nickname - 1);
    cfg.bitrate = bitrate;

    p = calloc(1, sizeof *p);
    if (!p) return NULL;
    pthread_mutex_init(&p->vmu, NULL);
    pthread_mutex_init(&p->amu, NULL);
    p->vframe = av_frame_alloc();
    p->aframe = av_frame_alloc();
    p->vpkt = av_packet_alloc();
    p->apkt = av_packet_alloc();
    p->ring = calloc((size_t)RING_FRAMES * 2, sizeof(float));
    sink.ctx = p;
    sink.on_session = on_session;
    sink.on_packet = on_packet;
    if (p->vframe && p->aframe && p->vpkt && p->apkt && p->ring) p->premo = premo_start(&cfg, &sink);
    if (!p->premo) { rp_stop(p); return NULL; }
    return p;
}

void rp_stop(rp_player *p) {
    if (!p) return;
    premo_stop(p->premo);
    free_decoders(p);
    av_frame_free(&p->vframe);
    av_frame_free(&p->aframe);
    av_packet_free(&p->vpkt);
    av_packet_free(&p->apkt);
    free(p->frame);
    free(p->conv);
    free(p->ring);
    pthread_mutex_destroy(&p->vmu);
    pthread_mutex_destroy(&p->amu);
    free(p);
}

int rp_state(rp_player *p) { return p ? premo_state(p->premo) : PREMO_IDLE; }

void rp_status(rp_player *p, char *out, int cap) {
    if (cap > 0) out[0] = 0;
    if (p) premo_status(p->premo, out, cap);
}

int rp_video_copy(rp_player *p, uint8_t *dst, int cap, int *width, int *height, unsigned *serial) {
    int copied = 0;
    if (!p) return 0;
    pthread_mutex_lock(&p->vmu);
    if (p->frame && p->serial != *serial && p->fw * p->fh * 4 <= cap) {
        memcpy(dst, p->frame, (size_t)p->fw * p->fh * 4);
        *width = p->fw;
        *height = p->fh;
        *serial = p->serial;
        copied = 1;
    }
    pthread_mutex_unlock(&p->vmu);
    return copied;
}

void rp_audio_read(rp_player *p, float *left, float *right, int frames) {
    int n = 0;
    if (p) {
        pthread_mutex_lock(&p->amu);
        if (!p->primed && p->rlen >= RING_PRIME) p->primed = 1;
        if (p->primed) {
            n = p->rlen < frames ? p->rlen : frames;
            for (int i = 0; i < n; i++) {
                int r = (p->rhead + i) % RING_FRAMES;
                left[i] = p->ring[r * 2];
                right[i] = p->ring[r * 2 + 1];
            }
            p->rhead = (p->rhead + n) % RING_FRAMES;
            p->rlen -= n;
            if (n < frames) p->primed = 0;                 /* underrun: rebuffer a little */
        }
        pthread_mutex_unlock(&p->amu);
    }
    for (int i = n; i < frames; i++) left[i] = right[i] = 0.0f;
}

void rp_button(rp_player *p, int code, int down) { if (p) premo_button(p->premo, code, down); }
void rp_axis(rp_player *p, int offset, int value) { if (p) premo_axis(p->premo, offset, value); }
void rp_home(rp_player *p) { if (p) premo_home(p->premo); }

void rp_stats(rp_player *p, int *video_frames, int *audio_frames, int *decode_errors) {
    if (!p) return;
    if (video_frames) *video_frames = p->vframes;
    if (audio_frames) *audio_frames = p->aframes;
    if (decode_errors) *decode_errors = p->errors;
}
