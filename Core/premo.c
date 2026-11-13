/*
 * premo - PS3 Remote Play (PREMO) client core.
 * Protocol logic follows Open Remote Play (GPLv2). This file is GPLv2 as well.
 */
#include "premo.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define PREMO_PORT 9293
#define USER_AGENT "premo/1.0.0 libhttp/1.0.0"
#define PAD_LEN 128
#define PAD_MAX 60
#define PAD_QUEUE 64

static const uint8_t SKEY0[16] = {0xD1, 0xB2, 0x12, 0xEB, 0x73, 0x86, 0x6C, 0x7B, 0x12, 0xA7, 0x5E, 0x0C, 0x04, 0xC6, 0xB8, 0x91};
static const uint8_t SKEY2[16] = {0x65, 0x2D, 0x8C, 0x90, 0xDE, 0x87, 0x17, 0xCF, 0x4F, 0xB3, 0xD8, 0xD3, 0x01, 0x79, 0x6B, 0x59};

/* ------------------------------------------------------------------ AES-128 */
static uint8_t SB[256], ISB[256], M2[256], M3[256], M9[256], M11[256], M13[256], M14[256];
static pthread_once_t aes_once = PTHREAD_ONCE_INIT;

static uint8_t gmul(uint8_t a, uint8_t b) {
    uint8_t r = 0;
    while (b) {
        if (b & 1) r ^= a;
        a = (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1B : 0));
        b >>= 1;
    }
    return r;
}

#define ROTL8(x, n) ((uint8_t)(((x) << (n)) | ((x) >> (8 - (n)))))

static void aes_tables(void) {
    uint8_t p = 1, q = 1;
    do {
        p = (uint8_t)(p ^ (p << 1) ^ ((p & 0x80) ? 0x1B : 0));
        q ^= (uint8_t)(q << 1);
        q ^= (uint8_t)(q << 2);
        q ^= (uint8_t)(q << 4);
        if (q & 0x80) q ^= 0x09;
        SB[p] = (uint8_t)(q ^ ROTL8(q, 1) ^ ROTL8(q, 2) ^ ROTL8(q, 3) ^ ROTL8(q, 4) ^ 0x63);
    } while (p != 1);
    SB[0] = 0x63;
    for (int i = 0; i < 256; i++) {
        ISB[SB[i]] = (uint8_t)i;
        M2[i] = gmul((uint8_t)i, 2); M3[i] = gmul((uint8_t)i, 3); M9[i] = gmul((uint8_t)i, 9);
        M11[i] = gmul((uint8_t)i, 11); M13[i] = gmul((uint8_t)i, 13); M14[i] = gmul((uint8_t)i, 14);
    }
}

static void aes_expand(const uint8_t key[16], uint8_t rk[176]) {
    uint8_t rcon = 1;
    memcpy(rk, key, 16);
    for (int i = 16; i < 176; i += 4) {
        uint8_t t[4];
        memcpy(t, rk + i - 4, 4);
        if (i % 16 == 0) {
            uint8_t t0 = t[0];
            t[0] = (uint8_t)(SB[t[1]] ^ rcon); t[1] = SB[t[2]]; t[2] = SB[t[3]]; t[3] = SB[t0];
            rcon = (uint8_t)((rcon << 1) ^ ((rcon & 0x80) ? 0x1B : 0));
        }
        for (int j = 0; j < 4; j++) rk[i + j] = rk[i - 16 + j] ^ t[j];
    }
}

static void aes_enc(const uint8_t rk[176], uint8_t s[16]) {
    uint8_t t[16];
    for (int i = 0; i < 16; i++) s[i] ^= rk[i];
    for (int r = 1; r <= 10; r++) {
        for (int i = 0; i < 16; i++) t[i] = SB[s[(i + 4 * (i % 4)) % 16]];
        if (r < 10) {
            for (int c = 0; c < 16; c += 4) {
                uint8_t a = t[c], b = t[c + 1], d = t[c + 2], e = t[c + 3];
                s[c] = M2[a] ^ M3[b] ^ d ^ e;
                s[c + 1] = a ^ M2[b] ^ M3[d] ^ e;
                s[c + 2] = a ^ b ^ M2[d] ^ M3[e];
                s[c + 3] = M3[a] ^ b ^ d ^ M2[e];
            }
        } else memcpy(s, t, 16);
        for (int i = 0; i < 16; i++) s[i] ^= rk[r * 16 + i];
    }
}

