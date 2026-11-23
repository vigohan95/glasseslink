"""The owner key: prove to the glasses that this box is the phone.

The private key is the one Meta's app created when the glasses were first paired.
It is exported once from an Android phone (tools/adb_export_owner.py) and from then
on lives here. Nothing in this file talks to Meta.

Signing rules (identity-and-trust page):
  * sign the 32-byte channel binding with NONEwithECDSA — no extra hashing;
  * fold s to the low half of the group order;
  * write r and s as 32 bytes each, big endian;
  * field 1 of the trust message is SHA-256 of the 64-byte public key (x || y).
"""
from __future__ import annotations

import base64
import hashlib
import json
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


class OwnerKey:
    def __init__(self, private_key: ec.EllipticCurvePrivateKey):
        self.key = private_key
        numbers = private_key.public_key().public_numbers()
        self.public_xy = (numbers.x.to_bytes(32, "big") + numbers.y.to_bytes(32, "big"))
        self.public_id = hashlib.sha256(self.public_xy).digest()

    # ---- loading ------------------------------------------------------
    @classmethod
    def load(cls, path: str) -> "OwnerKey":
        with open(path, "rb") as fh:
            blob = fh.read()
        if blob.lstrip().startswith(b"{"):
            return cls._from_json(json.loads(blob.decode()))
        if b"-----BEGIN" in blob:
            return cls(serialization.load_pem_private_key(blob, password=None))
        return cls(serialization.load_der_private_key(blob, password=None))

    @classmethod
    def _from_json(cls, doc: dict) -> "OwnerKey":
        for key in ("privateKeyPkcs8", "privateKey", "pkcs8"):
            if key in doc:
                der = base64.b64decode(doc[key])
                return cls(serialization.load_der_private_key(der, password=None))
        raise ValueError("owner-export.json has no privateKeyPkcs8")

    @classmethod
    def generate(cls) -> "OwnerKey":
        """Only useful for tests: the glasses will not know this key."""
        return cls(ec.generate_private_key(ec.SECP256R1()))

    # ---- crypto -------------------------------------------------------
    def ecdh(self, peer_xy: bytes) -> bytes:
        """Shared secret x coordinate, 32 bytes."""
        peer = ec.EllipticCurvePublicNumbers(
            int.from_bytes(peer_xy[:32], "big"),
            int.from_bytes(peer_xy[32:], "big"),
            ec.SECP256R1(),
        ).public_key()
        return self.key.exchange(ec.ECDH(), peer)

    def sign_digest_raw(self, digest: bytes) -> bytes:
        """NONEwithECDSA over a 32-byte digest, low s, r || s, 64 bytes."""
        der = self.key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
        r, s = decode_dss_signature(der)
        if s > P256_ORDER // 2:
            s = P256_ORDER - s
        return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def find_owner(path_hint: str | None = None) -> OwnerKey:
    """Look in the obvious places, so `gateway.py` needs no arguments."""
    here = os.path.dirname(os.path.abspath(__file__))
    store = os.environ.get("GLASSES_STORE", "identity")
    candidates = [path_hint] if path_hint else []
    candidates += [
        os.path.join(store, "owner-export.json"),                 # provision.py default
        os.path.join(here, store, "owner-export.json"),
        os.path.join(here, "owner-export.json"),
        os.path.join(here, "..", "owner-export", "owner-export.json"),
        os.path.join(here, "..", "owner-bundle.json"),
        os.path.expanduser("~/owner-export.json"),
        "/etc/glasses/owner-export.json",
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return OwnerKey.load(c)
    raise FileNotFoundError(
        "no owner key found — run `python -P provision.py --address <glasses> "
        "--store identity` once (it writes identity/owner-export.json), or drop an "
        "exported owner-export.json next to this file")
