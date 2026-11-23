// OwnerKey.swift — the owner identity the glasses trust.
//
// The glasses do not care what device you are; they care that you hold the private
// key whose public half is registered as their owner, and that you can produce a
// NONEwithECDSA signature (raw r||s, low-s) over a 32-byte channel binding.
//
// So on iOS we keep a plain P-256 scalar in the Keychain and implement both
// operations with CryptoKit:
//   * key agreement  : P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
//   * signing        : P256.Signing.PrivateKey(rawRepresentation: scalar) -> DER -> raw
//
// A key produced by pi/provision.py (PKCS#8 PEM inside owner-export.json) can be
// imported directly: we walk the DER to find the 32-byte scalar.

import Foundation
import CryptoKit
import Security

struct OwnerMaterial {
    let scalar: Data                    // 32-byte P-256 private scalar
    let publicKeyXy: Data               // 64 bytes, x||y, no 0x04 prefix

    var publicKey65: Data { Data([0x04]) + publicKeyXy }

    // MARK: construction

    static func generate() -> OwnerMaterial {
        let key = P256.Signing.PrivateKey()
        return OwnerMaterial(scalar: key.rawRepresentation, publicKeyXy: xy(of: key.publicKey))
    }

    /// `x||y`, exactly 64 bytes, no 0x04 prefix.
    ///
    /// CryptoKit's `rawRepresentation` is *not* guaranteed to be padded: when the x or y
    /// coordinate happens to start with a zero byte it can come back 63 bytes long, and
    /// dropping the prefix naively then yields 62/63 bytes. The glasses hash this blob
    /// (svc36 field 1) and use it for ECDH, so a short buffer breaks trust in a way that
    /// looks like an unrelated signature error. The DER form always carries fixed-width
    /// integers, which is why it is preferred here.
    static func xy(of key: P256.Signing.PublicKey) -> Data {
        let der = key.derRepresentation
        if der.count >= 65, der[der.count - 65] == 0x04 {
            return Data(der.suffix(64))
        }
        var raw = Data(key.rawRepresentation)
        if raw.count == 65, raw[0] == 0x04 { raw = Data(raw.dropFirst()) }
        if raw.count < 64 {
            raw = Data(repeating: 0, count: 64 - raw.count) + raw
        }
        return Data(raw.suffix(64))
    }

    init(scalar: Data, publicKeyXy: Data? = nil) {
        precondition(scalar.count == 32, "P-256 scalar is 32 bytes")
        self.scalar = scalar
        if let xy = publicKeyXy, xy.count == 64 {
            self.publicKeyXy = xy
        } else {
            let k = try! P256.Signing.PrivateKey(rawRepresentation: scalar)
            self.publicKeyXy = OwnerMaterial.xy(of: k.publicKey)
        }
    }

    // MARK: crypto