static void aes_dec(const uint8_t rk[176], uint8_t s[16]) {
    uint8_t t[16];
    for (int i = 0; i < 16; i++) s[i] ^= rk[160 + i];
    for (int r = 9; r >= 0; r--) {
        for (int i = 0; i < 16; i++) t[i] = ISB[s[(i + 16 - 4 * (i % 4)) % 16]] ^ rk[r * 16 + i];
        if (r > 0) {
            for (int c = 0; c < 16; c += 4) {
                uint8_t a = t[c], b = t[c + 1], d = t[c + 2], e = t[c + 3];
                s[c] = M14[a] ^ M11[b] ^ M13[d] ^ M9[e];
                s[c + 1] = M9[a] ^ M14[b] ^ M11[d] ^ M13[e];
                s[c + 2] = M13[a] ^ M9[b] ^ M14[d] ^ M11[e];
                s[c + 3] = M11[a] ^ M13[b] ^ M9[d] ^ M14[e];
            }
        } else memcpy(s, t, 16);
    }
}

void premo_aes_cbc(const uint8_t key[16], const uint8_t iv[16], uint8_t *data, int len, int encrypt) {
    uint8_t rk[176], prev[16], cur[16];
    pthread_once(&aes_once, aes_tables);
    aes_expand(key, rk);
    memcpy(prev, iv, 16);
    for (int o = 0; o + 16 <= len; o += 16) {
        if (encrypt) {
            for (int i = 0; i < 16; i++) data[o + i] ^= prev[i];
            aes_enc(rk, data + o);
            memcpy(prev, data + o, 16);
        } else {
            memcpy(cur, data + o, 16);
            aes_dec(rk, data + o);
            for (int i = 0; i < 16; i++) data[o + i] ^= prev[i];
            memcpy(prev, cur, 16);
        }
    }
}

/* ------------------------------------------------------------------ helpers */
int premo_hex(const char *hex, uint8_t *out, int len) {
    int n = 0, hi = -1;
    for (; hex && *hex; hex++) {
        int c = *hex, v;
        if (c == ':' || c == '-' || c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        if (c >= '0' && c <= '9') v = c - '0';
        else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
        else return -1;
        if (hi < 0) hi = v;
        else {
            if (n >= len) return -1;
            out[n++] = (uint8_t)((hi << 4) | v);
            hi = -1;
        }
    }
    return (n == len && hi < 0) ? 0 : -1;
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_enc(const uint8_t *in, int n, char *out) {
    int o = 0;
    for (int i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < n) v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = B64[(v >> 18) & 63];
        out[o++] = B64[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? B64[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? B64[v & 63] : '=';
    }
    out[o] = 0;
}

static int b64_dec(const char *in, uint8_t *out, int cap) {
    int n = 0, bits = 0;
    uint32_t acc = 0;
    for (; *in; in++) {
        const char *p = strchr(B64, *in);
        if (*in == '=' ) break;
        if (!p) continue;
        acc = (acc << 6) | (uint32_t)(p - B64);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n >= cap) return -1;
            out[n++] = (uint8_t)((acc >> bits) & 0xFF);
        }
    }
    return n;
}

/* ------------------------------------------------------------------ sockets */
typedef struct {
    int fd;
    uint8_t *buf;
    int len, cap;
} conn_t;

static void conn_init(conn_t *c) { c->fd = -1; c->buf = NULL; c->len = c->cap = 0; }

static void conn_close(conn_t *c) {
    if (c->fd >= 0) { shutdown(c->fd, SHUT_RDWR); close(c->fd); }
    free(c->buf);
    conn_init(c);
}

static int conn_open(conn_t *c, const char *host, int port, int timeout_ms) {
    struct addrinfo hints, *res = NULL, *ai;
    char svc[16];
    conn_init(c);
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(svc, sizeof svc, "%d", port);
    if (getaddrinfo(host, svc, &hints, &res) != 0) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r != 0 && errno == EINPROGRESS) {
            fd_set ws;
            struct timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
            FD_ZERO(&ws);
            FD_SET(fd, &ws);
            if (select(fd + 1, NULL, &ws, NULL, &tv) == 1) {
                int err = 0;
                socklen_t el = sizeof err;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                r = err ? -1 : 0;
            } else r = -1;
        }
        if (r == 0) {
            int one = 1;
            struct timeval rt = {1, 0}, st = {5, 0};
            fcntl(fd, F_SETFL, fl);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rt, sizeof rt);
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &st, sizeof st);
#ifdef SO_NOSIGPIPE
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
            c->fd = fd;
            break;
        }
        close(fd);
    }
    freeaddrinfo(res);
    return c->fd >= 0 ? 0 : -1;
}

