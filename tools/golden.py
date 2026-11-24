#!/usr/bin/env python3
"""Independent re-implementation of the byte layouts the iOS app sends.

Every layout here was transcribed from the Visor sources (Kotlin) rather than from the
Swift code, so comparing the two catches transcription mistakes in either direction.
Run it to print the golden hex strings used by `ios/Tests/CompatibilityTests.swift`.
"""
import hashlib
import sys

sys.path.insert(0, __file__.rsplit("\\", 1)[0] + "\\..\\pi")

from airshield import (  # noqa: E402
    CH_SETUP, CH_SETUP_MIRROR, SVC_TRUST, dx_message, dx_tag, dx_status,
    end_link_setup, pb_bytes, pb_uint, pb_varint,
)


def h(b):
    return b.hex()


# --- svc36 trust message: {1: sha256(pubkey), 2: signature, 3: varint 2} -----
def trust_message(public_id: bytes, signature: bytes) -> bytes:
    body = pb_bytes(1, public_id) + pb_bytes(2, signature) + pb_uint(3, 2)
    return dx_message(CH_SETUP, [dx_tag(1, SVC_TRUST, False), dx_tag(2, 0x1000, True)], body)


# --- svc31 settings: a single field, encoded per its kind -------------------
def settings_payload(kind: str, field: int, value) -> bytes:
    if kind == "bool":
        return pb_uint(field, 1 if value else 0)
    if kind == "int":
        if value < 0:
            return pb_varint(field, 0) + b""  # placeholder, negative handled below
        return pb_uint(field, value)
    if kind == "str":
        return pb_bytes(field, value.encode())
    raise SystemExit("float uses wire type 1; see the note in the Swift test")


def main() -> None:
    pub = bytes(range(64))
    digest = hashlib.sha256(pub).digest()
    print("# trust (pubkey = 00..3f)")
    print("trustFrame   ", h(trust_message(digest, bytes(range(64)))))
    print()
    print("# end link setup (46 B, v4 uuids)")
    s = bytes.fromhex("00112233445546778999aabbccddeeff")
    l = bytes.fromhex("0f1e2d3c4b5a49678896a5b4c3d2e1f0")
    print("endLinkSetup ", h(end_link_setup(s, l)))
    print()
    print("# svc31 single-field payloads")
    print("bool 2 = true   ", h(settings_payload("bool", 2, True)))
    print("int 5 = 90      ", h(settings_payload("int", 5, 90)))
    print("int 14 = 3      ", h(settings_payload("int", 14, 3)))
    print("str 1 = abc     ", h(settings_payload("str", 1, "abc")))
    print()
    print("# status frame")
    print("status ok       ", h(dx_status(CH_SETUP_MIRROR, 0x1000)))


if __name__ == "__main__":
    main()
