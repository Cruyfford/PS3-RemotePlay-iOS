#!/bin/bash
# Self-test: builds the C core, runs it against the mock PS3 and checks the decrypted streams.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"
cd "$W"
python3 -m pip install --quiet --user --break-system-packages pycryptodome 2>/dev/null || python3 -m pip install --quiet --user pycryptodome
cc -O2 -Wall -pthread -I"$ROOT/Core" -o premo_cli "$ROOT/tools/test/premo_cli.c" "$ROOT/Core/premo.c"
python3 - <<'PY'
import os
# tiny synthetic "streams": the mock only frames and encrypts them, so any bytes with start codes work
v = b"".join(b"\0\0\0\1" + bytes([0x65 if i % 5 == 0 else 0x41]) + os.urandom(700 + i * 13) for i in range(40))
a = b"".join(bytes([0xFF, 0xF1, 0x4C, 0x80 | ((n + 7) >> 11), ((n + 7) >> 3) & 0xFF, (((n + 7) & 7) << 5) | 0x1F, 0xFC]) + os.urandom(n)
             for n in [200 + (i * 7) % 90 for i in range(60)])
open("src.h264", "wb").write(v); open("src.aac", "wb").write(a)
PY
python3 "$ROOT/tools/test/make_xreg.py" xRegistry.sys
python3 "$ROOT/tools/ps3rp.py" register xRegistry.sys > /dev/null
python3 "$ROOT/tools/test/mock_ps3.py" xRegistry_new.sys src.h264 src.aac mock.log &
MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
sleep 1
KEYS=$(python3 -c "import json; c=json.load(open('ps3rp.json')); print(c['psp_id'], c['pkey'], c['psp_mac'])")
./premo_cli 127.0.0.1 $KEYS 6
python3 "$ROOT/tools/ps3rp.py" test 127.0.0.1 --seconds 4 --pad | tail -5
python3 - <<'PY'
v = open("src.h264", "rb").read(); a = open("src.aac", "rb").read()
raw = b""; p = 0
while p + 7 <= len(a):
    n = ((a[p + 3] & 3) << 11) | (a[p + 4] << 3) | (a[p + 5] >> 5); raw += a[p + 7:p + n]; p += n
cv = open("c_video.bin", "rb").read(); ca = open("c_audio.bin", "rb").read()
assert cv == v, "C core: video mismatch (%d vs %d bytes)" % (len(cv), len(v))
assert ca == raw, "C core: audio mismatch"
assert open("rp_video.h264", "rb").read() == v, "python tool: video mismatch"
log = open("mock.log").read()
assert log.count("AUTH OK") == 4 and "PAD id=1" in log, log
print("SELF-TEST PASS: C core and Python tool decrypt both streams byte-exactly; auth and pad accepted")
PY
