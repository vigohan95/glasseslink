"""Loopback test: a fake glasses peer speaking the real AirShield protocol.

It proves the parts we can prove without hardware:

  1. handshake ordering and the KDF agreement between the two sides
     (send/recv keys of phone and glasses must be mirror images);
  2. channel binding + NONEwithECDSA trust signature verification;
  3. EndLinkSetup UUID gate and the mirrored status frame;
  4. svc18 capture enumeration through the schema-less flatbuffer reader;
  5. svc20 airship file transfer, including the mandatory "type 7 drop" reply.

Anything that fails here will fail on a real Pi, so this file is the gatekeeper
before `gateway.py` is pointed at glasses.

    python3 selftest_session.py
"""
from __future__ import annotations

import hashlib
import queue
import struct
import sys
import threading

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

import airshield as A
import flatbuf
import session as S
from ownerkey import P256_ORDER, OwnerKey


# --------------------------------------------------------------------------
# a bidirectional SDU pipe that both ends can use as their transport
# --------------------------------------------------------------------------
class Pipe:
    def __init__(self):
        self.to_glasses: queue.Queue[bytes] = queue.Queue()
        self.to_phone: queue.Queue[bytes] = queue.Queue()

    def phone_transport(self):
        pipe = self

        class PhoneTransport:
            def send(self, sdu):
                pipe.to_glasses.put(bytes(sdu))

            def recv_frame(self, timeout=5.0):
                try:
                    return pipe.to_phone.get(timeout=timeout)
                except queue.Empty:
                    return None

            def close(self):
                pipe.to_phone.put(b"")

        return PhoneTransport()


# --------------------------------------------------------------------------
# minimal flatbuffer writer (only what the svc18 record needs)
# --------------------------------------------------------------------------
def fb_pad(buf: bytearray, n: int = 4):
    while len(buf) % n:
        buf.append(0)


def fb_string(buf: bytearray, s: str) -> int:
    raw = s.encode()
    pos = len(buf)
    buf += struct.pack("<I", len(raw)) + raw + b"\x00"
    fb_pad(buf)
    return pos


def fb_table(buf: bytearray, slots: dict[int, bytes]) -> int:
    """slots: slot index -> the 4-byte field payload (offset already resolved)."""
    max_slot = max(slots) if slots else 0
    n = max_slot + 1
    vt_size = 4 + 2 * n

    # vtable first, so the table can point backwards at it
    body = bytearray()
    offsets: dict[int, int] = {}
    cur = 4
    for slot in range(n):
        if slot in slots:
            offsets[slot] = cur
            body += slots[slot]
            cur += 4

    vt = bytearray(struct.pack("<HH", vt_size, cur))
    for slot in range(n):
        vt += struct.pack("<H", offsets.get(slot, 0))
    while len(vt) % 4:
        vt.append(0)

    vt_pos = len(buf)
    buf += vt
    table_pos = len(buf)
    buf += struct.pack("<i", table_pos - vt_pos)
    buf += body
    fb_pad(buf)
    return table_pos


def fb_u32(v: int) -> bytes:
    return struct.pack("<I", v & 0xFFFFFFFF)


def add_table(buf: bytearray, slots) -> tuple[int, dict[int, int]]:
    """Append a table (vtable first) with zeroed fields; returns field positions."""
    slots = sorted(slots)
    n = max(slots) + 1
    vt_size = 4 + 2 * n
    offsets = {}
    cur = 4
    for slot in range(n):
        if slot in slots:
            offsets[slot] = cur
            cur += 4
    vt = bytearray(struct.pack("<HH", vt_size, cur))
    for slot in range(n):
        vt += struct.pack("<H", offsets.get(slot, 0))
    while len(vt) % 4:
        vt.append(0)
    vt_pos = len(buf)
    buf += vt
    table_pos = len(buf)
    buf += struct.pack("<i", table_pos - vt_pos)
    buf += b"\x00" * (4 * len(slots))
    fb_pad(buf)
    return table_pos, {s: table_pos + offsets[s] for s in slots}


