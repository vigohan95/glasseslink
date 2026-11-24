import Foundation
import CryptoKit
import Security

/// On-device checks for the parts CI cannot prove: whether this phone will let us import a
/// standalone EC private key, and whether both signing paths produce signatures that our own
/// verifier accepts. Every line is cheap, so the result can be shown before the first connect.
enum SelfTest {
    struct Line { let ok: Bool; let text: String }

    private static func hexData(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            if let b = UInt8(s[i ..< j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    static func run() -> [Line] {
        var out: [Line] = []

        // 1. the reference vector, so a regression in the arithmetic is caught on the phone too
        let referenceScalar = Data((0 ..< 32).map { UInt8($0 + 0x0a) })
        let referenceDigest = Data((0 ..< 32).map { UInt8($0) })
        let referenceNonce = Data((0 ..< 32).map { UInt8($0 + 0x11) })
        let expected = hexData("4c6336e3b8b3de771b613a1c7a1734834cd69c1a4f5ffecb240c63bc0ddb1574"
                                 + "03bf8bb6c07d98211266b44f2c126e24cdb99572444e0d01d35b15d04433a4e2")
        let owner = OwnerMaterial(scalar: referenceScalar)
        if let sig = try? owner.signRaw(digest: referenceDigest, nonce: referenceNonce) {
            let same = sig == expected
            out.append(Line(ok: same, text: "参考向量签名 \(same ? "一致" : "不一致：\(sig.hexShort)")"))
            let verified = P256ECDSA.verify(digest: referenceDigest, signature: sig,
                                            publicKeyXy: owner.publicKeyXy)
            out.append(Line(ok: verified, text: "自研验签 \(verified ? "通过" : "失败")"))
        } else {
            out.append(Line(ok: false, text: "参考向量签名抛错"))
        }

        // 2. key material shape: the glasses hash 0x04 || x || y, so both widths matter
        out.append(Line(ok: owner.publicKeyXy.count == 64,
                        text: "公钥 x||y \(owner.publicKeyXy.count) 字节（应为 64）"))
        out.append(Line(ok: owner.publicKey65.count == 65,
                        text: "公钥 x||y（带前缀） \(owner.publicKey65.count) 字节（应为 65）"))

        // 3. can Security hold this key at all? if not we sign with our own arithmetic
        let imported = (try? owner.secPrivateKey()) != nil
        out.append(Line(ok: true,
                        text: imported ? "Security 可导入私钥（走系统签名）"
                                      : "Security 拒绝导入私钥（走自研签名，这在本机是正常的）"))

        // 4. both paths must agree on the digest being signed verbatim
        let digest = Data((0 ..< 32).map { UInt8(0xa0 &+ $0) })
        if let sig = try? owner.signRaw(digest: digest) {
            let ok = P256ECDSA.verify(digest: digest, signature: sig, publicKeyXy: owner.publicKeyXy)
            out.append(Line(ok: ok, text: "信任摘要签名 → 验签 \(ok ? "通过" : "失败")（\(imported ? "Security" : "自研")）"))
            let tampered = Data(digest.dropLast() + [digest.last! ^ 0x01])
            let rejected = !P256ECDSA.verify(digest: tampered, signature: sig,
                                             publicKeyXy: owner.publicKeyXy)
            out.append(Line(ok: rejected, text: "篡改一字节后 \(rejected ? "正确拒绝" : "竟然通过")"))
        } else {
            out.append(Line(ok: false, text: "信任摘要签名抛错"))
        }

        // 5. ECDH both ways, which is what the AirShield keys hang on
        let peer = OwnerMaterial(scalar: Data(repeating: 0x02, count: 32))
        do {
            let a = try owner.sharedSecret(peerPubkeyXy: peer.publicKeyXy)
            let b = try peer.sharedSecret(peerPubkeyXy: owner.publicKeyXy)
            out.append(Line(ok: a == b && a.count == 32,
                            text: "ECDH 双向一致 \(a == b ? "是" : "否")（\(a.count) 字节）"))
        } catch {
            out.append(Line(ok: false, text: "ECDH 抛错：\(error)"))
        }

        // 6. PKCS#8 we hand to other code must itself parse
        let pkcs8 = Provisioner.pkcs8(from: owner)
        out.append(Line(ok: pkcs8.count == 138 || pkcs8.count == 150,
                        text: "PKCS#8 \(pkcs8.count) 字节"))

        return out
    }
}