static int conn_send(conn_t *c, const void *data, int n) {
    const uint8_t *d = data;
    while (n > 0) {
        ssize_t r = send(c->fd, d, (size_t)n, MSG_NOSIGNAL);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return -1;
        }
        d += r;
        n -= (int)r;
    }
    return 0;
}

/* 1 = data added, 0 = closed, -1 = error, -2 = timeout */
static int conn_fill(conn_t *c) {
    if (c->cap - c->len < 65536) {
        int ncap = c->cap + 131072;
        uint8_t *nb = realloc(c->buf, (size_t)ncap);
        if (!nb) return -1;
        c->buf = nb;
        c->cap = ncap;
    }
    for (;;) {
        ssize_t r = recv(c->fd, c->buf + c->len, (size_t)(c->cap - c->len), 0);
        if (r > 0) { c->len += (int)r; return 1; }
        if (r == 0) return 0;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT) return -2;
        return -1;
    }
}

static void conn_consume(conn_t *c, int n) {
    if (n > c->len) n = c->len;
    memmove(c->buf, c->buf + n, (size_t)(c->len - n));
    c->len -= n;
}

static int http_request(conn_t *c, const char *method, const char *path, const char *host, int port, const char *extra) {
    char req[2048];
    int n = snprintf(req, sizeof req,
                     "%s %s HTTP/1.1\r\nUser-Agent: " USER_AGENT "\r\nAccept: */*;q=0.01\r\nAccept-Encoding: \r\n"
                     "Accept-Charset: iso-8859-1;q=0.01\r\nHost: %s:%d\r\n%sConnection: Keep-Alive\r\n\r\n",
                     method, path, host, port, extra ? extra : "");
    if (n <= 0 || n >= (int)sizeof req) return -1;
    return conn_send(c, req, n);
}

/* reads the response head into hdr (NUL terminated). 1 = ok, otherwise conn_fill codes */
static int http_response(conn_t *c, int *code, char *hdr, int cap, volatile int *stop, int wait_s) {
    int waited = 0;
    for (;;) {
        for (int i = 0; i + 3 < c->len; i++) {
            if (c->buf[i] == '\r' && c->buf[i + 1] == '\n' && c->buf[i + 2] == '\r' && c->buf[i + 3] == '\n') {
                int n = i < cap - 1 ? i : cap - 1;
                memcpy(hdr, c->buf, (size_t)n);
                hdr[n] = 0;
                conn_consume(c, i + 4);
                *code = 0;
                sscanf(hdr, "HTTP/%*s %d", code);
                return 1;
            }
        }
        if (c->len > 32768) return -1;
        int r = conn_fill(c);
        if (r == -2) {
            if ((stop && *stop) || ++waited >= wait_s) return -2;
            continue;
        }
        if (r != 1) return r;
    }
}

/* copies a header value with all whitespace removed (as the reference client does) */
static int hdr_get(const char *hdr, const char *name, char *out, int cap) {
    size_t nl = strlen(name);
    const char *p = hdr;
    out[0] = 0;
    while (p && *p) {
        const char *e = strstr(p, "\r\n");
        size_t ll = e ? (size_t)(e - p) : strlen(p);
        if (ll > nl && strncasecmp(p, name, nl) == 0) {
            const char *q = p + nl;
            while (q < p + ll && (*q == ' ' || *q == '\t')) q++;
            if (q < p + ll && *q == ':') {
                int o = 0;
                for (q++; q < p + ll; q++)
                    if (*q != ' ' && *q != '\t' && o < cap - 1) out[o++] = *q;
                out[o] = 0;
                return 1;
            }
        }
        p = e ? e + 2 : NULL;
    }
    return 0;
}

