"""Offline proof of the ownership path: fake glasses + fake Meta.

No hardware, no network. It exercises exactly what `provision.py` does:

    handshake(trust=False) -> svc36 identity -> skip_challenge
        -> start_change_owner -> (fake Meta pair) -> finish_change_owner
        -> identity/owner-export.json written and loadable

The fake peer speaks the real AirShield codec (airshield.py) and enforces the
things a real pair enforces: the DataX channel is named once, the mirrored
status frame after EndLinkSetup carries 0x1000, and svc36 statuses ride the
mirror channel.

    python3 selftest_provision.py
"""
from __future__ import annotations

import json
import os
import queue
import sys
import tempfile
import threading

from cryptography.hazmat.primitives.asymmetric import ec

import airshield as A
import session as S
from ownerkey import OwnerKey
from selftest_session import Pipe
import meta_identity as MI
import provision as P


CERT = b"\x30\x82\x01\x00" + bytes(range(64)) * 4       # stand-in DER certificate
SERIAL = "4V0ZW04H7J046N"
DEVICE_NONCE = bytes(range(16))


class FakeGlassesSetup(threading.Thread):
    """A pair that has no owner yet: it accepts the link but asks for provisioning."""

    def __init__(self, pipe: Pipe, log=print):
        super().__init__(daemon=True)
        self.pipe = pipe
        self.log = log
        self.failure: str | None = None
        self.seen: list[tuple[str, int]] = []
        self.identity_channel: int | None = None
        self.finished = threading.Event()

    # -- plumbing -------------------------------------------------------
    def run(self):
        try:
            self._handshake()
            self._provision()
        except Exception as exc:                            # noqa: BLE001
            self.failure = f"{type(exc).__name__}: {exc}"
            self.log(f"    fake glasses stopped: {self.failure}")
        finally:
            self.finished.set()

    def _handshake(self):
        req = self.pipe.to_glasses.get(timeout=8)
        ch, tags, body, _ = A.dx_parse(req)
        assert (ch, tags.get("service"), tags.get("type")) == (A.CH_SETUP, 5, 1), tags
        f = A.pb_parse(body)
        phone_pub, phone_challenge = f[1][0], f[2][0]

        self.priv = ec.generate_private_key(ec.SECP256R1())
        nums = self.priv.public_key().public_numbers()
        self.pub_xy = nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")
        self.challenge = A.random_nonce()
        self.pipe.to_phone.put(A.request_encryption(self.pub_xy, self.challenge))

        en = self.pipe.to_glasses.get(timeout=8)
        ch, tags, body, _ = A.dx_parse(en)
        assert (ch, tags.get("type")) == (A.CH_SETUP_MIRROR, 2), tags
        f = A.pb_parse(body)
        phone_seed, phone_iv = f[2][0], f[3][0]

        self.seed = A.random_seed()
        self.iv = A.random_nonce()
        self.pipe.to_phone.put(A.enable_encryption(self.pub_xy, self.seed, self.iv, 0))

        peer = ec.EllipticCurvePublicNumbers(
            int.from_bytes(phone_pub[:32], "big"),
            int.from_bytes(phone_pub[32:], "big"),
            ec.SECP256R1()).public_key()
        shared = self.priv.exchange(ec.ECDH(), peer)
        self.tx = A.Direction(*A.derive_keys(shared, self.seed, phone_challenge, self.iv)[:3], 0)
        self.rx = A.Direction(*A.derive_keys(shared, self.challenge, phone_seed, phone_iv)[:3], 0)

        # no trust in the setup link: straight to EndLinkSetup
        plain = self.recv()
        ch, tags, _, _ = A.dx_parse(plain)
        assert tags.get("type") == 0x1000, f"expected EndLinkSetup, got {tags}"
        self.send(A.dx_message(A.CH_SETUP_MIRROR, [A.dx_tag(2, 0x1000, True)], b""))
        status = self.recv()
        ch, tags, _, _ = A.dx_parse(status)
        assert tags.get("error") == A.ST_SUCCESS, tags

    # -- svc36 ----------------------------------------------------------
    def _provision(self):
        while True:
            plain = self.recv(timeout=20)
            ch, tags, body, _ = A.dx_parse(plain)
            svc, mtype = tags.get("service"), tags.get("type")
            if svc == S.SVC_IDENTITY:
                self.identity_channel = ch            # named once, by the first message
            assert ch == self.identity_channel, f"svc36 on unexpected channel 0x{ch:04X}"
            self.seen.append((f"0x{mtype:04X}", len(body)))

            if mtype == S.ID_IDENTITY_REQUEST:
                self.send(A.dx_message(ch, [A.dx_tag(2, S.ID_IDENTITY_RESPONSE, True)],
                                       A.pb_bytes(1, CERT) + A.pb_bytes(2, SERIAL.encode())
                                       + A.pb_bytes(3, b"") + A.pb_bytes(5, b"")))
            elif mtype == S.ID_SKIP_CHALLENGE:
                self.send(A.dx_message(ch, [A.dx_tag(2, S.ID_SKIP_CHALLENGE_ACK, True)],
                                       A.pb_bytes(1, DEVICE_NONCE)))
            elif mtype == S.ID_START_CHANGE_OWNER_REQ:
                pending = MI.Receipt.decode(body)
                assert pending.info.get("who") == "server", pending.info
                device_pending = MI.Receipt(b"\x22" * 512,
                                            b'{"who":"device","cert":"' + b"x" * 8 + b'"}')
                self.send(A.dx_message(ch, [A.dx_tag(2, S.ID_START_CHANGE_OWNER_RESP, True)],
                                       device_pending.encode()))
            elif mtype == S.ID_FINISH_CHANGE_OWNER_REQ:
                final = MI.Receipt.decode(body)
                assert final.info.get("who") == "final", final.info
                self.send(A.dx_message(ch, [A.dx_tag(2, S.ID_FINISH_CHANGE_OWNER_RESP, True)], b""))
                return
            else:
                raise AssertionError(f"unexpected svc36 type 0x{mtype:04X}")

    def send(self, plain: bytes):
        self.pipe.to_phone.put(self.tx.seal(plain))

    def recv(self, timeout=8.0) -> bytes:
        return self.rx.open(self.pipe.to_glasses.get(timeout=timeout))


