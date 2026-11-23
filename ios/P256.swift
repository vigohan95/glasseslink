//
//  P256.swift
//  GlassesLink
//
//  P-256 ECDSA over an already-hashed digest (NONEwithECDSA), which is what svc36's
//  trust exchange asks for.
//
//  Why this exists instead of two lines of CryptoKit:
//   * `P256.Signing.PrivateKey.signature(for: Data)` is ECDSA-with-SHA256: it hashes the
//     input, so signing the 32-byte channel binding yields SHA-256(binding) and the
//     glasses answer 0x1044 INVALID_SIGNATURE.
//   * The `signature(for: SHA256Digest)` overload would sign the digest verbatim, but
//     `SHA256Digest` has no accessible initializer, so arbitrary bytes cannot be wrapped.
//   * Security's `.ecdsaSignatureDigestX962SHA256` does exactly what we want, but
//     `SecKeyCreateWithData` refuses every EC private-key container we can build when the
//     key did not come from the keychain (OSStatus -50) — verified for raw, PKCS#8, SEC1
//     and keychain import.
//
//  So the arithmetic lives here. Montgomery multiplication with 32-bit limbs keeps every
//  intermediate inside UInt64, and `tools/p256_ref.py` pins the expected r||s for a fixed
//  key, digest and nonce; `testSignsTheDigestVerbatim` compares against it byte for byte.
//

import Foundation

enum P256Field {
    /// Little-endian 32-bit limbs, eight of them: 256 bits.
    typealias Word = [UInt32]

    static let p: Word = [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000,
                          0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]
    static let n: Word = [0xFC632551, 0xF3B9CAC2, 0xA7179E84, 0xBCE6FAAD,
                          0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]
    static let r2p: Word = [0x00000003, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFB,
                            0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFD, 0x00000004]
    static let r2n: Word = [0xBE79EEA2, 0x83244C95, 0x49BD6FA6, 0x4699799C,
                            0x2B6BEC59, 0x2845B239, 0xF3D95620, 0x66E12D94]
    static let n0p: UInt32 = 0x0000_0001
    static let n0n: UInt32 = 0xEE00_BC4F

    static let zero: Word = [UInt32](repeating: 0, count: 8)
    static let one: Word = [1, 0, 0, 0, 0, 0, 0, 0]

    static let gx: Word = [0xD898C296, 0xF4A13945, 0x2DEB33A0, 0x77037D81,
                           0x63A440F2, 0xF8BCE6E5, 0xE12C4247, 0x6B17D1F2]
    static let gy: Word = [0x37BF51F5, 0xCBB64068, 0x6B315ECE, 0x2BCE3357,
                           0x7C0F9E16, 0x8EE7EB4A, 0xFE1A7F9B, 0x4FE342E2]
    static let a: Word = [0xFFFFFFFC, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000,
                          0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]

    // MARK: basic limb arithmetic