/* 1 = a complete chunk is at buf[*off] (length *n); call conn_consume(c, *off + *n) afterwards */
static int conn_chunk(conn_t *c, int *off, int *n) {
    for (;;) {
        int s = 0;
        while (s < c->len && (c->buf[s] == '\r' || c->buf[s] == '\n')) s++;
        if (s) conn_consume(c, s);
        if (c->len >= 8) {
            int sz = 0;
            if (c->buf[6] != '\r' || c->buf[7] != '\n') return -3;
            for (int i = 0; i < 6; i++) {
                int ch = c->buf[i], v;
                if (ch >= '0' && ch <= '9') v = ch - '0';
                else if (ch >= 'a' && ch <= 'f') v = ch - 'a' + 10;
                else if (ch >= 'A' && ch <= 'F') v = ch - 'A' + 10;
                else return -3;
                sz = (sz << 4) | v;
            }
            if (sz == 0) return 0;
            if (sz > 4 * 1024 * 1024) return -3;
            if (c->len >= 8 + sz) { *off = 8; *n = sz; return 1; }
        }
        int r = conn_fill(c);
        if (r != 1) return r;
    }
}

/* ------------------------------------------------------------------ session */
enum { R_FAIL = 0, R_STOP, R_RESTORE, R_POWEROFF };

struct premo {
    premo_config cfg;
    premo_sink sink;
    pthread_t th;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    volatile int stop, state;
    char status[256];

    char sid[128], auth[64];
    uint8_t key[16], iv[16];
    premo_info info;
    volatile int sess_stop, restore, poweroff, video_fail;
    char video_err[96], audio_err[96];

    uint8_t pad[PAD_LEN];
    uint8_t q[PAD_QUEUE][PAD_LEN];
    uint8_t q_home[PAD_QUEUE];
    int q_head, q_len;
    uint32_t pad_id;
    int pad_count;
    struct timeval t0;
};

typedef struct { premo_t *p; int kind; } stream_arg;

static void set_status(premo_t *p, int state, const char *fmt, ...) {
    va_list ap;
    pthread_mutex_lock(&p->mu);
    if (state >= 0) p->state = state;
    va_start(ap, fmt);
    vsnprintf(p->status, sizeof p->status, fmt, ap);
    va_end(ap);
    pthread_mutex_unlock(&p->mu);
}

static void pad_reset(uint8_t *s, int home) {
    memset(s, 0, PAD_LEN);
    s[3] = 0x74;
    s[9] = s[11] = s[13] = s[15] = 0x80;
    s[0x51] = 0x01;
    if (home) s[1] = 0x01;
    else s[0x28] = s[0x2a] = s[0x2c] = s[0x2e] = 0x02;
}

static void pad_push(premo_t *p, const uint8_t *state, int home) {
    /* caller holds p->mu */
    int idx;
    if (p->q_len == PAD_QUEUE) idx = (p->q_head + p->q_len - 1) % PAD_QUEUE; /* overwrite newest */
    else idx = (p->q_head + p->q_len++) % PAD_QUEUE;
    memcpy(p->q[idx], state, PAD_LEN);
    p->q_home[idx] = (uint8_t)home;
    pthread_cond_signal(&p->cv);
}

void premo_button(premo_t *p, int code, int down) {
    int off = (code >> 8) & 0x7F;
    uint8_t mask = (uint8_t)(code & 0xFF);
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    uint8_t before = p->pad[off];
    if (down) p->pad[off] |= mask;
    else p->pad[off] &= (uint8_t)~mask;
    if (p->pad[off] != before) pad_push(p, p->pad, 0);
    pthread_mutex_unlock(&p->mu);
}

