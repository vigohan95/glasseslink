#!/usr/bin/env python3
"""AirShield + DataX for Linux — spec-faithful port of the public Meta glasses protocol.

Sources (all public, 2026):
  visor.macedonga.com/protocol/link-setup-and-airshield
  visor.macedonga.com/protocol/airshield-frames-and-ciphers
  visor.macedonga.com/protocol/datax-channels

This module is transport-free: it builds and parses bytes. Use it with
transport_bluez.py (LE CoC, PSM 128 on Ray-Ban Meta Gen 2) or a TCP socket.

    sudo apt install python3-cryptography
    python3 selftest.py
"""
from __future__ import annotations

import hashlib
import hmac as hmaclib
import os
import struct
import uuid as uuidlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# ---- channels --------------------------------------------------------------
CH_SETUP = 0x8001       # link setup channel (RequestEncryption, EndLinkSetup)
CH_SETUP_MIRROR = 0x0001

# ---- svc / type constants --------------------------------------------------
SVC_TRUST = 36
TRUST_TYPE_PHONE = 0x1000
TRUST_TYPE_GLASSES = 0x1001

# ---- status codes (error tag on a status frame) ----------------------------
ST_OK = 0x0000
ST_SUCCESS = 0x1000
ST_SERVICE_NOT_FOUND = 0xC001
ST_CHANNEL_GONE = 0xC002
ST_UNKNOWN_TYPE = 0xD001

# ---- quirks / mac word -----------------------------------------------------
QUIRK_NONE = 0
QUIRK_QCS7 = 1

PAD_MAGIC = 0xC0
FRAME_DATA = 0x40


# ===== DataX framing ========================================================
def dx_header(channel: int, payload_len: int, has_extension: bool = False) -> bytes:
    """4-byte fixed header. payload_len is 14 bits and counts tags + payload."""
    if payload_len > 0x3FFF:
        raise ValueError("payload_len is 14 bits")
    b0 = (0x80 if has_extension else 0) | ((payload_len >> 8) & 0x3F)
    return bytes([b0, payload_len & 0xFF]) + struct.pack(">H", channel)


def dx_tag(tag_id: int, value: int, last: bool) -> bytes:
    b = tag_id & 0x7F
    if not last:
        b |= 0x80
    return bytes([b, 0x00]) + struct.pack(">H", value & 0xFFFF)


def dx_message(channel: int, tags: list[bytes], payload: bytes = b"") -> bytes:
    n = sum(len(t) for t in tags) + len(payload)
    return dx_header(channel, n, has_extension=bool(tags)) + b"".join(tags) + payload


def dx_status(channel: int, code: int) -> bytes:
    """Bare header with only the error tag and no payload."""
    return dx_message(channel, [dx_tag(3, code, True)])


def dx_parse(buf: bytes) -> tuple[int, dict, bytes, int]:
    """Parse one DataX message.

    Returns (channel, tags, payload, consumed) where tags is
    {"service": int|None, "type": int|None, "error": int|None}.
    """
    if len(buf) < 4:
        raise ValueError("short header")
    b0 = buf[0]
    payload_len = ((b0 & 0x3F) << 8) | buf[1]
    channel = struct.unpack(">H", buf[2:4])[0]
    tags: dict = {"service": None, "type": None, "error": None}
    i = 4
    if b0 & 0x80:
        while True:
            if i + 4 > len(buf):
                raise ValueError("short tag")
            tb = buf[i]
            val = struct.unpack(">H", buf[i + 2:i + 4])[0]
            tid = tb & 0x7F
            if tid == 1:
                tags["service"] = val
            elif tid in (2, 4):
                tags["type"] = val
            elif tid == 3:
                tags["error"] = val
            i += 4
            if not tb & 0x80:
                break
    end = i + (payload_len - (i - 4))
    if len(buf) < end:
        raise ValueError("short payload")
    return channel, tags, buf[i:end], end


# ===== protobuf (wire types 0 and 2) =======================================
def pb_varint(v: int) -> bytes:
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_key(field: int, wire: int) -> bytes:
    return pb_varint(field << 3 | wire)


def pb_uint(field: int, v: int) -> bytes:
    return pb_key(field, 0) + pb_varint(v)


def pb_bytes(field: int, data: bytes) -> bytes:
    return pb_key(field, 2) + pb_varint(len(data)) + data


