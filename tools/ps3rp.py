#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ps3rp.py - PS3 Remote Play (PREMO) helper.  No dependencies, Python 3.7+.

  python ps3rp.py keys xRegistry.sys          list Remote Play registrations
  python ps3rp.py register xRegistry.sys      add a registration for this client
  python ps3rp.py find                        look for a PS3 on the local network
  python ps3rp.py test <PS3-IP> [--pad]       connect and record a few seconds

The protocol logic follows Open Remote Play (GPLv2, github.com/shoobyban/open-rp),
so this file is distributed under the GPLv2 as well.
"""
import argparse, base64, json, os, secrets, socket, struct, sys, threading, time

PORT = 9293
UA = "premo/1.0.0 libhttp/1.0.0"
SKEY0 = bytes.fromhex("D1B212EB73866C7B12A75E0C04C6B891")
SKEY2 = bytes.fromhex("652D8C90DE8717CF4FB3D8D301796B59")
CONF = "ps3rp.json"

# ----------------------------------------------------------------- AES-128
def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = (p ^ (p << 1) ^ (0x1B if p & 0x80 else 0)) & 0xFF
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xFF
        if q & 0x80: q ^= 0x09
        r = lambda v, n: ((v << n) | (v >> (8 - n))) & 0xFF
        sbox[p] = q ^ r(q, 1) ^ r(q, 2) ^ r(q, 3) ^ r(q, 4) ^ 0x63
        if p == 1: break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox): inv[v] = i
    def mul(a, b):
        r = 0
        while b:
            if b & 1: r ^= a
            a = ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1
            b >>= 1
        return r
    m = {k: [mul(i, k) for i in range(256)] for k in (2, 3, 9, 11, 13, 14)}
    return sbox, inv, m

_S, _SI, _M = _aes_tables()
_SHIFT = [(i + 4 * (i % 4)) % 16 for i in range(16)]
_ISHIFT = [(i - 4 * (i % 4)) % 16 for i in range(16)]

class AES128:
    def __init__(self, key):
        assert len(key) == 16
        w = list(key); rcon = 1
        for i in range(16, 176, 4):
            t = w[i - 4:i]
            if i % 16 == 0:
                t = [_S[t[1]] ^ rcon, _S[t[2]], _S[t[3]], _S[t[0]]]
                rcon = ((rcon << 1) ^ 0x1B) & 0xFF if rcon & 0x80 else rcon << 1
            w += [w[i - 16 + j] ^ t[j] for j in range(4)]
        self.rk = [w[i:i + 16] for i in range(0, 176, 16)]

    def enc_block(self, b):
        s = [x ^ k for x, k in zip(b, self.rk[0])]
        m2, m3 = _M[2], _M[3]
        for rnd in range(1, 11):
            s = [_S[s[j]] for j in _SHIFT]
            if rnd < 10:
                o = []
                for c in range(0, 16, 4):
                    a, b_, c_, d = s[c:c + 4]
                    o += [m2[a] ^ m3[b_] ^ c_ ^ d, a ^ m2[b_] ^ m3[c_] ^ d,
                          a ^ b_ ^ m2[c_] ^ m3[d], m3[a] ^ b_ ^ c_ ^ m2[d]]
                s = o
            s = [x ^ k for x, k in zip(s, self.rk[rnd])]
        return bytes(s)

    def dec_block(self, b):
        s = [x ^ k for x, k in zip(b, self.rk[10])]
        m9, m11, m13, m14 = _M[9], _M[11], _M[13], _M[14]
        for rnd in range(9, -1, -1):
            s = [_SI[s[j]] for j in _ISHIFT]
            s = [x ^ k for x, k in zip(s, self.rk[rnd])]
            if rnd > 0:
                o = []
                for c in range(0, 16, 4):
                    a, b_, c_, d = s[c:c + 4]
                    o += [m14[a] ^ m11[b_] ^ m13[c_] ^ m9[d], m9[a] ^ m14[b_] ^ m11[c_] ^ m13[d],
                          m13[a] ^ m9[b_] ^ m14[c_] ^ m11[d], m11[a] ^ m13[b_] ^ m9[c_] ^ m14[d]]
                s = o
        return bytes(s)

    def cbc_encrypt(self, data, iv):
        out = bytearray(); prev = iv
        for i in range(0, len(data), 16):
            prev = self.enc_block(bytes(x ^ y for x, y in zip(data[i:i + 16], prev)))
            out += prev
        return bytes(out)

    def cbc_decrypt(self, data, iv):
        out = bytearray(); prev = iv
        for i in range(0, len(data), 16):
            blk = data[i:i + 16]
            out += bytes(x ^ y for x, y in zip(self.dec_block(blk), prev))
            prev = blk
        return bytes(out)

def xor(a, b): return bytes(x ^ y for x, y in zip(a, b))

# ------------------------------------------------------------- xRegistry.sys
TERM = b"\xAA\xBB\xCC\xDD\xEE"

class XRegError(Exception): pass

class XReg:
    """Strict parser. Value entries: flags(2) keyOffset(2) unk(2) len(2) type(1) data(len) 00"""
    def __init__(self, buf):
        self.buf = bytes(buf)
        b = self.buf
        if b[0:4] != b"\xBC\xAD\xAD\xBC":
            raise XRegError("not an xRegistry.sys file (bad magic)")
        self.keys = {}
        p = 0x10
        while b[p:p + 5] != TERM:
            if p + 6 > len(b): raise XRegError("key table: no terminator")
            _, ln, _ = struct.unpack_from(">HHB", b, p)
            name = b[p + 5:p + 5 + ln]
            if not name.startswith(b"/") or b[p + 5 + ln] != 0:
                raise XRegError("key table: unexpected entry at 0x%X" % p)
            self.keys[p - 0x10] = name.decode("ascii", "replace")
            p += 6 + ln
        self.vstart = 0xFFF2 if b[0xFFF0:0xFFF2] == b"\x4D\x26" else None
        if self.vstart is None:
            i = b.find(b"\x4D\x26\x00", p)
            if i < 0: raise XRegError("value table not found")
            self.vstart = i + 2
        self.vals = []
        p = self.vstart
        while b[p:p + 5] != TERM:
            if p + 10 > len(b): raise XRegError("value table: no terminator")
            flags, koff, unk, ln, typ = struct.unpack_from(">HHHHB", b, p)
            if p + 10 + ln > len(b) or b[p + 9 + ln] != 0:
                raise XRegError("value table: unexpected entry at 0x%X" % p)
            if flags == 0x7A and koff not in self.keys:
                raise XRegError("value table: entry at 0x%X points to no key" % p)
            self.vals.append([flags, koff, unk, typ, b[p + 9:p + 9 + ln]])
            p += 10 + ln
        self.vend = p
        if self._table() != b[self.vstart:self.vend]:
            raise XRegError("round-trip check failed")

    def _table(self):
        return b"".join(struct.pack(">HHHHB", f, k, u, len(d), t) + d + b"\0"
                        for f, k, u, t, d in self.vals)

    def find(self, name):
        for v in self.vals:
            if v[0] == 0x7A and self.keys.get(v[1]) == name: return v
        return None

    def slot(self, n):
        base = "/setting/premo/psp%02d/" % n
        return {k: self.find(base + k) for k in ("nickname", "macAddress", "id", "keyType", "key")}

    def dump(self):
        tail = self.buf[self.vend + 5:]
        fill = tail[:1] if tail else b"\0"
        body = self._table() + TERM
        room = len(self.buf) - self.vstart
        if len(body) > room: raise XRegError("no room left in registry")
        return self.buf[:self.vstart] + body + fill * (room - len(body))

def slot_info(s):
    if not all(s.values()): return None
    nick = s["nickname"][4].split(b"\0")[0].decode("utf-8", "replace")
    return dict(nickname=nick, psp_mac=s["macAddress"][4].hex(), psp_id=s["id"][4].hex(),
                pkey=s["key"][4].hex(), key_type=s["keyType"][4].hex())

def slot_used(info):
    return bool(info) and any(c != "0" for c in info["psp_id"] + info["pkey"])

def load_reg(path):
    try:
        return XReg(open(path, "rb").read())
    except XRegError as e:
        sys.exit("Could not parse %s: %s\nSend me this message; do not upload the file anywhere "
                 "(it also holds Wi-Fi and PSN settings)." % (path, e))

def save_conf(info, extra=None):
    conf = {}
    if os.path.exists(CONF):
        try: conf = json.load(open(CONF))
        except Exception: conf = {}
    conf.update({k: info[k] for k in ("nickname", "psp_mac", "psp_id", "pkey")})
    conf.update(extra or {})
    json.dump(conf, open(CONF, "w"), indent=1)
    print("Saved client keys to", CONF)

def cmd_keys(a):
    reg = load_reg(a.file)
    rb = reg.find("/setting/premo/remoteBoot")
    print("remoteBoot:", rb[4].hex() if rb else "?")
    found = None
    for n in range(1, 9):
        info = slot_info(reg.slot(n))
        if info is None:
            print("psp%02d: (entries missing)" % n); continue
        used = slot_used(info)
        print("psp%02d: %s  nickname=%r mac=%s keyType=%s (lens: nick=%d mac=%d id=%d key=%d)" % (
            n, "REGISTERED" if used else "empty", info["nickname"], info["psp_mac"], info["key_type"],
            len(reg.slot(n)["nickname"][4]), len(info["psp_mac"]) // 2, len(info["psp_id"]) // 2,
            len(info["pkey"]) // 2))
        if used and (a.slot in (0, n)) and not found: found = info
    if found: save_conf(found)
    else: print("\nNo registered device found. Run:  python ps3rp.py register %s" % a.file)

def cmd_register(a):
    reg = load_reg(a.file)
    n = a.slot
    if not n:
        for i in range(1, 9):
            info = slot_info(reg.slot(i))
            if info is not None and not slot_used(info): n = i; break
    if not n: sys.exit("No empty slot; pass --slot N to overwrite one.")
    s = reg.slot(n)
    if not all(s.values()): sys.exit("psp%02d entries are missing in this registry." % n)
    want = {"macAddress": 6, "id": 16, "key": 16}
    for k, ln in want.items():
        if len(s[k][4]) != ln:
            sys.exit("psp%02d/%s has length %d, expected %d. Stopping without changes; send me the "
                     "output of the 'keys' command." % (n, k, len(s[k][4]), ln))
    mac = bytearray(secrets.token_bytes(6)); mac[0] = (mac[0] & 0xFC) | 0x02
    info = dict(nickname=a.name, psp_mac=bytes(mac).hex(), psp_id=secrets.token_hex(16),
                pkey=secrets.token_hex(16))
    old_nick = s["nickname"][4]
    nick = a.name.encode("utf-8")
    if len(old_nick) > len(nick) + 1: nick = nick.ljust(len(old_nick), b"\0")   # keep fixed-size field
    elif old_nick.endswith(b"\0") or not old_nick: nick += b"\0"
    s["nickname"][4] = nick
    s["macAddress"][4] = bytes.fromhex(info["psp_mac"])
    s["id"][4] = bytes.fromhex(info["psp_id"])
    s["key"][4] = bytes.fromhex(info["pkey"])
    out = reg.dump()
    XReg(out)                                    # must still parse cleanly
    assert len(out) == len(reg.buf)
    bak = a.file + ".backup"
    if not os.path.exists(bak): open(bak, "wb").write(reg.buf)
    new = os.path.join(os.path.dirname(a.file) or ".", "xRegistry_new.sys")
    open(new, "wb").write(out)
    print("Wrote registration into slot psp%02d (keyType left as %s)." % (n, s["keyType"][4].hex()))
    print("New registry :", new, "\nBackup       :", bak)
    save_conf(info)
    print("\nNext: upload %s to /dev_flash2/etc/xRegistry.sys by FTP, then reboot the PS3." % new)

# ------------------------------------------------------------------ network
def cmd_find(a):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(1.0)
    seen = {}
    for _ in range(4):
        try: s.sendto(b"SRCH", (a.addr, PORT))
        except OSError as e: sys.exit("Cannot send search packet: %s" % e)
        try:
            while True:
                d, peer = s.recvfrom(512)
                if d[:4] == b"RESP" and peer[0] not in seen:
                    seen[peer[0]] = (":".join("%02x" % x for x in d[10:16]), d[16:144].split(b"\0")[0].decode("utf-8", "replace"))
        except socket.timeout:
            pass
    for ip, (mac, nick) in seen.items(): print("PS3 %-15s mac=%s name=%s" % (ip, mac, nick))
    if not seen: print("No PS3 answered. Open Network > Remote Play on the PS3 first.")

class Http:
    """Bare HTTP/1.1 exchange on a raw socket (the PS3 uses 6-hex-digit chunk sizes)."""
    def __init__(self, ip, timeout=10):
        self.s = socket.create_connection((ip, PORT), timeout=timeout)
        self.buf = b""
        self.host = "%s:%d" % (ip, PORT)

    def request(self, method, path, headers, extra=b""):
        lines = ["%s %s HTTP/1.1" % (method, path), "User-Agent: " + UA, "Accept: */*;q=0.01",
                 "Accept-Encoding: ", "Accept-Charset: iso-8859-1;q=0.01", "Host: " + self.host]
        lines += ["%s: %s" % kv for kv in headers] + ["Connection: Keep-Alive"]
        self.s.sendall(("\r\n".join(lines) + "\r\n").encode("latin-1") + extra + b"\r\n")

    def _fill(self):
        d = self.s.recv(65536)
        if not d: raise ConnectionError("connection closed by PS3")
        self.buf += d

    def read_exact(self, n):
        while len(self.buf) < n: self._fill()
        d, self.buf = self.buf[:n], self.buf[n:]
        return d

    def response(self):
        while b"\r\n\r\n" not in self.buf: self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        code = int(lines[0].split()[1])
        hd = {}
        for l in lines[1:]:
            if ":" in l:
                k, v = l.split(":", 1); hd[k.strip().lower()] = "".join(v.split())
        return code, hd

    def chunk(self):
        """Return the next complete chunk; a timeout leaves the buffer intact so the call can be retried."""
        while True:
            while self.buf[:1] in (b"\r", b"\n"): self.buf = self.buf[1:]
            if len(self.buf) >= 8:
                if self.buf[6:8] != b"\r\n": raise ValueError("bad chunk header %r" % self.buf[:8])
                n = int(self.buf[:6], 16)
                if len(self.buf) >= 8 + n:
                    d, self.buf = self.buf[8:8 + n], self.buf[8 + n:]
                    return d
            self._fill()

class Session:
    def __init__(self, ip, conf, log=print):
        self.ip, self.conf, self.log = ip, conf, log
        self.psp_id = bytes.fromhex(conf["psp_id"]); self.pkey = bytes.fromhex(conf["pkey"])
        self.psp_mac = bytes.fromhex(conf["psp_mac"].replace(":", ""))
        self.stats = {}; self.stop = False; self.event = None

    def open(self):
        h = Http(self.ip)
        hdr = [("PREMO-PSPID", base64.b64encode(self.psp_id).decode()), ("PREMO-Version", "0.3"),
               ("PREMO-Mode", "PREMO"), ("PREMO-Platform-Info", "PSP"), ("PREMO-Pad-Info", "PSP-Pad"),
               ("PREMO-UserName", base64.b64encode(self.conf.get("nickname", "iPhone").encode()).decode()),
               ("PREMO-Trans", "capable")]
        h.request("GET", "/sce/premo/session", hdr)
        code, self.info = h.response()
        if code != 200:
            raise RuntimeError("PS3 refused the session: HTTP %d, reason=%s" % (
                code, self.info.get("premo-application-reason", "?")))
        self.sid = self.info["sessionid"]
        nonce = base64.b64decode(self.info["premo-nonce"])
        self.key = xor(self.pkey, SKEY0); self.iv = xor(nonce, SKEY2)
        self.aes = AES128(self.key)
        self.auth = base64.b64encode(self.aes.cbc_encrypt(self.psp_mac + bytes(10), self.iv)).decode()
        self.ctrl = Http(self.ip)
        self.ctrl.request("GET", "/sce/premo/session/ctrl", [("Mode", "change-bitrate"),
                          ("Bitrate", "1024000"), ("Max-Bitrate", "1024000"), ("SessionID", self.sid)])
        code, _ = self.ctrl.response()
        if code != 200: raise RuntimeError("control channel refused: HTTP %d" % code)
        return self.info

    def close(self):
        self.stop = True
        try:
            c = Http(self.ip, timeout=3)
            c.request("GET", "/sce/premo/session/ctrl", [("Mode", "session-term"), ("SessionID", self.sid)])
            c.response()
        except Exception:
            pass

    def stream(self, kind, sink):
        """kind: 'video' or 'audio'. sink(magic, header, payload)"""
        st = self.stats.setdefault(kind, dict(packets=0, bytes=0, encrypted=0, bad=0))
        try:
            h = Http(self.ip)
            if kind == "video":
                hdr = [("PREMO-Video-Codec", self.info.get("premo-video-codec", "AVC")),
                       ("PREMO-Video-Resolution", "480x272")]
            else:
                hdr = [("PREMO-Audio-Codec", self.info.get("premo-audio-codec", "M4A")),
                       ("PREMO-Audio-Bitrate", "128000")]
            h.request("GET", "/sce/premo/session/" + kind, hdr + [("PREMO-Auth", self.auth), ("SessionID", self.sid)])
            code, _ = h.response()
            if code != 200:
                st["error"] = "HTTP %d" % code; return
            h.s.settimeout(1)
            idle = 0
            while not self.stop:
                try:
                    c = h.chunk(); idle = 0
                except socket.timeout:
                    idle += 1
                    if idle >= 15: raise
                    continue
                if len(c) < 32 or c[0] != 0x80: st["bad"] += 1; continue
                m = c[1]
                if m == 0xFD: self.event = "restore"; continue
                if m == 0x81: self.event = "power-off"; break
                if m not in (0x80, 0xFF, 0xFE, 0xFB, 0xFC): st["bad"] += 1; continue
                size = struct.unpack_from(">H", c, 16)[0]
                data = c[32:32 + size]
                u6, u8 = c[22:24], c[26:28]
                enc = ((m in (0xFF, 0xFE) and u6 == b"\x01\x04") or (m == 0xFB and u6 in (b"\x01\x00", b"\x01\x04"))
                       or (m in (0x80, 0xFC) and u8 != b"\0\0"))
                if enc:
                    n = len(data) - len(data) % 16
                    data = self.aes.cbc_decrypt(data[:n], self.iv) + data[n:]
                    st["encrypted"] += 1
                st["packets"] += 1; st["bytes"] += len(data)
                sink(m, c[:32], data)
        except (socket.timeout, ConnectionError, OSError, ValueError) as e:
            if not self.stop: st["error"] = str(e) or type(e).__name__

PAD_IDLE = bytearray(128)
PAD_IDLE[3] = 0x74
for _o in (9, 11, 13, 15): PAD_IDLE[_o] = 0x80
for _o in (0x28, 0x2A, 0x2C, 0x2E): PAD_IDLE[_o] = 0x02
PAD_IDLE[0x51] = 0x01
BUTTONS = dict(select=0x0501, l3=0x0502, r3=0x0504, start=0x0508, up=0x0510, right=0x0520, down=0x0540,
               left=0x0580, r2=0x0701, l2=0x0702, l1=0x0704, r1=0x0708, triangle=0x0710, circle=0x0720,
               cross=0x0740, square=0x0780)

class Pad:
    def __init__(self, sess):
        self.sess = sess; self.h = Http(sess.ip); self.count = 0; self.id = 0
        self.t0 = time.time(); self.state = bytearray(PAD_IDLE)
        self._post()

    def _post(self):
        self.h.request("POST", "/sce/premo/session/pad", [("PREMO-Pad-Index", "1"), ("SessionID", self.sess.sid),
                       ("Content-Length", str(60 * 128))])

    def send(self):
        self.id += 1; self.count += 1
        struct.pack_into(">I", self.state, 0x40, int((time.time() - self.t0) * 1000 / 16) & 0xFFFFFFFF)
        struct.pack_into(">I", self.state, 0x48, self.id)
        self.h.s.sendall(bytes(self.state))
        if self.count == 60:
            self.h.read_exact(80); self.count = 0; self._post()

    def press(self, name, hold=0.12):
        code = BUTTONS[name]
        self.state[code >> 8] |= code & 0xFF; self.send(); time.sleep(hold)
        self.state[code >> 8] &= ~(code & 0xFF) & 0xFF; self.send()

def adts(payload, rate, ch):
    idx = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000].index(rate)
    n = len(payload) + 7
    return bytes([0xFF, 0xF1, (1 << 6) | (idx << 2) | (ch >> 2), ((ch & 3) << 6) | (n >> 11),
                  (n >> 3) & 0xFF, ((n & 7) << 5) | 0x1F, 0xFC]) + payload

def cmd_test(a):
    if not os.path.exists(CONF): sys.exit("No %s yet. Run the 'keys' or 'register' command first." % CONF)
    conf = json.load(open(CONF))
    sess = Session(a.ip, conf)
    try:
        info = sess.open()
    except (OSError, RuntimeError) as e:
        sys.exit("Connect failed: %s\nIs the PS3 on the Network > Remote Play waiting screen?" % e)
    nick = info.get("premo-ps3-nickname", "")
    try: nick = base64.b64decode(nick).decode("utf-8", "replace")
    except Exception: pass
    print("Session OK   PS3=%r mode=%s" % (nick, info.get("premo-exec-mode")))
    for k in sorted(info):
        if k.startswith("premo-video") or k.startswith("premo-audio"): print("  %-34s %s" % (k, info[k]))
    vc, ac = info.get("premo-video-codec", "AVC"), info.get("premo-audio-codec", "M4A")
    vf = open("rp_video." + ("h264" if vc.upper() == "AVC" else "m4v"), "wb")
    af = open("rp_audio." + ("aac" if ac.upper() == "M4A" else "at3"), "wb")
    try: rate, ch = int(info.get("premo-audio-samplingrate", 48000)), int(info.get("premo-audio-channels", 2))
    except ValueError: rate, ch = 48000, 2
    def asink(m, hd, d):
        try: af.write(adts(d, rate, ch) if m == 0x80 else d)
        except ValueError: af.write(d)
    tv = threading.Thread(target=sess.stream, args=("video", lambda m, hd, d: vf.write(d)), daemon=True)
    ta = threading.Thread(target=sess.stream, args=("audio", asink), daemon=True)
    tv.start(); time.sleep(0.25); ta.start()
    pad_result = None
    if a.pad:
        try:
            time.sleep(2); pad = Pad(sess)
            for b in ("right", "left"): pad.press(b); time.sleep(0.6)
            pad_result = "sent RIGHT then LEFT - the XMB cursor should have moved"
        except Exception as e:
            pad_result = "failed: %s" % e
    t_end = time.time() + a.seconds
    while time.time() < t_end and tv.is_alive(): time.sleep(0.2)
    sess.close(); tv.join(3); ta.join(3); vf.close(); af.close()
    print()
    for kind in ("video", "audio"):
        st = sess.stats.get(kind, {})
        print("%s: %s" % (kind, ", ".join("%s=%s" % kv for kv in st.items())))
    if pad_result: print("pad  :", pad_result)
    if sess.event: print("event:", sess.event)
    head = open(vf.name, "rb").read(5)
    ok = sess.stats.get("video", {}).get("packets", 0) > 0
    if ok and vc.upper() == "AVC": ok = head[:3] == b"\0\0\1" or head[:4] == b"\0\0\0\1"
    print("\nRESULT:", "PASS - open %s in VLC to see the picture" % vf.name if ok else
          "FAIL - copy everything above and send it to me")

def main():
    ap = argparse.ArgumentParser(description="PS3 Remote Play helper")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("keys"); p.add_argument("file"); p.add_argument("--slot", type=int, default=0)
    p.set_defaults(fn=cmd_keys)
    p = sub.add_parser("register"); p.add_argument("file"); p.add_argument("--slot", type=int, default=0)
    p.add_argument("--name", default="iPhone"); p.set_defaults(fn=cmd_register)
    p = sub.add_parser("find"); p.add_argument("--addr", default="255.255.255.255"); p.set_defaults(fn=cmd_find)
    p = sub.add_parser("test"); p.add_argument("ip"); p.add_argument("--seconds", type=float, default=10)
    p.add_argument("--pad", action="store_true"); p.set_defaults(fn=cmd_test)
    a = ap.parse_args()
    if not a.cmd: ap.print_help(); return
    a.fn(a)

if __name__ == "__main__":
    main()
