#!/usr/bin/env python3
"""Mock PS3 PREMO server for testing ps3rp.py. Uses pycryptodome as an independent AES."""
import base64, os, socket, struct, sys, threading, time
from Crypto.Cipher import AES

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ps3rp

PORT = 9293
reg = ps3rp.XReg(open(sys.argv[1], "rb").read())
slots = [ps3rp.slot_info(reg.slot(n)) for n in range(1, 9)]
VIDEO = open(sys.argv[2], "rb").read()      # Annex-B H.264
AUDIO = open(sys.argv[3], "rb").read()      # ADTS AAC
NONCE = os.urandom(16)
VCODEC = os.environ.get('MOCK_VCODEC', 'AVC')
STALL = float(os.environ.get('MOCK_STALL', '0.033'))
LOG = open(sys.argv[4], "w") if len(sys.argv) > 4 else sys.stderr
def log(*a): print(*a, file=LOG, flush=True)

def access_units(es):
    """split an Annex-B H.264 stream into access units: (is_key, bytes)"""
    pos = []; i = es.find(b"\0\0\1")
    while i >= 0:
        pos.append(i - 1 if i > 0 and es[i - 1] == 0 else i); i = es.find(b"\0\0\1", i + 3)
    pos.append(len(es))
    units = []; cur = b""; key = False
    for a, b in zip(pos, pos[1:]):
        nal = es[a:b]; t = nal[4 if nal[2] == 0 else 3] & 0x1F
        cur += nal
        if t == 5: key = True
        if t in (1, 5): units.append((key, cur)); cur = b""; key = False
    return units

def m4v_units(es):
    """split an MPEG-4 Part 2 elementary stream into one packet per VOP (headers stay with the next VOP)"""
    pos = []; i = es.find(b"\0\0\1")
    while i >= 0:
        pos.append(i); i = es.find(b"\0\0\1", i + 3)
    units = []; start = 0; has_vop = False
    for p in pos:
        if has_vop: units.append((True, es[start:p])); start = p; has_vop = False
        if es[p + 3] == 0xB6: has_vop = True
    units.append((True, es[start:]))
    return units

def adts_frames(es):
    out = []; p = 0
    while p + 7 <= len(es):
        n = ((es[p + 3] & 3) << 11) | (es[p + 4] << 3) | (es[p + 5] >> 5)
        out.append(es[p + 7:p + n]); p += n
    return out

def packet(magic, frame, clock, payload, encrypted, key, iv, video):
    if encrypted:
        n = len(payload) - len(payload) % 16
        payload = AES.new(key, AES.MODE_CBC, iv).encrypt(payload[:n]) + payload[n:]
    h = bytearray(32); h[0] = 0x80; h[1] = magic
    struct.pack_into(">HI", h, 2, frame & 0xFFFF, clock)
    struct.pack_into(">H", h, 16, len(payload))
    if encrypted and video: h[22:24] = b"\x01\x04"
    if encrypted and not video: h[26:28] = b"\x00\x01"
    body = bytes(h) + payload
    return b"%06x\r\n" % len(body) + body + b"\r\n"

def handle(c):
    buf = b""
    try:
        while True:
            while b"\r\n\r\n" not in buf:
                d = c.recv(65536)
                if not d: return
                buf += d
            head, buf = buf.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            method, path = lines[0].split()[:2]
            hd = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
            log("REQ", method, path)
            if path == "/sce/premo/session":
                pid = base64.b64decode(hd.get("premo-pspid", "")).hex()
                me = next((s for s in slots if s and s["psp_id"] == pid and ps3rp.slot_used(s)), None)
                if not me:
                    c.sendall(b"HTTP/1.1 403 Forbidden\r\nPREMO-Application-Reason: 80029820\r\nContent-Length: 0\r\n\r\n")
                    log("REJECT unknown pspid"); continue
                handle.me = me
                c.sendall(("HTTP/1.1 200 OK\r\nSessionID: 0123456789abcdef\r\nPREMO-Nonce: %s\r\n"
                           "PREMO-Exec-Mode: VSH\r\nPREMO-Video-Codec: VCODEC_HERE\r\nPREMO-Video-Resolution: 480x272\r\n"
                           "PREMO-Video-Framerate: 30\r\nPREMO-Video-ClockFrequency: 90000\r\n"
                           "PREMO-Audio-Codec: M4A\r\nPREMO-Audio-SamplingRate: 48000\r\nPREMO-Audio-Channels: 2\r\n"
                           "PREMO-Audio-Bitrate: 128000\r\nPREMO-Audio-ClockFrequency: 90000\r\n"
                           "PREMO-PS3-Nickname: %s\r\nContent-Length: 0\r\n\r\n" % (
                               base64.b64encode(NONCE).decode(), base64.b64encode(b"MockPS3").decode())).replace("VCODEC_HERE", VCODEC).encode())
            elif path == "/sce/premo/session/ctrl":
                log("CTRL", hd.get("mode"), hd.get("bitrate"))
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            elif path in ("/sce/premo/session/video", "/sce/premo/session/audio"):
                me = handle.me
                key = ps3rp.xor(bytes.fromhex(me["pkey"]), ps3rp.SKEY0); iv = ps3rp.xor(NONCE, ps3rp.SKEY2)
                want = base64.b64encode(AES.new(key, AES.MODE_CBC, iv).encrypt(
                    bytes.fromhex(me["psp_mac"]) + bytes(10))).decode()
                if hd.get("premo-auth") != want:
                    c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); log("AUTH FAIL", path); continue
                log("AUTH OK", path)
                c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
                if path.endswith("video"):
                    units = m4v_units(VIDEO) if VCODEC == "M4V" else access_units(VIDEO)
                    for i, (k, au) in enumerate(units):
                        c.sendall(packet(0xFB if VCODEC == "M4V" else 0xFF, i, i * 3000, au, (k and VCODEC != "M4V") or i % 3 == 0, key, iv, True))
                        time.sleep(0.033 if i % 30 else STALL)
                else:
                    for i, fr in enumerate(adts_frames(AUDIO)):
                        c.sendall(packet(0x80, i, i * 1920, fr, True, key, iv, False)); time.sleep(0.0205)
                log("STREAM DONE", path)
                time.sleep(30); return
            elif path == "/sce/premo/session/pad":
                n = 0
                while True:
                    while len(buf) < 128:
                        d = c.recv(4096)
                        if not d: return
                        buf += d
                    st, buf = buf[:128], buf[128:]
                    n += 1
                    log("PAD id=%d ts=%d b5=%02x b7=%02x" % (struct.unpack_from(">I", st, 0x48)[0],
                        struct.unpack_from(">I", st, 0x40)[0], st[5], st[7]))
                    if n == 60:
                        c.sendall(b"HTTP/1.1 200 OK\r\n".ljust(78, b" ") + b"\r\n"); break
    except OSError:
        pass
    finally:
        c.close()

def udp():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("0.0.0.0", PORT))
    while True:
        d, peer = u.recvfrom(64)
        if d[:4] == b"SRCH":
            u.sendto(b"RESP" + bytes(6) + bytes.fromhex("001122334455") + b"MockPS3".ljust(128, b"\0") + bytes(12), peer)

threading.Thread(target=udp, daemon=True).start()
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT)); srv.listen(8)
log("mock PS3 listening")
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
