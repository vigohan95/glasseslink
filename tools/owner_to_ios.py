"""visor-owner-<serial>.json -> owner-export.json, the shape the iOS app loads.

usage: python -P owner_to_ios.py <in.json> <out.json>
"""
import base64
import json
import sys

from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
    load_pem_private_key,
)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as handle:
        raw = json.load(handle)
    pem = base64.b64decode(raw["privateKeyPemB64"])
    key = load_pem_private_key(pem, password=None)
    pkcs8 = key.private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption())
    pub65 = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    if len(pub65) != 65 or pub65[0] != 0x04:
        raise SystemExit(f"unexpected public point: {len(pub65)} bytes, first {pub65[0]:#x}")
    out = {
        "serial": raw.get("serial"),
        "source": "visor-export",
        "publicKeyXy": base64.b64encode(pub65[1:]).decode(),
        "privateKeyPkcs8": base64.b64encode(pkcs8).decode(),
    }
    with open(dst, "w", encoding="utf-8") as handle:
        json.dump(out, handle, indent=2)
    print("serial   :", out["serial"])
    print("pubkey xy:", out["publicKeyXy"])
    print("pkcs8    :", len(pkcs8), "bytes")
    print("wrote", dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