def pb_parse(buf: bytes) -> dict[int, list]:
    out: dict[int, list] = {}
    i = 0
    while i < len(buf):
        key, i = _read_varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            v, i = _read_varint(buf, i)
        elif wire == 2:
            n, i = _read_varint(buf, i)
            v, i = buf[i:i + n], i + n
        else:
            raise NotImplementedError(f"wire type {wire}")
        out.setdefault(field, []).append(v)
    return out


def _read_varint(buf: bytes, i: int) -> tuple[int, int]:
    val = 0
    shift = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


# ===== link setup messages (plaintext DataX) ===============================
def request_encryption(pub_xy: bytes, challenge: bytes,
                       hints: tuple[bytes, ...] = (), quirks: int = QUIRK_NONE) -> bytes:
    body = (pb_bytes(1, pub_xy) + pb_bytes(2, challenge) + pb_uint(3, 0) + pb_uint(4, 31))
    for h in hints:
        body += pb_bytes(5, h)
    if quirks:
        body += pb_uint(6, quirks)
    body += pb_uint(7, 16)
    return dx_message(CH_SETUP, [dx_tag(1, 5, False), dx_tag(2, 1, True)], body)


def enable_encryption(pub_xy: bytes, seed: bytes, iv: bytes,
                      base_seq: int, quirks: int = QUIRK_NONE) -> bytes:
    body = (pb_bytes(1, pub_xy) + pb_bytes(2, seed) + pb_bytes(3, iv)
            + pb_uint(4, base_seq) + pb_uint(5, 31))
    if quirks:
        body += pb_uint(6, quirks)
    return dx_message(CH_SETUP_MIRROR, [dx_tag(1, 2, False), dx_tag(2, 2, True)], body)


def end_link_setup(stream_uuid: bytes, link_uuid: bytes) -> bytes:
    for name, u in (("stream", stream_uuid), ("link", link_uuid)):
        if len(u) != 16 or (u[6] & 0xF0) != 0x40 or (u[8] & 0xC0) != 0x80:
            raise ValueError(f"{name} uuid is not RFC4122 v4 — glasses answer service_not_found")
    body = pb_uint(1, 1) + pb_bytes(2, stream_uuid) + pb_bytes(3, link_uuid)
    return bytes.fromhex("802A8001" "02001000") + body


def trust_message(pub_xy: bytes, signature_raw: bytes) -> bytes:
    """svc36 type 4096: SHA-256(pubkey x||y), r||s, capabilities 2."""
    digest = hashlib.sha256(pub_xy).digest()
    assert len(signature_raw) == 64
    body = pb_bytes(1, digest) + pb_bytes(2, signature_raw) + pb_uint(3, 2)
    return dx_message(CH_SETUP_MIRROR, [dx_tag(1, SVC_TRUST, False),
                                        dx_tag(2, TRUST_TYPE_PHONE, True)], body)


def uuid4_bytes() -> bytes:
    return uuidlib.uuid4().bytes


# ===== key schedule ========================================================
def derive_keys(shared: bytes, nonce: bytes, seed: bytes, iv: bytes,
                quirks: int = QUIRK_NONE, multikey: bool = False):
    """HKDF-ish schedule from link-setup-and-airshield.

    salt_aes  = SHA256(nonce || seed)
    salt_hmac = SHA256(seed || nonce || "hmac_derive")
    PRK       = HMAC-SHA256(salt_aes, shared)
    key       = HMAC-SHA256(PRK, "AirShield" || 0x01)          (32 B)
    quirks=1  : info becomes "AirShield" padded to 128 || LE32 32 || LE32 256
    """
    # nonce/seed are 16 and 32 bytes for the send direction; the receive direction
    # swaps those roles (peer seed first, own challenge second), so only the shared
    # secret has a fixed width.
    assert len(shared) == 32 and nonce and seed
    salt_aes = hashlib.sha256(nonce + seed).digest()
    salt_hmac = hashlib.sha256(seed + nonce + b"hmac_derive").digest()
    prk = hmaclib.new(salt_aes, shared, hashlib.sha256).digest()
    info = (b"AirShield".ljust(128, b"\x00") + struct.pack("<II", 32, 256)
            if quirks == QUIRK_QCS7 else b"AirShield\x01")
    aes_key = hmaclib.new(prk, info, hashlib.sha256).digest()
    hmac_key = aes_key
    if multikey:
        prk_h = hmaclib.new(salt_hmac, shared, hashlib.sha256).digest()
        hmac_key = hmaclib.new(prk_h, info, hashlib.sha256).digest()
    mac_word = bytes([0x02, 0x02, 0x00, quirks & 0xFF])
    return aes_key, hmac_key, iv, mac_word