def put_ref(buf: bytearray, field_pos: int, target_pos: int):
    struct.pack_into("<I", buf, field_pos, target_pos - field_pos)


def build_capture_record(handle: str, kind: int, ts_ns: int,
                         assets: list[tuple[str, int, int]]) -> bytes:
    buf = bytearray(b"\x00\x00\x00\x00")            # root offset, patched last

    rec, rec_fields = add_table(buf, {4, 8, 10, 12})
    struct.pack_into("<I", buf, rec_fields[8], kind)

    # vector of asset tables: count then one relative offset per element
    vec_pos = len(buf)
    buf += struct.pack("<I", len(assets))
    elem_positions = []
    for _ in assets:
        elem_positions.append(len(buf))
        buf += struct.pack("<I", 0)
    fb_pad(buf)

    for i, (uuid, atype, size) in enumerate(assets):
        tbl, fields = add_table(buf, {4, 6, 12})
        struct.pack_into("<I", buf, fields[6], atype)
        struct.pack_into("<I", buf, fields[12], size)
        put_ref(buf, elem_positions[i], tbl)            # vector element -> table
        spos = fb_string(buf, uuid)
        put_ref(buf, fields[4], spos)                   # table slot 4 -> string

    put_ref(buf, rec_fields[10], vec_pos)               # record slot 10 -> vector
    hpos = fb_string(buf, handle)
    put_ref(buf, rec_fields[4], hpos)                   # record slot 4 -> handle

    meta, meta_fields = add_table(buf, {4})             # metadata { slot4: ns }
    struct.pack_into("<I", buf, meta_fields[4], ts_ns & 0xFFFFFFFF)
    put_ref(buf, rec_fields[12], meta)                  # record slot 12 -> metadata

    struct.pack_into("<I", buf, 0, rec)
    return bytes(buf)


