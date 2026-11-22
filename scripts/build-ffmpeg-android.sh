#!/bin/bash
# Decoder-only FFmpeg (H.264, MPEG-4, AAC, ATRAC3) as static libraries for Android arm64-v8a.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ffmpeg-android/arm64-v8a"
SRC="$ROOT/build/ffmpeg-src-android"
VER="n6.1.1"
API=24
if [ -f "$OUT/lib/libavcodec.a" ] && [ -f "$OUT/lib/libswresample.a" ]; then echo "FFmpeg already built"; exit 0; fi
NDK="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}"
[ -d "$NDK" ] || { echo "NDK not found"; exit 1; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
mkdir -p "$ROOT/build"; rm -rf "$SRC" "$OUT"
git clone --quiet --depth 1 --branch "$VER" https://github.com/FFmpeg/FFmpeg.git "$SRC"
cd "$SRC"
if ! ./configure --prefix="$OUT" --enable-cross-compile --target-os=android --arch=aarch64 \
    --cc="$TC/aarch64-linux-android$API-clang" --cxx="$TC/aarch64-linux-android$API-clang++" \
    --ar="$TC/llvm-ar" --nm="$TC/llvm-nm" --ranlib="$TC/llvm-ranlib" --strip="$TC/llvm-strip" \
    --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-postproc \
    --enable-swscale --enable-swresample --enable-decoder=h264,mpeg4,aac,atrac3 \
    --enable-pic --enable-static --disable-shared --disable-debug --disable-vulkan \
    > "$ROOT/build/ffmpeg-android-configure.log" 2>&1; then
  tail -40 "$ROOT/build/ffmpeg-android-configure.log"; tail -40 ffbuild/config.log || true; exit 1
fi
if ! make -j"$(nproc)" > "$ROOT/build/ffmpeg-android-make.log" 2>&1; then tail -60 "$ROOT/build/ffmpeg-android-make.log"; exit 1; fi
make install > /dev/null
rm -rf "$SRC"
ls -la "$OUT/lib"
