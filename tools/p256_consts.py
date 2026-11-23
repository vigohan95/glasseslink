"""Emit the Montgomery constants the Swift signer needs, plus the pinned vector."""

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
A = P - 3
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5


def limbs32(x):
    return ", ".join(f"0x{(x >> (32 * i)) & 0xFFFFFFFF:08X}" for i in range(8))


def n0inv(m):
    # -m^-1 mod 2^32
    inv = 1
    for _ in range(5):
        inv = (inv * (2 - m * inv)) & 0xFFFFFFFF
    return (-inv) & 0xFFFFFFFF


print("// p")
print(limbs32(P))
print("// n")
print(limbs32(N))
print("// R2 mod p")
print(limbs32((1 << 512) % P))
print("// R2 mod n")
print(limbs32((1 << 512) % N))
print(f"// n0inv p = 0x{n0inv(P):08X}  n0inv n = 0x{n0inv(N):08X}")
print("// Gx", limbs32(GX))
print("// Gy", limbs32(GY))
print("// A", limbs32(A))
