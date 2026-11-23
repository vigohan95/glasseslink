"""Mirror of ios/P256.swift's limb arithmetic, to separate algorithm bugs from Swift bugs.

Builds the same 8x32-bit limb Montgomery code and signs with the pinned d/digest/k.
If this prints the reference r||s, the algorithm is right and the bug is in the Swift
transcription; if it does not, the approach itself has a defect.
"""

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
A = P - 3
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
M32 = 0xFFFFFFFF


def limbs(x):
    return [(x >> (32 * i)) & M32 for i in range(8)]


def toint(w):
    return sum(v << (32 * i) for i, v in enumerate(w))


def cmp(x, y):
    for i in range(7, -1, -1):
        if x[i] != y[i]:
            return -1 if x[i] < y[i] else 1
    return 0


def sub_raw(x, y):
    out = [0] * 8
    borrow = 0
    for i in range(8):
        s = x[i] - y[i] - borrow
        if s < 0:
            out[i] = (s + (1 << 32)) & M32
            borrow = 1
        else:
            out[i] = s & M32
            borrow = 0
    return out, borrow


def add_raw(x, y):
    out = [0] * 8
    carry = 0
    for i in range(8):
        s = x[i] + y[i] + carry
        out[i] = s & M32
        carry = s >> 32
    return out, carry


def mont_mul(x, y, m, n0):
    t = [0] * 10
    for i in range(8):
        carry = 0
        xi = x[i]
        for j in range(8):
            s = t[j] + xi * y[j] + carry
            t[j] = s & M32
            carry = s >> 32
        k = 8
        while carry:
            s = t[k] + carry
            t[k] = s & M32
            carry = s >> 32
            k += 1
        u = (t[0] * n0) & M32
        carry = 0
        for j in range(8):
            s = t[j] + u * m[j] + carry
            t[j] = s & M32
            carry = s >> 32
        k = 8
        while carry:
            s = t[k] + carry
            t[k] = s & M32
            carry = s >> 32
            k += 1
        for j in range(9):
            t[j] = t[j + 1]
        t[9] = 0
    out = t[:8]
    if t[8] != 0 or cmp(out, m) >= 0:
        out, _ = sub_raw(out, m)
    return out


def to_mont(x, m, n0, r2):
    return mont_mul(x, r2, m, n0)


def from_mont(x, m, n0):
    return mont_mul(x, [1, 0, 0, 0, 0, 0, 0, 0], m, n0)


def powm(x, e, m, n0, r2):
    result = to_mont([1, 0, 0, 0, 0, 0, 0, 0], m, n0, r2)
    base = x
    for i in range(256):
        if (e[i // 32] >> (i % 32)) & 1:
            result = mont_mul(result, base, m, n0)
        base = mont_mul(base, base, m, n0)
    return result


Pw, Nw = limbs(P), limbs(N)
R2Pw, R2Nw = limbs((1 << 512) % P), limbs((1 << 512) % N)
N0P, N0N = 1, 0xEE00BC4F


def add_mod(x, y, m):
    s, carry = add_raw(x, y)
    if carry or cmp(s, m) >= 0:
        return sub_raw(s, m)[0]
    return s


def sub_mod(x, y, m):
    d, borrow = sub_raw(x, y)
    if borrow:
        return add_raw(d, m)[0]
    return d


def mul_p(x, y):
    return mont_mul(x, y, Pw, N0P)


def mul_n(x, y):
    return mont_mul(x, y, Nw, N0N)


def inv_p(x):
    return powm(x, sub_raw(Pw, [2] + [0] * 7)[0], Pw, N0P, R2Pw)


def inv_n(x):
    return powm(x, sub_raw(Nw, [2] + [0] * 7)[0], Nw, N0N, R2Nw)


def point_double(p):
    if p is None:
        return None
    three = to_mont(limbs(3), Pw, N0P, R2Pw)
    am = to_mont(limbs(A), Pw, N0P, R2Pw)
    num = add_mod(mul_p(three, mul_p(p[0], p[0])), am, Pw)
    den = inv_p(add_mod(p[1], p[1], Pw))
    lam = mul_p(num, den)
    x3 = sub_mod(mul_p(lam, lam), add_mod(p[0], p[0], Pw), Pw)
    y3 = sub_mod(mul_p(lam, sub_mod(p[0], x3, Pw)), p[1], Pw)
    return (x3, y3)


def point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    if cmp(p1[0], p2[0]) == 0:
        if cmp(p1[1], p2[1]) != 0:
            return None
        return point_double(p1)
    lam = mul_p(sub_mod(p2[1], p1[1], Pw), inv_p(sub_mod(p2[0], p1[0], Pw)))
    x3 = sub_mod(sub_mod(mul_p(lam, lam), p1[0], Pw), p2[0], Pw)
    y3 = sub_mod(mul_p(lam, sub_mod(p1[0], x3, Pw)), p1[1], Pw)
    return (x3, y3)


def mul_g(k):
    result = None
    addend = (to_mont(limbs(GX), Pw, N0P, R2Pw), to_mont(limbs(GY), Pw, N0P, R2Pw))
    for i in range(256):
        if (k[i // 32] >> (i % 32)) & 1:
            result = point_add(result, addend)
        addend = point_double(addend)
    return result


def main():
    d = 0x0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829
    digest = bytes(range(32))
    k = 0x1112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F30

    kn = limbs(k)
    rp = mul_g(kn)
    r = from_mont(rp[0], Pw, N0P)
    if cmp(r, Nw) >= 0:
        r = sub_raw(r, Nw)[0]

    z = to_mont(limbs(int.from_bytes(digest, "big")), Nw, N0N, R2Nw)
    dm = to_mont(limbs(d), Nw, N0N, R2Nw)
    rm = to_mont(r, Nw, N0N, R2Nw)
    t = add_mod(z, mul_n(rm, dm), Nw)
    s = mul_n(inv_n(to_mont(kn, Nw, N0N, R2Nw)), t)
    sp = from_mont(s, Nw, N0N)
    if sp[7] >> 31:
        s = to_mont(sub_raw(Nw, sp)[0], Nw, N0N, R2Nw)

    print("r =", f"{toint(r):064x}")
    print("s =", f"{toint(from_mont(s, Nw, N0N)):064x}")
    print("R2p ok:", (1 << 512) % P == toint(R2Pw))


if __name__ == "__main__":
    main()