    /// ECDH with the glasses' 64-byte x||y key. Returns the 32-byte x coordinate.
    func sharedSecret(peerPubkeyXy: Data) throws -> Data {
        precondition(peerPubkeyXy.count == 64, "peer key is x||y, 64 bytes")
        let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        let peer: P256.KeyAgreement.PublicKey
        do {
            peer = try P256.KeyAgreement.PublicKey(rawRepresentation: Data([0x04]) + peerPubkeyXy)
        } catch {
            throw LinkError.unexpected("glasses key is not a P-256 point (len=\(peerPubkeyXy.count), "
                + "head=\(peerPubkeyXy.prefix(4).hexShort)): \(error)")
        }
        let secret = try priv.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// ECDSA over an already-hashed 32-byte digest (NONEwithECDSA), returned as raw r||s.
    ///
    /// CryptoKit has no prehashed entry point: `P256.Signing.PrivateKey.signature(for:)`
    /// hashes its input again, and signing SHA-256(binding) is precisely what the glasses
    /// reject with 0x1044 INVALID_SIGNATURE. Security's `.ecdsaSignatureDigestX962SHA256`
    /// consumes the digest verbatim, which is the operation svc36 asks for.
    func signRaw(digest: Data) throws -> Data {
        precondition(digest.count == 32, "binding digest is SHA-256")
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(scalar as CFData, attrs as CFDictionary, &error) else {
            throw LinkError.io("SecKeyCreateWithData: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureDigestX962SHA256,
                                              digest as CFData, &error) else {
            throw LinkError.io("SecKeyCreateSignature: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let raw = Self.derToRaw(sig as Data)
        guard raw.count == 64 else { throw LinkError.io("signature is not 64 bytes") }
        return raw
    }

    // MARK: DER helpers

    static func derToRaw(_ der: Data) -> Data {
        // SEQUENCE { INTEGER r, INTEGER s } -> 32-byte r padded || 32-byte s padded
        let b = [UInt8](der)
        var i = 0
        func readLen(_ i: inout Int) -> Int {
            guard i < b.count else { return 0 }
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                len = 0
                for _ in 0 ..< n where i < b.count { len = len << 8 | Int(b[i]); i += 1 }
            }
            return len
        }
        guard i < b.count, b[i] == 0x30 else { return Data() }
        i += 1
        _ = readLen(&i)
        var parts: [Data] = []
        for _ in 0 ..< 2 {
            guard i < b.count, b[i] == 0x02 else { return Data() }
            i += 1
            let len = readLen(&i)
            guard i + len <= b.count else { return Data() }
            var v = Data(b[i ..< i + len])
            i += len
            while v.count > 32, v.first == 0 { v.removeFirst() }
            if v.count < 32 { v = Data(repeating: 0, count: 32 - v.count) + v }
            parts.append(v)
        }
        return parts[0] + parts[1]
    }

    /// Pulls the 32-byte scalar out of a PKCS#8 EC private key (what BoringSSL,
    /// python `cryptography` and Java all emit for P-256).
    static func scalar(fromPKCS8 der: Data) -> Data? {
        let b = [UInt8](der)
        var i = 0
        func readLen(_ i: inout Int) -> Int {
            guard i < b.count else { return 0 }
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                len = 0
                for _ in 0 ..< n where i < b.count { len = len << 8 | Int(b[i]); i += 1 }
            }
            return len
        }
        func walk(_ depth: Int) -> Data? {
            while i < b.count {
                let tag = b[i]; i += 1
                let len = readLen(&i)
                let end = min(i + len, b.count)
                if tag == 0x04, len == 32 {
                    return Data(b[i ..< end])            // the scalar itself
                }
                if tag == 0x04, depth < 4 {
                    // OCTET STRING wrapping the inner ECPrivateKey SEQUENCE
                    let inner = Data(b[i ..< end])
                    if let s = scalar(fromPKCS8: inner) { return s }
                }
                if tag == 0x30, depth < 4 {
                    let save = i
                    if let s = walk(depth + 1) { return s }
                    i = max(i, save)
                }
                i = end
            }
            return nil
        }
        return walk(0)
    }

    // MARK: storage

    static let keychainService = "dev.local.glasseslink.owner"
    static let keychainAccount = "owner-scalar"
    static let bundleName = "owner-export.json"

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var defaultURL: URL { documentsURL.appendingPathComponent(bundleName) }

    /// owner-export.json shape (shared with pi/provision.py and tools/adb_export_owner.py):
    /// { "serial": "...", "publicKeyXy": "<b64 64B>", "privateKeyPkcs8": "<b64 DER>",
    ///   "receipt": { "signature": "<b64>", "body": "<b64>" } }
    struct Bundle: Codable {
        struct Receipt: Codable { var signature: String; var body: String }
        var serial: String
        var publicKeyXy: String
        var privateKeyPkcs8: String
        var receipt: Receipt?
    }

    static func load(from url: URL) throws -> (OwnerMaterial, Bundle) {
        let data = try Data(contentsOf: url)
        let bundle = try JSONDecoder().decode(Bundle.self, from: data)
        guard let der = Data(base64Encoded: bundle.privateKeyPkcs8),
              let scalar = scalar(fromPKCS8: der) else {
            throw LinkError.unexpected("owner-export.json has no usable PKCS#8 key")
        }
        let xy = Data(base64Encoded: bundle.publicKeyXy) ?? Data()
        return (OwnerMaterial(scalar: scalar, publicKeyXy: xy.count == 64 ? xy : nil), bundle)
    }

    /// What the patched Visor writes to Downloads: {"serial","source":"visor-export","privateKeyPemB64"}.
    /// The PEM is base64 of a PKCS#8 "-----BEGIN PRIVATE KEY-----" block.
    struct VisorExport: Codable {
        var serial: String
        var source: String?
        var privateKeyPemB64: String
    }

    /// Accepts either our own owner-export.json or a visor-owner-<serial>.json straight
    /// off the phone, and always normalises to the owner-export.json shape on disk.
    static func loadAny(from url: URL) throws -> (OwnerMaterial, Bundle) {
        let data = try Data(contentsOf: url)
        if let bundle = try? JSONDecoder().decode(Bundle.self, from: data),
           let der = Data(base64Encoded: bundle.privateKeyPkcs8),
           let scalar = scalar(fromPKCS8: der) {
            let xy = Data(base64Encoded: bundle.publicKeyXy) ?? Data()
            return (OwnerMaterial(scalar: scalar, publicKeyXy: xy.count == 64 ? xy : nil), bundle)
        }
        let exported = try JSONDecoder().decode(VisorExport.self, from: data)
        guard let pemData = Data(base64Encoded: exported.privateKeyPemB64),
              let pem = String(data: pemData, encoding: .utf8) else {
            throw LinkError.unexpected("visor export has no readable privateKeyPemB64")
        }
        let body = pem.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body),
              let scalar = scalar(fromPKCS8: der) else {
            throw LinkError.unexpected("visor export PEM has no P-256 scalar")
        }
        let material = OwnerMaterial(scalar: scalar)
        let bundle = Bundle(serial: exported.serial,
                           publicKeyXy: material.publicKeyXy.base64EncodedString(),
                           privateKeyPkcs8: der.base64EncodedString(),
                           receipt: nil)
        return (material, bundle)
    }

    func save(bundle: Bundle) throws {
        let url = Self.defaultURL
        try JSONEncoder().encode(bundle).write(to: url, options: .atomic)
        try saveToKeychain()
    }

    func saveToKeychain() throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: Self.keychainAccount]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = scalar
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw LinkError.io("keychain add \(st)") }
    }

    static func loadFromKeychain() -> OwnerMaterial? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, d.count == 32 else { return nil }
        return OwnerMaterial(scalar: d)
    }
}