# --------------------------------------------------------------------------
# the fake peer
# --------------------------------------------------------------------------
class FakeGlasses(threading.Thread):
    def __init__(self, pipe: Pipe, phone_pub_xy: bytes,
                 captures, files, log=print):
        super().__init__(daemon=True)
        self.pipe = pipe
        self.phone_pub_xy = phone_pub_xy
        self.captures = captures
        self.files = files
        self.log = log
        self.failure: str | None = None
        self.got_drop = False
        self.got_status = False

    # -- plumbing -------------------------------------------------------
    def send_plain(self, data: bytes):
        self.pipe.to_phone.put(data)

    def recv_plain(self, timeout=8.0):
        return self.pipe.to_glasses.get(timeout=timeout)

    def run(self):
        try:
            self._handshake()
            self._services()
        except Exception as exc:                      # noqa: BLE001
            self.failure = f"{type(exc).__name__}: {exc}"
            self.log(f"    fake glasses stopped: {self.failure}")

    # -- handshake ------------------------------------------------------
    def _handshake(self):
        req = self.recv_plain()
        ch, tags, body, _ = A.dx_parse(req)
        assert (ch, tags.get("service"), tags.get("type")) == (A.CH_SETUP, 5, 1), tags
        f = A.pb_parse(body)
        phone_pub, phone_challenge = f[1][0], f[2][0]

        self.priv = ec.generate_private_key(ec.SECP256R1())
        nums = self.priv.public_key().public_numbers()
        self.pub_xy = nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")
        self.challenge = A.random_nonce()
        self.send_plain(A.request_encryption(self.pub_xy, self.challenge))

        en = self.recv_plain()
        ch, tags, body, _ = A.dx_parse(en)
        assert (ch, tags.get("type")) == (A.CH_SETUP_MIRROR, 2), tags
        f = A.pb_parse(body)
        assert f[1][0] == phone_pub
        phone_seed, phone_iv = f[2][0], f[3][0]

        self.seed = A.random_seed()
        self.iv = A.random_nonce()
        self.send_plain(A.enable_encryption(self.pub_xy, self.seed, self.iv, 0))

        peer = ec.EllipticCurvePublicNumbers(
            int.from_bytes(phone_pub[:32], "big"),
            int.from_bytes(phone_pub[32:], "big"),
            ec.SECP256R1()).public_key()
        shared = self.priv.exchange(ec.ECDH(), peer)

        # mirrored schedule: our send == phone recv, our recv == phone send
        self.tx = A.Direction(*A.derive_keys(shared, self.seed, phone_challenge,
                                             self.iv)[:3], 0)
        # phone -> glasses: nonce = glasses challenge, seed = phone seed, iv = phone iv
        self.rx = A.Direction(*A.derive_keys(shared, self.challenge, phone_seed,
                                             phone_iv)[:3], 0)
        self.binding = A.channel_binding(self.challenge, self.pub_xy,
                                         phone_seed, phone_pub)

        # trust
        tr = self.recv()
        ch, tags, body, _ = A.dx_parse(tr)
        assert tags.get("service") == A.SVC_TRUST and tags.get("type") == A.TRUST_TYPE_PHONE
        f = A.pb_parse(body)
        assert f[1][0] == hashlib.sha256(phone_pub).digest(), "public id mismatch"
        assert f[3][0] == 2, "capabilities field"
        self._verify(phone_pub, f[2][0], self.binding)
        self.send(A.dx_message(A.CH_SETUP_MIRROR,
                               [A.dx_tag(1, A.SVC_TRUST, False),
                                A.dx_tag(2, A.TRUST_TYPE_GLASSES, True)], b""))
        self.send_plain_dx(A.dx_status(A.CH_SETUP_MIRROR, A.ST_SUCCESS))

        # end link setup
        els = self.recv()
        ch, tags, _, _2 = A.dx_parse(els)
        assert tags.get("type") == 0x1000, tags
        self.send(A.dx_message(A.CH_SETUP_MIRROR,
                               [A.dx_tag(2, 0x1000, True)], b""))
        status = self.recv()
        ch, tags, _, _2 = A.dx_parse(status)
        assert tags.get("error") == A.ST_SUCCESS, tags
        self.got_status = True

    def _verify(self, pub_xy: bytes, sig_raw: bytes, digest: bytes):
        pub = ec.EllipticCurvePublicNumbers(
            int.from_bytes(pub_xy[:32], "big"),
            int.from_bytes(pub_xy[32:], "big"),
            ec.SECP256R1()).public_key()
        r = int.from_bytes(sig_raw[:32], "big")
        s = int.from_bytes(sig_raw[32:], "big")
        der = utils.encode_dss_signature(r, s)
        pub.verify(der, digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))

    # -- encrypted helpers ---------------------------------------------
    def send(self, plain: bytes):
        self.pipe.to_phone.put(self.tx.seal(plain))

    def send_plain_dx(self, plain: bytes):
        # a status frame right after trust still rides the encrypted session
        self.send(plain) if False else self.send(plain)

    def recv(self, timeout=8.0) -> bytes:
        sdu = self.pipe.to_glasses.get(timeout=timeout)
        return self.rx.open(sdu)

    # -- services -------------------------------------------------------
    def _services(self):
        while True:
            plain = self.recv(timeout=15)
            ch, tags, body, _ = A.dx_parse(plain)
            svc, mtype = tags.get("service"), tags.get("type")
            if svc == S.SVC_CAPTURES and mtype == S.CAP_ENUM:
                for cap in self.captures:
                    self.send(A.dx_message(ch, [A.dx_tag(1, S.SVC_CAPTURES, False),
                                                A.dx_tag(2, S.CAP_RECORD, True)], cap))
                self.send(A.dx_message(ch, [A.dx_tag(1, S.SVC_CAPTURES, False),
                                            A.dx_tag(2, S.CAP_END, True)]))
                continue
            if svc == S.SVC_CAPTURES and mtype == S.CAP_REQUEST_ASSET:
                self._serve_file(ch)
                continue
            if svc == S.SVC_AIRSHIP and mtype == S.AIR_DROP:
                self.got_drop = True
                continue

    def _serve_file(self, ch_hint):
        ch = S.CH_LOCAL_FIRST + 1                      # the peer's airship channel
        name, payload = self.files
        uuid = A.uuid4_bytes()
        offer = (A.pb_bytes(1, uuid) + A.pb_uint(2, len(payload)) +
                 A.pb_bytes(3, b"namespace_media") + A.pb_bytes(4, name.encode()))
        self.send(A.dx_message(ch, [A.dx_tag(1, S.SVC_AIRSHIP, False),
                                    A.dx_tag(2, S.AIR_FILE_OFFER, True)], offer))
        self.recv()                                     # cursor
        for i in range(0, len(payload), 1024):
            self.send(A.dx_message(ch, [A.dx_tag(1, S.SVC_AIRSHIP, False),
                                        A.dx_tag(2, S.AIR_DATA, True)],
                                   payload[i:i + 1024]))
        self.send(A.dx_message(ch, [A.dx_tag(1, S.SVC_AIRSHIP, False),
                                    A.dx_tag(2, S.AIR_COMPLETE, True)],
                               A.pb_uint(1, len(payload)) + A.pb_uint(2, S._adler32(payload))))


