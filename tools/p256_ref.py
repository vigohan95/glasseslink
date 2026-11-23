"""Reference implementation of the P-256 ECDSA step the glasses require.

The glasses verify svc36's signature with NONEwithECDSA: the 32-byte channel
binding *is* the digest, so no hashing may happen on either side. CryptoKit
cannot express that (`signature(for:)` hashes its input), and Security refuses
to import a standalone EC private key on the simulator, so the iOS client signs
with its own arithmetic. This file is the executable specification for that
arithmetic: it produces a signature for a fixed key, digest and nonce, and
checks it with `cryptography`'s prehashed verifier. The same numbers are pinned
in ios/Tests/ProtocolTests.swift.

Usage: python -P p256_ref.py
"""

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5


def inv(a, m):
    return pow(a, m - 2, m)


def add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1 + A) * inv(2 * y1 % P, P) % P
    else:
        lam = (y2 - y1) * inv((x2 - x1) % P, P) % P
    x3 = (lam * lam - x1 - x2) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def mul(k, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = add(result, addend)
        addend = add(addend, addend)
        k >>= 1
    return result


def sign(d, digest: bytes, k: int):
    """ECDSA over `digest` verbatim (NONEwithECDSA), returned as r||s (64 bytes)."""
    assert len(digest) == 32
    z = int.from_bytes(digest, "big")
    r_point = mul(k % N, (GX, GY))
    r = r_point[0] % N
    s = (inv(k % N, N) * (z + r * d)) % N
    # ECDSA requires the low half of s so both sides agree on the encoding.
    if s > N // 2:
        s = N - s
    return r, s


def main():
    d = 0x0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829
    digest = bytes(range(32))  # what channelBinding() would hand us
    k = 0x1112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F30

    r, s = sign(d, digest, k)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    print("r =", f"{r:064x}")
    print("s =", f"{s:064x}")
    print("r||s =", raw.hex())

    priv = ec.derive_private_key(d, ec.SECP256R1())
    pub = priv.public_key()
    der = utils.encode_dss_signature(r, s)
    pub.verify(der, digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
    print("cryptography accepts it as a NONEwithECDSA signature over the binding")

    xy = pub.public_numbers()
    print("publicKeyXy =", f"{xy.x:064x}{xy.y:064x}")
    print("scalar =", f"{d:064x}")


if __name__ == "__main__":
    main()