class FakeMeta:
    """Stands in for meta_identity: same two calls, receipts made up locally."""

    ar_token = "AR-token-for-tests"

    def __init__(self):
        self.calls: list[str] = []
        self.saw_pubkey = b""

    def pair_request(self, *, cert_der, serial, device_nonce, app_pubkey, secondary_cert=b""):
        self.calls.append("pair_request")
        assert cert_der == CERT, "cert must come from the glasses"
        assert serial == SERIAL
        assert device_nonce == DEVICE_NONCE, device_nonce
        assert len(app_pubkey) == 64
        self.saw_pubkey = app_pubkey
        return MI.Receipt(b"\x11" * 256, b'{"who":"server","serial":"' + SERIAL.encode() + b'"}')

    def pair(self, device_pending):
        self.calls.append("pair")
        assert len(device_pending.signature) == 512
        return MI.Receipt(b"\x33" * 256, b'{"who":"final","serial":"' + SERIAL.encode() + b'"}')


def main() -> int:
    ok = True
    owner = OwnerKey.generate()
    pipe = Pipe()
    fake = FakeGlassesSetup(pipe)
    fake.start()

    store = tempfile.mkdtemp(prefix="glasses-store-")
    transport = pipe.phone_transport()

    steps: list[str] = []
    try:
        result = P.run_provision(transport, owner, store=store,
                                backend=FakeMeta(), on_step=steps.append,
                                timeout=8, press_timeout=12)
        print("[1] handshake without trust + svc36 sequence   OK")
    except Exception as exc:                                # noqa: BLE001
        print(f"[1] provisioning FAILED: {type(exc).__name__}: {exc}")
        for line in steps[-8:]:
            print("    ", line)
        fake.join(timeout=2)
        return 1

    fake.join(timeout=5)

    # -- assertions ------------------------------------------------------
    if fake.failure:
        print(f"[2] peer-side assertions                       FAIL  {fake.failure}")
        ok = False
    else:
        expect = [f"0x{S.ID_IDENTITY_REQUEST:04X}", f"0x{S.ID_SKIP_CHALLENGE:04X}",
                  f"0x{S.ID_START_CHANGE_OWNER_REQ:04X}", f"0x{S.ID_FINISH_CHANGE_OWNER_REQ:04X}"]
        got = [m for m, _ in fake.seen]
        if got != expect:
            print(f"[2] svc36 order                                FAIL  {got} != {expect}")
            ok = False
        else:
            print("[2] svc36 order + channel named once           OK  "
                  + " -> ".join(got))

    bundle_path = os.path.join(store, "owner-export.json")
    if not os.path.exists(bundle_path):
        print("[3] owner-export.json                          FAIL  missing")
        return 1
    with open(bundle_path, encoding="utf-8") as f:
        blob = json.load(f)
    if blob.get("serial") != SERIAL or not blob.get("privateKeyPkcs8"):
        print(f"[3] owner-export.json                          FAIL  {sorted(blob)}")
        ok = False
    else:
        print("[3] owner-export.json written                  OK  "
              f"(serial {blob['serial']}, key {len(blob['privateKeyPkcs8'])} B b64)")

    # the file must feed straight into ownerkey.OwnerKey / gateway.py
    try:
        reloaded = OwnerKey.load(bundle_path)
        assert reloaded.public_xy == owner.public_xy, "round-tripped key differs"
        receipt = MI.load_receipt(store)
        assert receipt and receipt.info == {"who": "final", "serial": SERIAL}, receipt
        print("[4] bundle round-trip (key + receipt)          OK")
    except Exception as exc:                                # noqa: BLE001
        print(f"[4] bundle round-trip                          FAIL  {type(exc).__name__}: {exc}")
        ok = False

    print("ALL OK" if ok else "FAILURES ABOVE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