void premo_axis(premo_t *p, int offset, int value) {
    if (!p || offset < 0x08 || offset > 0x0e) return;
    if (value < 0) value = 0;
    if (value > 255) value = 255;
    pthread_mutex_lock(&p->mu);
    if (p->pad[offset + 1] != (uint8_t)value) {
        p->pad[offset] = 0;
        p->pad[offset + 1] = (uint8_t)value;
        pad_push(p, p->pad, 0);
    }
    pthread_mutex_unlock(&p->mu);
}

void premo_home(premo_t *p) {
    uint8_t s[PAD_LEN];
    if (!p) return;
    pad_reset(s, 1);
    pthread_mutex_lock(&p->mu);
    pad_push(p, s, 1);
    pthread_mutex_unlock(&p->mu);
}

static int pad_post(premo_t *p, conn_t *c) {
    char extra[256];
    snprintf(extra, sizeof extra, "PREMO-Pad-Index: 1\r\nSessionID: %s\r\nContent-Length: %d\r\n", p->sid, PAD_MAX * PAD_LEN);
    return http_request(c, "POST", "/sce/premo/session/pad", p->cfg.host, p->cfg.port, extra);
}

static int pad_send(premo_t *p, conn_t *c, uint8_t *s, int home) {
    if (!home) {
        struct timeval now;
        gettimeofday(&now, NULL);
        uint32_t ms = (uint32_t)((now.tv_sec - p->t0.tv_sec) * 1000 + (now.tv_usec - p->t0.tv_usec) / 1000);
        uint32_t ts = ms / 16, id = ++p->pad_id;
        s[0x40] = (uint8_t)(ts >> 24); s[0x41] = (uint8_t)(ts >> 16); s[0x42] = (uint8_t)(ts >> 8); s[0x43] = (uint8_t)ts;
        s[0x48] = (uint8_t)(id >> 24); s[0x49] = (uint8_t)(id >> 16); s[0x4a] = (uint8_t)(id >> 8); s[0x4b] = (uint8_t)id;
    }
    if (conn_send(c, s, PAD_LEN) != 0) return -1;
    if (++p->pad_count == PAD_MAX) {
        char hdr[1024];
        int code;
        p->pad_count = 0;
        http_response(c, &code, hdr, sizeof hdr, &p->sess_stop, 3);
        c->len = 0;
        if (pad_post(p, c) != 0) return -1;
    }
    return 0;
}

static void *stream_main(void *arg) {
    stream_arg *a = arg;
    premo_t *p = a->p;
    int kind = a->kind;
    conn_t c;
    char extra[512], hdr[4096];
    int code = 0, idle = 0;
    const char *err = NULL;
    free(a);

    if (conn_open(&c, p->cfg.host, p->cfg.port, 8000) != 0) { err = "cannot open stream connection"; goto done; }
    if (kind == PREMO_VIDEO)
        snprintf(extra, sizeof extra, "PREMO-Video-Codec: %s\r\nPREMO-Video-Resolution: 480x272\r\nPREMO-Auth: %s\r\nSessionID: %s\r\n",
                 p->info.video_codec, p->auth, p->sid);
    else
        snprintf(extra, sizeof extra, "PREMO-Audio-Codec: %s\r\nPREMO-Audio-Bitrate: 128000\r\nPREMO-Auth: %s\r\nSessionID: %s\r\n",
                 p->info.audio_codec, p->auth, p->sid);
    if (http_request(&c, "GET", kind == PREMO_VIDEO ? "/sce/premo/session/video" : "/sce/premo/session/audio",
                     p->cfg.host, p->cfg.port, extra) != 0 ||
        http_response(&c, &code, hdr, sizeof hdr, &p->sess_stop, 10) != 1) { err = "no answer on stream connection"; goto done; }
    if (code != 200) { err = "PS3 rejected the stream (wrong key?)"; goto done; }

    while (!p->sess_stop && !p->stop) {
        int off = 0, n = 0;
        int r = conn_chunk(&c, &off, &n);
        if (r == -2) {
            if (++idle >= 20) { err = "stream timed out"; break; }
            continue;
        }
        if (r != 1) { err = r == -3 ? "unexpected stream data" : "stream closed by PS3"; break; }
        idle = 0;
        uint8_t *b = c.buf + off;
        if (n >= 32 && b[0] == 0x80) {
            uint8_t m = b[1];
            if (m == 0xfd) { p->restore = 1; break; }
            if (m == 0x81) { p->poweroff = 1; break; }
            if (m == 0x80 || m == 0xff || m == 0xfe || m == 0xfb || m == 0xfc) {
                int size = (b[16] << 8) | b[17];
                uint32_t clock = ((uint32_t)b[4] << 24) | ((uint32_t)b[5] << 16) | ((uint32_t)b[6] << 8) | b[7];
                uint8_t *data = b + 32;
                int enc;
                if (size <= 0 || size > n - 32) size = n - 32;
                if (m == 0xff || m == 0xfe) enc = b[22] == 0x01 && b[23] == 0x04;
                else if (m == 0xfb) enc = b[22] == 0x01 && (b[23] == 0x00 || b[23] == 0x04);
                else enc = b[26] || b[27];
                if (enc) premo_aes_cbc(p->key, p->iv, data, size - size % 16, 0);
                if (p->sink.on_packet) p->sink.on_packet(p->sink.ctx, kind, m, clock, data, size);
            }
        }
        conn_consume(&c, off + n);
    }
done:
    conn_close(&c);
    pthread_mutex_lock(&p->mu);
    if (err && !p->sess_stop && !p->stop && !p->restore && !p->poweroff) {
        if (kind == PREMO_VIDEO) {
            p->video_fail = 1;
            snprintf(p->video_err, sizeof p->video_err, "%s", err);
        } else {
            snprintf(p->audio_err, sizeof p->audio_err, "%s", err);
        }
    }
    pthread_cond_signal(&p->cv);
    pthread_mutex_unlock(&p->mu);
    return NULL;
}

