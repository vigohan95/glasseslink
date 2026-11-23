#!/usr/bin/env python3
"""Self-test for airshield.py — no glasses, no key, no radio.

    python3 selftest.py
"""
from __future__ import annotations

import os
import sys

import airshield as A

FAILS = 0


def check(name, cond, extra=""):
    global FAILS
    if not cond:
        FAILS += 1
    print(("  ok   " if cond else "  FAIL ") + name + (f"  [{extra}]" if extra else ""))


def raises(fn) -> bool:
    try:
        fn()
        return False
    except Exception:
        return True


def main() -> int:
    print("[1] DataX tag layout vs docs sample 81 00 00 05 02 00 00 01")
    got = (A.dx_tag(1, 5, False) + A.dx_tag(2, 1, True)).hex()
    check("tags", got == "8100000502000001", got)

    print("[2] status frame vs docs sample 80 04 00 02 03 00 00 00")
    check("status", A.dx_status(0x0002, 0).hex() == "8004000203000000",
          A.dx_status(0x0002, 0).hex())

    print("[3] header-only message vs docs sample 00 11 80 02")
    check("bare header", A.dx_header(0x8002, 17).hex() == "00118002",
          A.dx_header(0x8002, 17).hex())

    print("[4] EndLinkSetup: 46 bytes, documented prefix")
    fr = A.end_link_setup(A.uuid4_bytes(), A.uuid4_bytes())
    check("length", len(fr) == 46, str(len(fr)))
    check("prefix", fr[:8].hex() == "802a800102001000", fr[:8].hex())

    print("[5] UUID v4 gate")
    check("rejects non-v4", raises(lambda: A.end_link_setup(b"\x01" * 16, A.uuid4_bytes())))

    print("[6] RequestEncryption / EnableEncryption roundtrip")
    pub, chal = os.urandom(64), os.urandom(16)
    ch, tags, payload, used = A.dx_parse(A.request_encryption(pub, chal))
    check("req channel", ch == 0x8001, hex(ch))
    check("req tags", (tags["service"], tags["type"]) == (5, 1), str(tags))
    f = A.pb_parse(payload)
    check("req body", f[1][0] == pub and f[2][0] == chal and f[7][0] == 16)
    seed, iv = os.urandom(32), os.urandom(16)
    ch, tags, payload, _ = A.dx_parse(A.enable_encryption(pub, seed, iv, 9))
    f = A.pb_parse(payload)
    check("enable channel mirror", ch == 0x0001, hex(ch))
    check("enable base seq", f[4][0] == 9, str(f[4][0]))
    check("enable tags close", (tags["service"], tags["type"]) == (2, 2), str(tags))

    print("[7] Padding per the docs table")
    check("46 -> C2 C2", len(A.pad(b"x" * 46)) == 48 and A.pad(b"x" * 46)[-2:].hex() == "c2c2")
    check("32 -> D0 x16", A.pad(b"x" * 32)[-16:].hex() == "d0" * 16)
    check("8 -> C8 x8", A.pad(b"x" * 8)[-8:].hex() == "c8" * 8)
    check("unpad", A.unpad(A.pad(b"hello" * 9)) == b"hello" * 9)

    print("[8] Key schedule determinism and the QCS7 quirk")
    shared = os.urandom(32)
    k1 = A.derive_keys(shared, chal, seed, iv)
    k2 = A.derive_keys(shared, chal, seed, iv)
    check("deterministic", k1[0] == k2[0] and len(k1[0]) == 32)
    q = A.derive_keys(shared, chal, seed, iv, quirks=A.QUIRK_QCS7)
    check("qcs7 differs", q[0] != k1[0])
    check("qcs7 mac word", q[3].hex() == "02020001", q[3].hex())

    print("[9] DATA frame: seal/open, IV chaining, sequence, tamper")
    d = A.Direction(k1[0], k1[1], iv, 0, mac_word=k1[3])
    sdu = d.seal(b'{"hi":1}')
    check("header 0x40", sdu[0] == 0x40, hex(sdu[0]))
    check("sdu length 10+16n", (len(sdu) - 10) % 16 == 0 and len(sdu) == 10 + 16)
    r = A.Direction(k1[0], k1[1], iv, 0, mac_word=k1[3])
    check("roundtrip", r.open(sdu) == b'{"hi":1}')
    check("seq advanced", d.seq == 1, str(d.seq))
    sdu2 = d.seal(b'{"hi":2}')
    check("iv chained", sdu2[10:26] != sdu[10:26])
    check("recv still syncs", r.open(sdu2) == b'{"hi":2}')
    check("rejects replay", raises(lambda: A.Direction(k1[0], k1[1], iv, 0, mac_word=k1[3])
                                   .open(sdu2)))
    bad = bytearray(sdu)
    bad[0] = 0x41
    bad[10] ^= 1
    check("rejects tamper", raises(lambda: A.Direction(k1[0], k1[1], iv, 0, mac_word=k1[3])
                                   .open(bytes(bad))))

    print("[10] SessionKeys wires both directions")
    sk = A.SessionKeys(shared, chal, seed, os.urandom(16), os.urandom(32),
                       os.urandom(16), os.urandom(16), 7)
    check("send/recv keys differ", sk.send.aes_key != sk.recv.aes_key)
    check("base seq honoured", sk.recv.seq == 7, str(sk.recv.seq))

    print("[11] channel binding")
    b1 = A.channel_binding(chal, pub, seed, pub)
    b2 = A.channel_binding(chal, pub, seed + b"\x00", pub)
    check("binding", b1 != b2 and len(b1) == 32)

    print("[12] trust body shape")
    tm = A.trust_message(pub, os.urandom(64))
    ch, tags, payload, _ = A.dx_parse(tm)
    f = A.pb_parse(payload)
    check("svc36 type 4096", (tags["service"], tags["type"]) == (36, 4096), str(tags))
    check("digest of pubkey", f[1][0].hex() == __import__("hashlib").sha256(pub).hexdigest())
    check("capabilities 2", f[3][0] == 2, str(f[3][0]))

    print("\n" + ("ALL OK" if not FAILS else f"{FAILS} FAILURES"))
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
