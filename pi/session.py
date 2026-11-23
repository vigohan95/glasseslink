"""AirShield link session: handshake -> trust -> EndLinkSetup -> services.

This is the piece that turns ``airshield.py`` (codec) into a live conversation
with Ray-Ban Meta glasses, so the glasses can be driven by a Linux box instead
of an Android phone.

Transport contract (see ``transport_bluez.py``)::

    t = LecocoTransport(address="..", psm=128)
    t.send(sdu_bytes)          # one L2CAP CoC SDU
    t.recv_frame(timeout=5.0)  # -> bytes | None

Every method that talks to the glasses takes a ``timeout`` and raises
``LinkTimeout`` instead of hanging forever: the glasses close the link when they
are folded, so a stuck read means "wake them up", not "bug in the parser".

Protocol pages: https://visor.macedonga.com/protocol/
  link-setup-and-airshield/  handshake, KDF, channel binding, EndLinkSetup
  datax/                     framing, channels, tags, status frames
  services/                  svc18 captures, svc20 airship (file transfer)
"""

from __future__ import annotations

import hashlib
import struct
import time
from dataclasses import dataclass, field

import airshield as A
import flatbuf
from ownerkey import OwnerKey

CH_LOCAL_FIRST = 0x8002           # bit15 set = phone-originated channel
SVC_CAPTURES = 18                 # svc18, flatbuffer records, no schema
SVC_AIRSHIP = 20                  # svc20, FileOffer / Cursor / data / complete
SVC_IDENTITY = 36                 # svc36, ownership + trust

# svc36 message types (core/protocol/Constants.kt, IdentityMsgType)
ID_ENABLE_TRUST = 0x1000          # phone -> glasses trust {1: SHA256(pubkey), 2: sig, 3: caps=2}
ID_ENABLE_TRUST_EC = 0x1001       # glasses -> phone trust {1: keyHint, 2: sig, 3: caps}
ID_SKIP_CHALLENGE = 0x2000        # request, empty
ID_SKIP_CHALLENGE_ACK = 0x2001    # {1: nonce(16)}
ID_START_CHANGE_OWNER_REQ = 0x2002    # ServerPendingOwnershipReceipt {1: sig(256), 2: json}
ID_START_CHANGE_OWNER_RESP = 0x2003   # DevicePendingOwnershipReceipt {1: sig, 2: json+cert}
ID_FINISH_CHANGE_OWNER_REQ = 0x2004   # ServerFinalOwnershipReceipt {1: sig(256), 2: json}
ID_FINISH_CHANGE_OWNER_RESP = 0x2005  # ack, empty
ID_IDENTITY_REQUEST = 0x3000      # request, empty
ID_IDENTITY_RESPONSE = 0x3001     # {1: cert(DER), 2: serial, 3: registration, 5: secondary cert}

# svc36 status codes (IdentityStatus)
ID_STATUS_OK = 0x1000
ID_STATUS_NAMES = {
    0x1001: "FAILURE",
    0x1002: "NOT_SUPPORTED",
    0x1003: "UNAVAILABLE",
    0x1010: "KEY_NOT_FOUND",
    0x1040: "INVALID_RECEIPT",
    0x1041: "INVALID_NONCE",
    0x1042: "INVALID_USER_ID — the glasses belong to another Meta account",
    0x1043: "INVALID_APP_IDENTITY",
    0x1044: "INVALID_SIGNATURE",
    0x1045: "INVALID_TIME",
}

CAP_ENUM = 1                      # svc18: enumerate
CAP_RECORD = 6                    # svc18: one capture record
CAP_END = 2                       # svc18: enumeration finished
CAP_REQUEST_ASSET = 0x83          # "<handle>:<assetId>"
CAP_ASSET_QUEUED = 0x84
CAP_SET_LINK = 0x86               # "<handle>:<linkType>" 1 = BT, 7 = WiFi

AIR_FILE_OFFER = 1
AIR_CURSOR = 2
AIR_RESET = 3
AIR_DATA = 4
AIR_CHECK = 5
AIR_COMPLETE = 6
AIR_DROP = 7

KIND_PHOTO = 3073
KIND_VIDEO = 3074