    static func cmp(_ x: Word, _ y: Word) -> Int {
        var i = 7
        while i >= 0 {
            if x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func addRaw(_ x: Word, _ y: Word) -> (Word, UInt32) {
        var out = zero
        var carry: UInt64 = 0
        for i in 0 ..< 8 {
            let s = UInt64(x[i]) + UInt64(y[i]) + carry
            out[i] = UInt32(s & 0xFFFF_FFFF)
            carry = s >> 32
        }
        return (out, UInt32(carry))
    }

    static func subRaw(_ x: Word, _ y: Word) -> (Word, UInt32) {
        var out = zero
        var borrow: Int64 = 0
        for i in 0 ..< 8 {
            let s = Int64(x[i]) - Int64(y[i]) - borrow
            if s < 0 {
                out[i] = UInt32((s + (1 << 32)) & 0xFFFF_FFFF)
                borrow = 1
            } else {
                out[i] = UInt32(s & 0xFFFF_FFFF)
                borrow = 0
            }
        }
        return (out, UInt32(borrow))
    }

    /// a + b mod m, both already reduced below m.
    static func addMod(_ x: Word, _ y: Word, _ m: Word) -> Word {
        let (s, carry) = addRaw(x, y)
        if carry != 0 || cmp(s, m) >= 0 { return subRaw(s, m).0 }
        return s
    }

    static func subMod(_ x: Word, _ y: Word, _ m: Word) -> Word {
        let (d, borrow) = subRaw(x, y)
        if borrow != 0 { return addRaw(d, m).0 }
        return d
    }

    /// Montgomery product (CIOS), operands and result in Montgomery form.
    static func montMul(_ x: Word, _ y: Word, _ m: Word, _ n0: UInt32) -> Word {
        var t = [UInt64](repeating: 0, count: 10)
        for i in 0 ..< 8 {
            // t += x[i] * y
            var carry: UInt64 = 0
            let xi = UInt64(x[i])
            for j in 0 ..< 8 {
                let s = t[j] + xi * UInt64(y[j]) + carry
                t[j] = s & 0xFFFF_FFFF
                carry = s >> 32
            }
            var k = 8
            while carry != 0 {
                let s = t[k] + carry
                t[k] = s & 0xFFFF_FFFF
                carry = s >> 32
                k += 1
            }
            // u = t[0] * n0 mod 2^32 ; t += u * m ; t >>= 32
            let u = (t[0] * UInt64(n0)) & 0xFFFF_FFFF
            carry = 0
            for j in 0 ..< 8 {
                let s = t[j] + u * UInt64(m[j]) + carry
                t[j] = s & 0xFFFF_FFFF
                carry = s >> 32
            }
            k = 8
            while carry != 0 {
                let s = t[k] + carry
                t[k] = s & 0xFFFF_FFFF
                carry = s >> 32
                k += 1
            }
            for j in 0 ..< 9 { t[j] = t[j + 1] }
            t[9] = 0
        }
        var out = zero
        for i in 0 ..< 8 { out[i] = UInt32(t[i] & 0xFFFF_FFFF) }
        if t[8] != 0 || cmp(out, m) >= 0 { out = subRaw(out, m).0 }
        return out
    }

    static func toMont(_ x: Word, _ m: Word, _ n0: UInt32, _ r2: Word) -> Word {
        montMul(x, r2, m, n0)
    }

    static func fromMont(_ x: Word, _ m: Word, _ n0: UInt32) -> Word {
        montMul(x, one, m, n0)
    }

    static func mulModP(_ x: Word, _ y: Word) -> Word { montMul(x, y, p, n0p) }
    static func mulModN(_ x: Word, _ y: Word) -> Word { montMul(x, y, n, n0n) }

    static func invP(_ x: Word) -> Word { pow(x, subRaw(p, [2, 0, 0, 0, 0, 0, 0, 0]).0, p, n0p) }
    static func invN(_ x: Word) -> Word { pow(x, subRaw(n, [2, 0, 0, 0, 0, 0, 0, 0]).0, n, n0n) }

    /// Square-and-multiply in Montgomery form; `x` and the result are Montgomery reps.
    static func pow(_ x: Word, _ e: Word, _ m: Word, _ n0: UInt32) -> Word {
        var result = toMont(one, m, n0, m == p ? r2p : r2n)
        var base = x
        var i = 0
        while i < 256 {
            if (e[i / 32] >> UInt32(i % 32)) & 1 == 1 {
                result = montMul(result, base, m, n0)
            }
            base = montMul(base, base, m, n0)
            i += 1
        }
        return result
    }

    // MARK: byte conversion

    static func words(_ data: Data) -> Word {
        var out = zero
        let bytes = [UInt8](data)
        for i in 0 ..< min(32, bytes.count) {
            let idx = 8 - 1 - i / 4
            out[idx] |= UInt32(bytes[bytes.count - 1 - i]) << UInt32((i % 4) * 8)
        }
        return out
    }

    static func data(_ x: Word) -> Data {
        var out = Data(capacity: 32)
        var i = 7
        while i >= 0 {
            let w = x[i]
            out.append(UInt8((w >> 24) & 0xFF))
            out.append(UInt8((w >> 16) & 0xFF))
            out.append(UInt8((w >> 8) & 0xFF))
            out.append(UInt8(w & 0xFF))
            i -= 1
        }
        return out
    }
}

enum P256ECDSA {
    struct Point {
        var x: P256Field.Word
        var y: P256Field.Word
        var infinity: Bool
    }

    static func add(_ p1: Point, _ p2: Point) -> Point {
        typealias F = P256Field
        if p1.infinity { return p2 }
        if p2.infinity { return p1 }
        if F.cmp(p1.x, p2.x) == 0 {
            if F.cmp(p1.y, p2.y) != 0 { return Point(x: F.zero, y: F.zero, infinity: true) }
            return double(p1)
        }
        let dy = F.subMod(p2.y, p1.y, F.p)
        let dx = F.subMod(p2.x, p1.x, F.p)
        let lam = F.mulModP(dy, F.invP(dx))
        let x3 = F.subMod(F.subMod(F.mulModP(lam, lam), p1.x, F.p), p2.x, F.p)
        let y3 = F.subMod(F.mulModP(lam, F.subMod(p1.x, x3, F.p)), p1.y, F.p)
        return Point(x: x3, y: y3, infinity: false)
    }

    static func double(_ p1: Point) -> Point {
        typealias F = P256Field
        if p1.infinity { return p1 }
        // 3 and A must enter the Montgomery domain like every other operand: mixing a
        // plain limb vector with a Montgomery one is off by a factor of R.
        let three = F.toMont([3, 0, 0, 0, 0, 0, 0, 0], F.p, F.n0p, F.r2p)
        let aMont = F.toMont(F.a, F.p, F.n0p, F.r2p)
        let num = F.addMod(F.mulModP(three, F.mulModP(p1.x, p1.x)), aMont, F.p)
        let den = F.invP(F.addMod(p1.y, p1.y, F.p))
        let lam = F.mulModP(num, den)
        let x3 = F.subMod(F.mulModP(lam, lam), F.addMod(p1.x, p1.x, F.p), F.p)
        let y3 = F.subMod(F.mulModP(lam, F.subMod(p1.x, x3, F.p)), p1.y, F.p)
        return Point(x: x3, y: y3, infinity: false)
    }

    /// k * G, with all coordinates in Montgomery form.
    static func mulG(_ k: P256Field.Word) -> Point {
        typealias F = P256Field
        var result = Point(x: F.zero, y: F.zero, infinity: true)
        var addend = Point(x: F.toMont(F.gx, F.p, F.n0p, F.r2p),
                           y: F.toMont(F.gy, F.p, F.n0p, F.r2p),
                           infinity: false)
        var i = 0
        while i < 256 {
            if (k[i / 32] >> UInt32(i % 32)) & 1 == 1 { result = add(result, addend) }
            addend = double(addend)
            i += 1
        }
        return result
    }

    /// k * P for an arbitrary point, coordinates in Montgomery form.
    static func mul(_ k: P256Field.Word, _ point: Point) -> Point {
        var result = Point(x: P256Field.zero, y: P256Field.zero, infinity: true)
        var addend = point
        var i = 0
        while i < 256 {
            if (k[i / 32] >> UInt32(i % 32)) & 1 == 1 { result = add(result, addend) }
            addend = double(addend)
            i += 1
        }
        return result
    }

    /// NONEwithECDSA verification: `digest` is used verbatim, `publicKeyXy` is 64 bytes.
    static func verify(digest: Data, signature: Data, publicKeyXy: Data) -> Bool {
        typealias F = P256Field
        guard digest.count == 32, signature.count == 64, publicKeyXy.count == 64 else { return false }
        let r = F.words(signature.prefix(32))
        let s = F.words(signature.suffix(32))
        if r.allSatisfy({ $0 == 0 }) || s.allSatisfy({ $0 == 0 }) { return false }
        if F.cmp(r, F.n) >= 0 || F.cmp(s, F.n) >= 0 { return false }

        let w = F.invN(F.toMont(s, F.n, F.n0n, F.r2n))
        let z = F.toMont(F.words(digest), F.n, F.n0n, F.r2n)
        let u1 = F.fromMont(F.mulModN(z, w), F.n, F.n0n)
        let u2 = F.fromMont(F.mulModN(F.toMont(r, F.n, F.n0n, F.r2n), w), F.n, F.n0n)

        let q = Point(x: F.toMont(F.words(publicKeyXy.prefix(32)), F.p, F.n0p, F.r2p),
                      y: F.toMont(F.words(publicKeyXy.suffix(32)), F.p, F.n0p, F.r2p),
                      infinity: false)
        let point = add(mulG(u1), mul(u2, q))
        if point.infinity { return false }
        var x = F.fromMont(point.x, F.p, F.n0p)
        if F.cmp(x, F.n) >= 0 { x = F.subRaw(x, F.n).0 }
        return F.cmp(x, r) == 0
    }

    /// ECDSA over `digest` verbatim, returned as raw r||s with s in the low half.
    static func sign(digest: Data, scalar: Data, nonce: Data) throws -> Data {
        typealias F = P256Field
        guard digest.count == 32, scalar.count == 32, nonce.count == 32 else {
            throw LinkError.io("P-256 needs 32-byte digest, scalar and nonce")
        }
        let k = F.words(nonce)
        let d = F.toMont(F.words(scalar), F.n, F.n0n, F.r2n)
        let rPoint = mulG(k)
        guard !rPoint.infinity else { throw LinkError.io("nonce produced the point at infinity") }

        var r = F.fromMont(rPoint.x, F.p, F.n0p)
        if F.cmp(r, F.n) >= 0 { r = F.subRaw(r, F.n).0 }
        if r.allSatisfy({ $0 == 0 }) { throw LinkError.io("r is zero") }

        // s = k^-1 (z + r d) mod n, everything in Montgomery form
        let z = F.toMont(F.words(digest), F.n, F.n0n, F.r2n)
        let rMont = F.toMont(r, F.n, F.n0n, F.r2n)
        let t = F.addMod(z, F.mulModN(rMont, d), F.n)
        var s = F.mulModN(F.invN(F.toMont(k, F.n, F.n0n, F.r2n)), t)
        // low-s: the glasses normalise, so we must too
        let sPlain = F.fromMont(s, F.n, F.n0n)
        if sPlain[7] & 0x8000_0000 != 0 {
            s = F.toMont(F.subRaw(F.n, sPlain).0, F.n, F.n0n, F.r2n)
        }
        return F.data(r) + F.data(F.fromMont(s, F.n, F.n0n))
    }
}
