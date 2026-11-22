/* JNI bridge: Kotlin <-> rp_player (PREMO session + FFmpeg decoding) */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "rp_player.h"

#define FN(n) Java_com_cruyfford_ps3hub_RP_##n
#define P(h) ((rp_player *)(intptr_t)(h))

static const char *S(JNIEnv *e, jstring s) { return s ? (*e)->GetStringUTFChars(e, s, NULL) : ""; }
static void R(JNIEnv *e, jstring s, const char *c) { if (s) (*e)->ReleaseStringUTFChars(e, s, c); }

JNIEXPORT jlong JNICALL FN(start)(JNIEnv *e, jclass c, jstring host, jstring id, jstring key, jstring mac, jstring nick, jint bitrate)
{
    (void)c;
    const char *h = S(e, host), *i = S(e, id), *k = S(e, key), *m = S(e, mac), *n = S(e, nick);
    rp_player *p = rp_start(h, i, k, m, n, bitrate);
    R(e, host, h); R(e, id, i); R(e, key, k); R(e, mac, m); R(e, nick, n);
    return (jlong)(intptr_t)p;
}

JNIEXPORT void JNICALL FN(stop)(JNIEnv *e, jclass c, jlong h) { (void)e; (void)c; rp_stop(P(h)); }
JNIEXPORT jint JNICALL FN(state)(JNIEnv *e, jclass c, jlong h) { (void)e; (void)c; return rp_state(P(h)); }

JNIEXPORT jstring JNICALL FN(status)(JNIEnv *e, jclass c, jlong h)
{
    (void)c;
    char b[512] = "";
    rp_status(P(h), b, sizeof(b));
    return (*e)->NewStringUTF(e, b);
}

/* info = {width, height, serial}; returns 1 when a new frame was copied into the direct buffer */
JNIEXPORT jint JNICALL FN(video)(JNIEnv *e, jclass c, jlong h, jobject buf, jintArray info)
{
    (void)c;
    uint8_t *dst = (*e)->GetDirectBufferAddress(e, buf);
    jlong cap = (*e)->GetDirectBufferCapacity(e, buf);
    if (!dst || cap <= 0) return 0;
    jint v[3];
    (*e)->GetIntArrayRegion(e, info, 0, 3, v);
    int w = v[0], hh = v[1];
    unsigned serial = (unsigned)v[2];
    int r = rp_video_copy(P(h), dst, (int)cap, &w, &hh, &serial);
    if (r) { v[0] = w; v[1] = hh; v[2] = (jint)serial; (*e)->SetIntArrayRegion(e, info, 0, 3, v); }
    return r;
}

/* interleaved stereo floats, frames per channel */
JNIEXPORT void JNICALL FN(audio)(JNIEnv *e, jclass c, jlong h, jfloatArray out, jint frames)
{
    (void)c;
    static float *l, *r, *x; static int cap;
    if (frames > cap) { free(l); free(r); free(x); l = malloc(frames * 4); r = malloc(frames * 4); x = malloc(frames * 8); cap = frames; }
    if (!l || !r || !x) { cap = 0; return; }
    rp_audio_read(P(h), l, r, frames);
    for (int i = 0; i < frames; i++) { x[2 * i] = l[i]; x[2 * i + 1] = r[i]; }
    (*e)->SetFloatArrayRegion(e, out, 0, frames * 2, x);
}

JNIEXPORT void JNICALL FN(button)(JNIEnv *e, jclass c, jlong h, jint code, jboolean down) { (void)e; (void)c; rp_button(P(h), code, down); }
JNIEXPORT void JNICALL FN(axis)(JNIEnv *e, jclass c, jlong h, jint off, jint v) { (void)e; (void)c; rp_axis(P(h), off, v); }
JNIEXPORT void JNICALL FN(home)(JNIEnv *e, jclass c, jlong h) { (void)e; (void)c; rp_home(P(h)); }