ASSET_VIDEO, ASSET_STILL, ASSET_IMU, ASSET_FRAMELOG = 1, 2, 3, 4
ASSET_DELIVERED = 0x100000


class LinkError(RuntimeError):
    pass


class LinkTimeout(LinkError):
    pass


class TrustRejected(LinkError):
    def __init__(self, code: int):
        self.code = code
        super().__init__(f"trust rejected: 0x{code:04X} "
                         f"({ID_STATUS_NAMES.get(code, 'unknown code')})")


class IdentityRejected(LinkError):
    def __init__(self, step: str, code: int):
        self.code = code
        super().__init__(f"svc36 {step} refused: 0x{code:04X} "
                         f"({ID_STATUS_NAMES.get(code, 'unknown code')})")


@dataclass
class Capture:
    handle: str
    kind: int
    timestamp_ns: int | None
    assets: list[dict] = field(default_factory=list)

    @property
    def is_photo(self) -> bool:
        return self.kind == KIND_PHOTO

    def still_assets(self) -> list[dict]:
        return [a for a in self.assets if a.get("type") == ASSET_STILL]


class GlassesSession:
    """One link. Not thread safe: drive it from a single reader thread."""

    def __init__(self, transport, owner: OwnerKey, *,
                 quirks: int = A.QUIRK_NONE, multikey: bool = False,
                 log=None):
        self.t = transport
        self.owner = owner
        self.quirks = quirks
        self.multikey = multikey
        self.keys: A.SessionKeys | None = None
        self.log = log or (lambda *a: None)
        self.stream_uuid = A.uuid4_bytes()
        self.link_uuid = A.uuid4_bytes()
        self._next_channel = CH_LOCAL_FIRST
        self.channels: dict[int, str] = {}

    # ---------------------------------------------------------------- plumbing
    def _emit(self, msg: str, data: bytes | None = None, inbound: bool = False):
        arrow = "<-" if inbound else "->"
        line = f"[{time.strftime('%H:%M:%S')}] {arrow} {msg}"
        if data is not None:
            line += f" ({len(data)}B) {data[:48].hex()}"
        self.log(line)

    def _send_plain(self, payload: bytes):
        self._emit("plain", payload)
        self.t.send(payload)

    def _send(self, payload: bytes):
        if self.keys is None:
            return self._send_plain(payload)
        frame = self.keys.send.seal(payload)
        self._emit("sealed", payload)
        self.t.send(frame)

    def _recv_raw(self, timeout: float) -> bytes:
        sdu = self.t.recv_frame(timeout=timeout)
        if sdu is None:
            raise LinkTimeout("no frame from the glasses "
                              "(folded / out of range / link dropped)")
        return sdu

    def _recv(self, timeout: float) -> tuple[int, dict, bytes]:
        sdu = self._recv_raw(timeout)
        plain = self.keys.recv.open(sdu) if self.keys else sdu
        channel, tags, payload, _ = A.dx_parse(plain)
        self._emit(f"ch=0x{channel:04X} tags={tags}", plain, inbound=True)
        return channel, tags, payload

    def alloc_channel(self, name: str) -> int:
        ch = self._next_channel
        self._next_channel += 1
        self.channels[ch] = name
        return ch

    # ------------------------------------------------------------- handshake
    def handshake(self, timeout: float = 12.0, trust: bool = True) -> None:
        """RequestEncryption -> EnableEncryption -> [trust] -> EndLinkSetup.

        ``trust=False`` is the setup link: a glasses pair that does not know our
        key yet still accepts the link, and ownership is provisioned over svc36
        before the next connect can trust.
        """
        pub_xy = self.owner.public_xy
        challenge = A.random_nonce()
        seed = A.random_seed()
        iv = A.random_nonce()

        self._send_plain(A.request_encryption(pub_xy, challenge,
                                              quirks=self.quirks))
        ch, tags, body = self._recv(timeout)
        if ch != A.CH_SETUP or tags.get("service") != 5 or tags.get("type") != 1:
            raise LinkError(f"expected RequestEncryption, got ch=0x{ch:04X} {tags}")
        fields = A.pb_parse(body)
        peer_pub = fields[1][0]
        peer_challenge = fields[2][0]
        peer_quirks = fields.get(6, [0])[0]
        if peer_quirks and not self.quirks:
            # the glasses advertise QCS7 themselves; follow them
            self.quirks = peer_quirks

        shared = self.owner.ecdh(peer_pub)

        # keys become active the moment we send EnableEncryption, so build them first
        self.keys = A.SessionKeys(
            shared=shared,
            own_challenge=challenge,
            own_seed=seed,
            peer_challenge=peer_challenge,
            peer_seed=b"\x00" * 32,      # replaced below by the real peer seed
            own_iv=iv,
            peer_iv=b"\x00" * 16,
            peer_base_seq=0,
            quirks=self.quirks,
            multikey=self.multikey,
        )
        self._pending = dict(shared=shared, challenge=challenge, seed=seed, iv=iv,
                             peer_challenge=peer_challenge)

        # EnableEncryption: field4 = base sequence number for the glasses' reader
        self.t.send(A.enable_encryption(pub_xy, seed, iv, 0, self.quirks))
        self._emit("EnableEncryption sent", None)

        # the glasses' EnableEncryption is still plaintext
        sdu = self._recv_raw(timeout)
        ch, tags, body, _ = A.dx_parse(sdu)
        self._emit(f"ch=0x{ch:04X} tags={tags}", sdu, inbound=True)
        if ch != A.CH_SETUP_MIRROR or tags.get("type") != 2:
            raise LinkError(f"expected EnableEncryption, got ch=0x{ch:04X} {tags}")
        f = A.pb_parse(body)
        peer_seed, peer_iv, peer_base = f[2][0], f[3][0], f.get(4, [0])[0]

        self.keys = A.SessionKeys(
            shared=shared, own_challenge=challenge, own_seed=seed,
            peer_challenge=peer_challenge, peer_seed=peer_seed,
            own_iv=iv, peer_iv=peer_iv, peer_base_seq=peer_base,
            quirks=self.quirks, multikey=self.multikey,
        )
        self._binding = A.channel_binding(peer_challenge, peer_pub, seed, pub_xy)
        self._peer_pub = peer_pub

        if trust:
            self._trust(timeout)
        self._end_link_setup(timeout)

    def _trust(self, timeout: float):
        sig = self.owner.sign_digest_raw(self._binding)
        pub_xy = self.owner.public_xy
        self._send(A.trust_message(pub_xy, sig))
        while True:
            ch, tags, payload = self._recv(timeout)
            if tags.get("service") == A.SVC_TRUST and tags.get("type") == A.TRUST_TYPE_GLASSES:
                break
            if tags.get("service") == A.SVC_TRUST and tags.get("type") == A.TRUST_TYPE_PHONE:
                continue
            self.log(f"    (ignoring ch=0x{ch:04X} {tags} during trust)")
        while True:
            ch, tags, _ = self._recv(timeout)
            if tags.get("error") is not None:
                code = tags["error"]
                if code != A.ST_SUCCESS:
                    raise TrustRejected(code)
                return

    def _end_link_setup(self, timeout: float):
        self._send(A.end_link_setup(self.stream_uuid, self.link_uuid))
        while True:
            ch, tags, _ = self._recv(timeout)
            if tags.get("type") == 0x1000:
                break
        self._send(bytes.fromhex("80040001" "03001000"))  # status OK, mirrored

    # --------------------------------------------------------------- services
    def request(self, channel: int, service: int, mtype: int,
                payload: bytes = b"", timeout: float = 8.0,
                want: tuple[int, int] | None = None) -> tuple[dict, bytes]:
        tags = [A.dx_tag(1, service, False), A.dx_tag(2, mtype, True)]
        self._send(A.dx_message(channel, tags, payload))
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise LinkTimeout(f"no answer to svc{service}/type{mtype}")
            ch, rtags, body = self._recv(left)
            if ch != channel:
                self.log(f"    (skip reply on ch=0x{ch:04X} {rtags})")
                continue
            if rtags.get("error") not in (None, 0, A.ST_SUCCESS):
                raise LinkError(f"svc{service}/type{mtype} -> status 0x{rtags['error']:04X}")
            if want is None or (rtags.get("service"), rtags.get("type")) == want:
                return rtags, body

    # -- svc36: identity + change of owner ----------------------------------
    def open_identity(self) -> int:
        """Allocate the svc36 channel used for provisioning and identity reads."""
        self._id_channel = self.alloc_channel("identity")
        self._id_first = True
        return self._id_channel

    def _id_send(self, mtype: int, payload: bytes = b""):
        tags = []
        if self._id_first:                     # a channel names its service once
            tags.append(A.dx_tag(1, SVC_IDENTITY, False))
            self._id_first = False
        tags.append(A.dx_tag(2, mtype, True))
        self._send(A.dx_message(self._id_channel, tags, payload))

    def _id_recv(self, want: int, timeout: float, step: str = "",
                 on_wait=None, wait_after: float = 3.0) -> bytes:
        """Wait for one svc36 message type, raising on a mirrored error status."""
        mirror = self._id_channel ^ 0x8000
        started = time.time()
        warned = on_wait is None
        while True:
            left = timeout - (time.time() - started)
            if left <= 0:
                raise LinkTimeout(f"timed out awaiting svc36 0x{want:04X} {step}")
            if not warned and (time.time() - started) >= wait_after:
                warned = True
                on_wait()
            chunk = 3.0 if not warned else left
            try:
                ch, tags, body = self._recv(min(left, chunk))
            except LinkTimeout:
                continue
            err = tags.get("error")
            if err is not None and ch == mirror:
                if err != ID_STATUS_OK:
                    raise IdentityRejected(step or f"0x{want:04X}", err)
                continue
            if ch != self._id_channel:
                continue
            if tags.get("type") == want:
                return body

    def identity(self, timeout: float = 20.0) -> dict:
        """IDENTITY_REQUEST -> cert DER, serial, registration blob, secondary cert."""
        if not hasattr(self, "_id_channel"):
            self.open_identity()
        self._id_send(ID_IDENTITY_REQUEST)
        body = self._id_recv(ID_IDENTITY_RESPONSE, timeout, "identity")
        f = A.pb_parse(body)
        return {
            "cert": f.get(1, [b""])[0],
            "serial": f.get(2, [b""])[0].decode("ascii", "replace"),
            "registration": f.get(3, [b""])[0],
            "secondary_cert": f.get(5, [b""])[0],
        }

    def skip_challenge(self, timeout: float = 20.0) -> bytes:
        """SKIP_CHALLENGE -> the 16-byte device nonce Meta's pair_request needs."""
        if not hasattr(self, "_id_channel"):
            self.open_identity()
        self._id_send(ID_SKIP_CHALLENGE)
        f = A.pb_parse(self._id_recv(ID_SKIP_CHALLENGE_ACK, timeout, "skip_challenge"))
        return f[1][0]

    def start_change_owner(self, pending_receipt: bytes, timeout: float = 120.0,
                           on_press=None) -> bytes:
        """Hand Meta's pending receipt over; the glasses answer with theirs."""
        if not hasattr(self, "_id_channel"):
            self.open_identity()
        self._id_send(ID_START_CHANGE_OWNER_REQ, pending_receipt)
        return self._id_recv(ID_START_CHANGE_OWNER_RESP, timeout,
                             "start_change_owner", on_wait=on_press)

    def finish_change_owner(self, final_receipt: bytes, timeout: float = 25.0) -> None:
        if not hasattr(self, "_id_channel"):
            self.open_identity()
        self._id_send(ID_FINISH_CHANGE_OWNER_REQ, final_receipt)
        self._id_recv(ID_FINISH_CHANGE_OWNER_RESP, timeout, "finish_change_owner")

    # -- svc18: capture list ------------------------------------------------
    def capture_list(self, timeout: float = 15.0) -> list[Capture]:
        ch = self.alloc_channel("captures")
        tags = [A.dx_tag(1, SVC_CAPTURES, False), A.dx_tag(2, CAP_ENUM, True)]
        self._send(A.dx_message(ch, tags, b""))
        out: list[Capture] = []
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise LinkTimeout("capture enumeration did not finish")
            c, rtags, body = self._recv(left)
            if c != ch:
                continue
            mtype = rtags.get("type")
            if mtype == CAP_END:
                return out
            if mtype == CAP_RECORD:
                cap = parse_capture(body)
                if cap:
                    out.append(cap)

    def request_asset(self, handle: str, asset_id: str):
        ch = self.channels and next(c for c, n in self.channels.items() if n == "captures")
        payload = f"{handle}:{asset_id}".encode()
        self._send(A.dx_message(ch, [A.dx_tag(1, SVC_CAPTURES, False),
                                     A.dx_tag(2, CAP_REQUEST_ASSET, True)], payload))

    def set_link_type(self, handle: str, link_type: int = 1):
        ch = next(c for c, n in self.channels.items() if n == "captures")
        payload = f"{handle}:{link_type}".encode()
        self._send(A.dx_message(ch, [A.dx_tag(1, SVC_CAPTURES, False),
                                     A.dx_tag(2, CAP_SET_LINK, True)], payload))

    # -- svc20: airship file transfer ---------------------------------------
    def receive_file(self, timeout: float = 90.0, chunk_size_hint: int = 1024):
        """Serve one incoming FileOffer to completion.

        Every offer must be answered with type 7 (drop) even when we keep the
        bytes — skipping that reply stalls the glasses' whole queue.
        """
        ch = self.alloc_channel("airship")
        offer = None
        buf = bytearray()
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise LinkTimeout("file transfer did not complete")
            c, tags, body = self._recv(left)
            if c != ch:
                continue
            mtype = tags.get("type")
            if mtype == AIR_FILE_OFFER:
                f = A.pb_parse(body)
                offer = {"uuid": f[1][0], "size": f.get(2, [0])[0],
                         "namespace": f.get(3, [b""])[0].decode(errors="replace"),
                         "name": f.get(4, [b""])[0].decode(errors="replace")}
                self._send(A.dx_message(ch, [A.dx_tag(1, SVC_AIRSHIP, False),
                                             A.dx_tag(2, AIR_CURSOR, True)],
                                        A.pb_key(1, 0) + A.pb_varint(0) +
                                        A.pb_key(2, 0) + A.pb_varint(0)))
                # empty cursor is the documented 10 01 shape for offset 0 / adler 0
                continue
            if mtype == AIR_DATA:
                buf += body
                continue
            if mtype == AIR_CHECK:
                self._send(A.dx_message(ch, [A.dx_tag(1, SVC_AIRSHIP, False),
                                             A.dx_tag(2, AIR_CURSOR, True)],
                                        A.pb_uint(1, len(buf)) +
                                        A.pb_uint(2, _adler32(buf))))
                continue
            if mtype == AIR_COMPLETE:
                self._send(A.dx_message(ch, [A.dx_tag(1, SVC_AIRSHIP, False),
                                             A.dx_tag(2, AIR_DROP, True)]))
                if offer is None:
                    return None, bytes(buf)
                return offer, bytes(buf)
            if mtype in (AIR_RESET, AIR_DROP):
                raise LinkError(f"transfer aborted by the glasses (type {mtype})")

    # ----------------------------------------------------------------- tests
    def close(self):
        try:
            self.t.close()
        except Exception:
            pass


def _adler32(data: bytes) -> int:
    import zlib
    return zlib.adler32(data) & 0xFFFFFFFF


def parse_capture(body: bytes) -> Capture | None:
    """Decode one svc18 type-6 record (schema-less flatbuffer, vtable reads)."""
    root = flatbuf.root(body)
    handle = flatbuf.string(body, root, 4)
    kind = flatbuf.scalar(body, root, 8) or 0
    meta = flatbuf.table(body, root, 12)
    ts = flatbuf.scalar(body, meta, 4) if meta is not None else None
    assets = []
    for asset in flatbuf.table_vector(body, root, 10):
        word = flatbuf.scalar(body, asset, 6) or 0
        assets.append({
            "uuid": flatbuf.string(body, asset, 4) or "",
            "type": word & 0xFF,
            "delivered": bool(word & ASSET_DELIVERED),
            "size": flatbuf.scalar(body, asset, 12) or 0,
            "flags": word,
        })
    if not handle:
        return None
    return Capture(handle=handle, kind=kind, timestamp_ns=ts, assets=assets)
