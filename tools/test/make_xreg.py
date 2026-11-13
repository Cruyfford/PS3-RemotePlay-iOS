#!/usr/bin/env python3
"""Build a synthetic xRegistry.sys in the layout ps3rp.py assumes (for self-tests only)."""
import struct, sys
names = ["/setting", "/setting/parental", "/setting/parental/passwordNumber", "/setting/premo"]
vals = {"/setting/parental/passwordNumber": (2, b"0000\0")}
for n in range(1, 9):
    b = "/setting/premo/psp%02d" % n
    names += [b, b + "/nickname", b + "/macAddress", b + "/id", b + "/keyType", b + "/key"]
    vals[b + "/nickname"] = (2, b"\0")
    vals[b + "/macAddress"] = (2, bytes(6))
    vals[b + "/id"] = (2, bytes(16))
    vals[b + "/keyType"] = (1, bytes(4))
    vals[b + "/key"] = (2, bytes(16))
names += ["/setting/premo/remoteBoot", "/setting/net", "/setting/net/eapMd5/password"]
vals["/setting/premo/remoteBoot"] = (1, struct.pack(">I", 1))
vals["/setting/net/eapMd5/password"] = (2, b"secret\0")
buf = bytearray(0x40000)
buf[0:16] = bytes.fromhex("BCADADBC0000009000000002BCADADBC")
p = 0x10; off = {}
for i, n in enumerate(names):
    off[n] = p - 0x10
    e = struct.pack(">HHB", 0x1000 + i, len(n), 0) + n.encode() + b"\0"
    buf[p:p + len(e)] = e; p += len(e)
buf[p:p + 5] = b"\xAA\xBB\xCC\xDD\xEE"
p = 0xFFF0; buf[p:p + 2] = b"\x4D\x26"; p += 2
for n, (t, d) in vals.items():
    e = struct.pack(">HHHHB", 0x7A, off[n], 0, len(d), t) + d + b"\0"
    buf[p:p + len(e)] = e; p += len(e)
buf[p:p + 5] = b"\xAA\xBB\xCC\xDD\xEE"
open(sys.argv[1], "wb").write(buf)