def main() -> int:
    owner = OwnerKey.generate()
    pipe = Pipe()
    record = build_capture_record("cap-1", S.KIND_PHOTO, 1_700_000_000_000_000_000,
                                  [("asset-a", S.ASSET_STILL, 2_730_026)])
    files = ("Visor_20261123_110000.jpg", bytes(range(256)) * 20)   # 5120 B
    fake = FakeGlasses(pipe, owner.public_xy, [record], files, log=print)
    fake.start()

    logs: list[str] = []
    sess = S.GlassesSession(pipe.phone_transport(), owner, log=logs.append)
    ok = True

    try:
        sess.handshake(timeout=8)
        print("[1] handshake + trust + EndLinkSetup       OK")
    except Exception as exc:                                  # noqa: BLE001
        print(f"[1] handshake FAILED: {type(exc).__name__}: {exc}")
        for line in logs[-12:]:
            print("    ", line)
        return 1

    try:
        caps = sess.capture_list(timeout=8)
        assert len(caps) == 1 and caps[0].handle == "cap-1", caps
        assert caps[0].is_photo and caps[0].still_assets()[0]["size"] == 2_730_026
        print(f"[2] svc18 capture list                     OK  ({caps[0].handle}, "
              f"{caps[0].still_assets()[0]['size']} B)")
    except Exception as exc:                                  # noqa: BLE001
        print(f"[2] capture list FAILED: {type(exc).__name__}: {exc}")
        ok = False

    try:
        sess.request_asset("cap-1", "asset-a")
        offer, data = sess.receive_file(timeout=10)
        assert offer and data == files[1], (offer, len(data))
        print(f"[3] svc20 airship transfer                 OK  ({offer['name']}, "
              f"{len(data)} B, adler ok)")
    except Exception as exc:                                  # noqa: BLE001
        print(f"[3] airship FAILED: {type(exc).__name__}: {exc}")
        ok = False

    fake.join(timeout=3)
    if fake.failure:
        print(f"[4] peer-side assertion                    FAIL  {fake.failure}")
        ok = False
    else:
        print("[4] peer-side assertions                   OK  (binding, public id, caps)")
    if not fake.got_drop:
        print("[5] type 7 drop reply                      FAIL  missing")
        ok = False
    else:
        print("[5] type 7 drop reply                      OK")

    print("ALL OK" if ok else "FAILURES ABOVE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