def channel_binding(glasses_challenge: bytes, glasses_pub: bytes,
                    seed: bytes, phone_pub: bytes) -> bytes:
    a = hashlib.sha256(glasses_challenge + glasses_pub).digest()
    b = hashlib.sha256(seed + phone_pub).digest()
    return hashlib.sha256(a + b).digest()


# ===== padding and per-direction cipher ====================================
def pad(plain: bytes) -> bytes:
    n = 16 - (len(plain) % 16)
    return plain + bytes([(n + PAD_MAGIC) & 0xFF]) * n


def unpad(data: bytes) -> bytes:
    if not data:
        return data
    n = (data[-1] + 0x40) & 0xFF
    if 1 <= n <= 16 and data[-n:] == bytes([data[-1]]) * n:
        return data[:-n]
    return data  # inbound padding is not enforced by the phone either


class Direction:
    """One direction of an AirShield session: AES-256-CBC + HMAC-SHA-256.

    The IV chains: it starts at the IV from EnableEncryption and then becomes the
    last ciphertext block of every frame. The sequence is 4 bytes little endian
    and never resets on a link.
    """

    def __init__(self, aes_key: bytes, hmac_key: bytes, iv: bytes, seq: int,
                 mac_word: bytes = b"\x02\x02\x00\x00", stream: int = 0):
        self.aes_key, self.hmac_key = aes_key, hmac_key
        self.iv, self.seq = iv, seq
        self.mac_word, self.stream = mac_word, stream

    # -- send ---------------------------------------------------------
    def seal(self, plaintext: bytes) -> bytes:
        data = pad(plaintext)
        nblocks = len(data) // 16
        ct = self._cbc(data)
        count = nblocks - 1
        mac = self._mac(count, ct)
        self.iv = ct[-16:]
        self.seq = (self.seq + 1) & 0xFFFFFFFF
        return bytes([FRAME_DATA | self.stream]) + mac + bytes([count]) + ct

    # -- receive ------------------------------------------------------
    def open(self, sdu: bytes) -> bytes:
        if len(sdu) < 25:
            raise ValueError("frame too short")
        if sdu[0] & 0xC0 != FRAME_DATA:
            raise ValueError("not a DATA frame")
        tag, count = sdu[1:9], sdu[9]
        ct = sdu[10:]
        if len(ct) != 16 * (count + 1):
            raise ValueError("length does not match the block count")
        if not hmaclib.compare_digest(tag, self._mac(count, ct)):
            raise ValueError("bad MAC")
        plain = self._cbc(ct, encrypt=False)
        self.iv = ct[-16:]
        self.seq = (self.seq + 1) & 0xFFFFFFFF
        return unpad(plain)

    # -- internals ----------------------------------------------------
    def _mac(self, count: int, ct: bytes) -> bytes:
        msg = self.mac_word + struct.pack("<I", self.seq) + bytes([count]) + ct
        return hmaclib.new(self.hmac_key, msg, hashlib.sha256).digest()[:8]

    def _cbc(self, data: bytes, encrypt: bool = True) -> bytes:
        c = Cipher(algorithms.AES(self.aes_key), modes.CBC(self.iv))
        op = c.encryptor() if encrypt else c.decryptor()
        return op.update(data) + op.finalize()


class SessionKeys:
    """Send and receive state for one link.

    Per the protocol page: the send key comes from the glasses' challenge and the
    phone's seed; the receive key from the glasses' seed and the phone's challenge.
    """

    def __init__(self, shared: bytes, own_challenge: bytes, own_seed: bytes,
                 peer_challenge: bytes, peer_seed: bytes, own_iv: bytes,
                 peer_iv: bytes, peer_base_seq: int, quirks: int = QUIRK_NONE,
                 multikey: bool = False):
        self.send = Direction(*derive_keys(shared, peer_challenge, own_seed, own_iv,
                                           quirks, multikey)[:3], 0,
                              mac_word=bytes([0x02, 0x02, 0x00, quirks & 0xFF]))
        self.recv = Direction(*derive_keys(shared, peer_seed, own_challenge, peer_iv,
                                           quirks, multikey)[:3], peer_base_seq,
                              mac_word=bytes([0x02, 0x02, 0x00, quirks & 0xFF]))


def random_nonce() -> bytes:
    return os.urandom(16)


def random_seed() -> bytes:
    return os.urandom(32)
