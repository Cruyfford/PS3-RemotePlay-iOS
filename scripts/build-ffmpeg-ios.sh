#!/bin/bash
# Builds a decoder-only FFmpeg (H.264, MPEG-4, AAC, ATRAC3) as static libraries for iOS arm64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ffmpeg-ios"
SRC="$ROOT/build/ffmpeg-src"
VER="n6.1.1"

if [ -f "$OUT/lib/libavcodec.a" ] && [ -f "$OUT/lib/libswresample.a" ]; then
  echo "FFmpeg already built at $OUT"
  exit 0
fi

mkdir -p "$ROOT/build"
rm -rf "$SRC" "$OUT"
git clone --quiet --depth 1 --branch "$VER" https://github.com/FFmpeg/FFmpeg.git "$SRC"
cd "$SRC"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0"

if ! ./configure --prefix="$OUT" \
    --enable-cross-compile --target-os=darwin --arch=arm64 --cc="$CC" \
    --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS" \
    --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-postproc \
    --enable-swscale --enable-swresample \
    --enable-decoder=h264,mpeg4,aac,atrac3 \
    --disable-asm --enable-pic --enable-static --disable-shared --disable-debug \
    > "$ROOT/build/ffmpeg-configure.log" 2>&1; then
  tail -40 "$ROOT/build/ffmpeg-configure.log"
  tail -40 ffbuild/config.log || true
  exit 1
fi

if ! make -j"$(sysctl -n hw.ncpu)" > "$ROOT/build/ffmpeg-make.log" 2>&1; then
  tail -60 "$ROOT/build/ffmpeg-make.log"
  exit 1
fi
make install > /dev/null
rm -rf "$SRC"
ls -la "$OUT/lib"