static int session_run(premo_t *p) {
    conn_t s, ctrl, pad;
    char hdr[4096], extra[1024], tmp[256], b64id[64], b64name[128];
    uint8_t nonce[32], block[16];
    int code = 0, result = R_FAIL, tv_ok = 0, ta_ok = 0;
    pthread_t tv, ta;
    const char *host = p->cfg.host;
    int port = p->cfg.port;

    conn_init(&s); conn_init(&ctrl); conn_init(&pad);
    p->sess_stop = p->restore = p->poweroff = p->video_fail = 0;
    p->pad_count = 0;
    p->video_err[0] = p->audio_err[0] = 0;

    set_status(p, PREMO_CONNECTING, "Connecting to %s ...", host);
    if (conn_open(&s, host, port, 8000) != 0) {
        set_status(p, -1, "Cannot reach the PS3 at %s:%d. Open Network > Remote Play on the PS3 and check the IP.", host, port);
        goto out;
    }
    b64_enc(p->cfg.psp_id, 16, b64id);
    b64_enc((const uint8_t *)p->cfg.nickname, (int)strlen(p->cfg.nickname), b64name);
    snprintf(extra, sizeof extra,
             "PREMO-PSPID: %s\r\nPREMO-Version: 0.3\r\nPREMO-Mode: PREMO\r\nPREMO-Platform-Info: PSP\r\n"
             "PREMO-Pad-Info: PSP-Pad\r\nPREMO-UserName: %s\r\nPREMO-Trans: capable\r\n", b64id, b64name);
    if (http_request(&s, "GET", "/sce/premo/session", host, port, extra) != 0 ||
        http_response(&s, &code, hdr, sizeof hdr, &p->stop, 10) != 1) {
        set_status(p, -1, "The PS3 did not answer. Is it on the Remote Play waiting screen?");
        goto out;
    }
    if (code != 200) {
        hdr_get(hdr, "PREMO-Application-Reason", tmp, sizeof tmp);
        set_status(p, -1, "The PS3 refused the session (HTTP %d, reason %s). Check the registration keys.", code, tmp[0] ? tmp : "?");
        goto out;
    }
    conn_close(&s);

    hdr_get(hdr, "SessionID", p->sid, sizeof p->sid);
    hdr_get(hdr, "PREMO-Nonce", tmp, sizeof tmp);
    if (!p->sid[0] || b64_dec(tmp, nonce, sizeof nonce) != 16) {
        set_status(p, -1, "Unexpected session answer from the PS3.");
        goto out;
    }
    memset(&p->info, 0, sizeof p->info);
    if (!hdr_get(hdr, "PREMO-Video-Codec", p->info.video_codec, sizeof p->info.video_codec)) strcpy(p->info.video_codec, "AVC");
    if (!hdr_get(hdr, "PREMO-Audio-Codec", p->info.audio_codec, sizeof p->info.audio_codec)) strcpy(p->info.audio_codec, "M4A");
    hdr_get(hdr, "PREMO-Exec-Mode", p->info.exec_mode, sizeof p->info.exec_mode);
    p->info.audio_rate = hdr_get(hdr, "PREMO-Audio-SamplingRate", tmp, sizeof tmp) ? atoi(tmp) : 48000;
    p->info.audio_channels = hdr_get(hdr, "PREMO-Audio-Channels", tmp, sizeof tmp) ? atoi(tmp) : 2;
    p->info.audio_bitrate = hdr_get(hdr, "PREMO-Audio-Bitrate", tmp, sizeof tmp) ? atoi(tmp) : 128000;
    p->info.video_fps = hdr_get(hdr, "PREMO-Video-Framerate", tmp, sizeof tmp) ? atoi(tmp) : 30;
    if (hdr_get(hdr, "PREMO-PS3-Nickname", tmp, sizeof tmp)) {
        int n = b64_dec(tmp, (uint8_t *)p->info.ps3_name, (int)sizeof p->info.ps3_name - 1);
        p->info.ps3_name[n > 0 ? n : 0] = 0;
    }

    for (int i = 0; i < 16; i++) { p->key[i] = p->cfg.pkey[i] ^ SKEY0[i]; p->iv[i] = nonce[i] ^ SKEY2[i]; }
    memset(block, 0, sizeof block);
    memcpy(block, p->cfg.psp_mac, 6);
    premo_aes_cbc(p->key, p->iv, block, 16, 1);
    b64_enc(block, 16, p->auth);

    if (conn_open(&ctrl, host, port, 8000) != 0) { set_status(p, -1, "Cannot open the control connection."); goto out; }
    snprintf(extra, sizeof extra, "Mode: change-bitrate\r\nBitrate: %d\r\nMax-Bitrate: 1024000\r\nSessionID: %s\r\n", p->cfg.bitrate, p->sid);
    if (http_request(&ctrl, "GET", "/sce/premo/session/ctrl", host, port, extra) != 0 ||
        http_response(&ctrl, &code, hdr, sizeof hdr, &p->stop, 10) != 1 || code != 200) {
        set_status(p, -1, "The PS3 rejected the control request (HTTP %d).", code);
        goto out;
    }

    if (p->sink.on_session) p->sink.on_session(p->sink.ctx, &p->info);

    {
        stream_arg *av = malloc(sizeof *av), *aa = malloc(sizeof *aa);
        av->p = p; av->kind = PREMO_VIDEO;
        aa->p = p; aa->kind = PREMO_AUDIO;
        tv_ok = pthread_create(&tv, NULL, stream_main, av) == 0;
        usleep(250000);
        ta_ok = pthread_create(&ta, NULL, stream_main, aa) == 0;
    }
    if (conn_open(&pad, host, port, 8000) != 0 || pad_post(p, &pad) != 0) conn_close(&pad);

    set_status(p, PREMO_STREAMING, "Connected to %s (%s / %s)", p->info.ps3_name[0] ? p->info.ps3_name : host,
               p->info.video_codec, p->info.audio_codec);

    for (;;) {
        uint8_t batch[PAD_QUEUE][PAD_LEN];
        uint8_t home[PAD_QUEUE];
        int n = 0;
        pthread_mutex_lock(&p->mu);
        if (!p->stop && !p->restore && !p->poweroff && !p->video_fail && p->q_len == 0) {
            struct timeval now;
            struct timespec until;
            gettimeofday(&now, NULL);
            until.tv_sec = now.tv_sec;
            until.tv_nsec = now.tv_usec * 1000 + 200000000;
            if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&p->cv, &p->mu, &until);
        }
        while (p->q_len > 0) {
            memcpy(batch[n], p->q[p->q_head], PAD_LEN);
            home[n++] = p->q_home[p->q_head];
            p->q_head = (p->q_head + 1) % PAD_QUEUE;
            p->q_len--;
        }
        pthread_mutex_unlock(&p->mu);
        for (int i = 0; i < n && pad.fd >= 0; i++)
            if (pad_send(p, &pad, batch[i], home[i]) != 0) conn_close(&pad);
        if (p->stop) { result = R_STOP; break; }
        if (p->poweroff) { result = R_POWEROFF; break; }
        if (p->restore) { result = R_RESTORE; break; }
        if (p->video_fail) { set_status(p, -1, "Video stream failed: %s", p->video_err); result = R_FAIL; break; }
    }

out:
    p->sess_stop = 1;
    if (tv_ok) pthread_join(tv, NULL);
    if (ta_ok) pthread_join(ta, NULL);
    if (ctrl.fd >= 0 && result != R_RESTORE && p->sid[0]) {
        snprintf(extra, sizeof extra, "Mode: session-term\r\nSessionID: %s\r\n", p->sid);
        if (http_request(&ctrl, "GET", "/sce/premo/session/ctrl", host, port, extra) == 0) {
            volatile int never = 0;
            http_response(&ctrl, &code, hdr, sizeof hdr, &never, 2);
        }
    }
    conn_close(&s); conn_close(&ctrl); conn_close(&pad);
    return result;
}

static void *session_main(void *arg) {
    premo_t *p = arg;
    for (;;) {
        int r = session_run(p);
        if (r == R_RESTORE && !p->stop) {
            set_status(p, PREMO_CONNECTING, "PS3 is switching mode, reconnecting ...");
            usleep(500000);
            continue;
        }
        pthread_mutex_lock(&p->mu);
        if (r == R_STOP) { p->state = PREMO_ENDED; snprintf(p->status, sizeof p->status, "Disconnected"); }
        else if (r == R_POWEROFF) { p->state = PREMO_ENDED; snprintf(p->status, sizeof p->status, "The PS3 was turned off"); }
        else p->state = PREMO_FAILED;
        pthread_mutex_unlock(&p->mu);
        break;
    }
    return NULL;
}

premo_t *premo_start(const premo_config *cfg, const premo_sink *sink) {
    premo_t *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->cfg = *cfg;
    if (sink) p->sink = *sink;
    if (p->cfg.port <= 0) p->cfg.port = PREMO_PORT;
    if (p->cfg.bitrate <= 0) p->cfg.bitrate = 1024000;
    if (!p->cfg.nickname[0]) strcpy(p->cfg.nickname, "iPhone");
    pthread_mutex_init(&p->mu, NULL);
    pthread_cond_init(&p->cv, NULL);
    pad_reset(p->pad, 0);
    gettimeofday(&p->t0, NULL);
    p->state = PREMO_CONNECTING;
    snprintf(p->status, sizeof p->status, "Connecting ...");
    if (pthread_create(&p->th, NULL, session_main, p) != 0) {
        pthread_mutex_destroy(&p->mu);
        pthread_cond_destroy(&p->cv);
        free(p);
        return NULL;
    }
    return p;
}

void premo_stop(premo_t *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->stop = 1;
    pthread_cond_signal(&p->cv);
    pthread_mutex_unlock(&p->mu);
    pthread_join(p->th, NULL);
    pthread_mutex_destroy(&p->mu);
    pthread_cond_destroy(&p->cv);
    free(p);
}

int premo_state(premo_t *p) { return p ? p->state : PREMO_IDLE; }

void premo_status(premo_t *p, char *out, int cap) {
    if (!p || cap <= 0) return;
    pthread_mutex_lock(&p->mu);
    if (p->audio_err[0] && p->state == PREMO_STREAMING) snprintf(out, (size_t)cap, "%s - no audio: %s", p->status, p->audio_err);
    else snprintf(out, (size_t)cap, "%s", p->status);
    pthread_mutex_unlock(&p->mu);
}
