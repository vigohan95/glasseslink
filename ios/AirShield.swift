// AirShield.swift — byte-faithful Swift port of the Meta Ray-Ban link layer.
//
// Source of truth: the public protocol docs (visor.macedonga.com/protocol) and the
// Python reference in this repo (pi/airshield.py), which is covered by 12 byte-level
// selftests. Keeping the two in lockstep matters: every constant below has a test.
//
// iOS reality check:
//   LE L2CAP CoC : available  (CBPeripheral.openL2CAPChannel)  -> control link OK
//   RFCOMM       : unavailable to third-party apps
//   Wi-Fi Direct : unavailable -> media runs over the encrypted L2CAP link
//   AES-256-CBC  : CommonCrypto (CryptoKit has no CBC)
//   P-256/HKDF   : CryptoKit

import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - bytes

@inline(__always) func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
@inline(__always) func le32(_ v: UInt32) -> Data {
    Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
}
@inline(__always) func be32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var hexShort: String { let h = hex; return h.count > 32 ? String(h.prefix(32)) + "…" : h }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }

    /// RFC 4122 v4 UUID bytes. The glasses silently answer service_not_found for
    /// anything that is not a well-formed v4 (see endLinkSetup).
    static func uuid4() -> Data {
        var b = [UInt8](Data.random(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return Data(b)
    }

    func u16be(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
}

final class ByteReader {
    let bytes: [UInt8]
    var i = 0
    init(_ d: Data) { bytes = [UInt8](d) }
    init(_ b: [UInt8]) { bytes = b }
    var remaining: Int { bytes.count - i }
    func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw LinkError.shortBuffer }
        let out = Data(bytes[i ..< i + n]); i += n; return out
    }
    func peek(_ k: Int = 1) throws -> UInt8 {
        guard remaining >= k else { throw LinkError.shortBuffer }
        return bytes[i]
    }
}

// MARK: - DataX framing

enum DataX {
    static let chSetup: UInt16 = 0x8001        // link setup (RequestEncryption, EndLinkSetup)
    static let chSetupMirror: UInt16 = 0x0001  // EnableEncryption, trust, mirroring

    /// 4-byte header. payloadLen is 14 bits and counts tags + payload; bit 7 of the
    /// first byte marks "tags present". Encrypted DATA frames use 0x40|stream instead,
    /// and the two ranges never overlap (0x00-0x3F / 0x80-0xBF vs 0x40-0x7F).
    static func header(_ channel: UInt16, _ payloadLen: Int, hasExtension: Bool) -> Data {
        precondition(payloadLen >= 0 && payloadLen <= 0x3FFF, "payloadLen is 14 bits")
        let b0 = (hasExtension ? 0x80 : 0x00) | UInt8((payloadLen >> 8) & 0x3F)
        return Data([b0, UInt8(payloadLen & 0xFF)]) + be16(channel)
    }

    /// 4-byte tag: id (bit7 = "another tag follows"), zero, u16be value.
    static func tag(_ id: UInt8, _ value: UInt16, last: Bool) -> Data {
        var b = id & 0x7F
        if !last { b |= 0x80 }
        return Data([b, 0x00]) + be16(value)
    }

    static func message(_ channel: UInt16, tags: [Data], payload: Data = Data()) -> Data {
        let n = tags.reduce(0) { $0 + $1.count } + payload.count
        return header(channel, n, hasExtension: !tags.isEmpty) + tags.reduce(Data(), +) + payload
    }

    /// A status frame is a bare header carrying only the error tag and no payload.
    static func status(_ channel: UInt16, _ code: UInt16) -> Data {
        message(channel, tags: [tag(3, code, last: true)])
    }

    struct Message {
        let channel: UInt16
        let service: Int?
        let type: Int?
        let error: Int?
        let payload: Data
        let consumed: Int
    }

    /// Parse one plaintext DataX message.
    static func parse(_ buf: Data) throws -> Message {
        guard buf.count >= 4 else { throw LinkError.shortBuffer }
        let b0 = buf[0]
        let payloadLen = Int(b0 & 0x3F) << 8 | Int(buf[1])
        let channel = buf.u16be(2)
        var service: Int?, type: Int?, error: Int?
        var i = 4
        if b0 & 0x80 != 0 {
            while true {
                guard i + 4 <= buf.count else { throw LinkError.shortBuffer }
                let tb = buf[i]
                let val = Int(buf.u16be(i + 2))
                switch tb & 0x7F {
                case 1: service = val
                case 2, 4: type = val
                case 3: error = val
                default: break
                }
                i += 4
                if tb & 0x80 == 0 { break }
            }
        }
        let end = i + (payloadLen - (i - 4))
        guard end >= i, buf.count >= end else { throw LinkError.shortBuffer }
        return Message(channel: channel, service: service, type: type, error: error,
                       payload: Data(buf[i ..< end]), consumed: end)
    }
}

// MARK: - protobuf (wire types 0 and 2)

enum PB {
    static func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func key(_ field: Int, _ wire: Int) -> Data { varint(UInt64(field << 3 | wire)) }
    static func uint(_ field: Int, _ v: UInt64) -> Data { key(field, 0) + varint(v) }
    static func bytes(_ field: Int, _ d: Data) -> Data { key(field, 2) + varint(UInt64(d.count)) + d }

    static func parse(_ buf: Data) throws -> [Int: [Any]] {
        var out: [Int: [Any]] = [:]
        var i = 0
        let b = [UInt8](buf)
        while i < b.count {
            var key = 0, shift = 0
            while true {
                guard i < b.count else { throw LinkError.shortBuffer }
                let x = b[i]; i += 1
                key |= Int(x & 0x7F) << shift
                if x & 0x80 == 0 { break }
                shift += 7
            }
            let field = key >> 3, wire = key & 7
            if wire == 0 {
                var v = 0; shift = 0
                while true {
                    guard i < b.count else { throw LinkError.shortBuffer }
                    let x = b[i]; i += 1
                    v |= Int(x & 0x7F) << shift
                    if x & 0x80 == 0 { break }
                    shift += 7
                }
                out[field, default: []].append(v)
            } else if wire == 2 {
                var n = 0; shift = 0
                while true {
                    guard i < b.count else { throw LinkError.shortBuffer }
                    let x = b[i]; i += 1
                    n |= Int(x & 0x7F) << shift
                    if x & 0x80 == 0 { break }
                    shift += 7
                }
                guard i + n <= b.count else { throw LinkError.shortBuffer }
                out[field, default: []].append(Data(b[i ..< i + n]))
                i += n
            } else {
                throw LinkError.unsupportedWireType(wire)
            }
        }
        return out
    }
}

// MARK: - errors

enum LinkError: Error, CustomStringConvertible {
    case shortBuffer
    case unsupportedWireType(Int)
    case badUUID(String)
    case notDataFrame
    case badMAC
    case badLength
    case unexpected(String)
    case trustRejected(UInt16)
    case serviceError(String, UInt16)
    case io(String)

    var description: String {
        switch self {
        case .shortBuffer: return "short buffer"
        case .unsupportedWireType(let w): return "protobuf wire type \(w)"
        case .badUUID(let n): return "\(n) uuid is not RFC4122 v4 — glasses answer service_not_found"
        case .notDataFrame: return "not a DATA frame"
        case .badMAC: return "bad MAC"
        case .badLength: return "length does not match the block count"
        case .unexpected(let s): return "unexpected: \(s)"
        case .trustRejected(let c): return "trust rejected: \(AirShield.statusName(c)) (0x\(String(c, radix: 16)))"
        case .serviceError(let s, let c): return "\(s) error 0x\(String(c, radix: 16))"
        case .io(let s): return "io: \(s)"
        }
    }
}

// MARK: - AirShield handshake + key schedule

enum AirShield {
    static let version: UInt64 = 16
    static let paramsDefault: UInt64 = 31

    enum Quirk: UInt64 { case none = 0, qcs7 = 1 }

    // svc36 (identity / trust)
    static let svcIdentity = 36
    static let idEnableTrust: UInt16 = 0x1000
    static let idEnableTrustEC: UInt16 = 0x1001
    static let idSkipChallenge: UInt16 = 0x2000
    static let idStartChangeOwner: UInt16 = 0x2002
    static let idFinishChangeOwner: UInt16 = 0x2004
    static let idIdentityRequest: UInt16 = 0x3000

    static let stOK: UInt16 = 0x0000
    static let stSuccess: UInt16 = 0x1000

    static func statusName(_ c: UInt16) -> String {
        switch c {
        case 0x1000: return "SUCCESS"
        case 0x1010: return "KEY_NOT_FOUND (眼镜上没有这个 owner 的公钥)"
        case 0x1040: return "INVALID_RECEIPT (receipt 过期或被改)"
        case 0x1041: return "INVALID_NONCE"
        case 0x1042: return "INVALID_USER_ID (眼镜属于另一个 Meta 账号)"
        case 0x1043: return "INVALID_APP_IDENTITY"
        case 0x1044: return "INVALID_SIGNATURE"
        case 0x1045: return "INVALID_TIME"
        default: return "status 0x\(String(c, radix: 16))"
        }
    }

    /// RequestEncryption — ch 0x8001, service 5, type 1.
    static func requestEncryption(pubkey: Data, challenge: Data,
                                  hints: [Data] = [], quirks: Quirk = .none) -> Data {
        precondition(pubkey.count == 64, "wire pubkey is x||y, 64 bytes, no 0x04")
        precondition(challenge.count == 16)
        var body = PB.bytes(1, pubkey) + PB.bytes(2, challenge)
        body += PB.uint(3, 0) + PB.uint(4, paramsDefault)
        for h in hints { body += PB.bytes(5, h) }
        if quirks != .none { body += PB.uint(6, quirks.rawValue) }
        body += PB.uint(7, version)
        return DataX.message(DataX.chSetup, tags: [DataX.tag(1, 5, last: false),
                                                  DataX.tag(2, 1, last: true)], payload: body)
    }

    /// EnableEncryption — ch 0x0001, type 2. The second tag MUST be last, otherwise
    /// the receiver keeps reading tags and chokes on the payload.
    static func enableEncryption(pubkey: Data, seed: Data, iv: Data,
                                 baseSeq: UInt32, quirks: Quirk = .none) -> Data {
        precondition(pubkey.count == 64 && seed.count == 32 && iv.count == 16)
        var body = PB.bytes(1, pubkey) + PB.bytes(2, seed) + PB.bytes(3, iv)
        body += PB.uint(4, UInt64(baseSeq)) + PB.uint(5, paramsDefault)
        if quirks != .none { body += PB.uint(6, quirks.rawValue) }
        return DataX.message(DataX.chSetupMirror, tags: [DataX.tag(1, 2, last: false),
                                                         DataX.tag(2, 2, last: true)], payload: body)
    }

    /// EndLinkSetup — 46-byte plaintext: 80 2A 80 01 02 00 10 00 | 08 01 | 12 10 <stream> | 1A 10 <link>
    static func endLinkSetup(streamUUID: Data, linkUUID: Data) throws -> Data {
        for (name, u) in [("stream", streamUUID), ("link", linkUUID)] {
            guard u.count == 16, u[6] & 0xF0 == 0x40, u[8] & 0xC0 == 0x80 else {
                throw LinkError.badUUID(name)
            }
        }
        let body = PB.uint(1, 1) + PB.bytes(2, streamUUID) + PB.bytes(3, linkUUID)
        return Data([0x80, 0x2A, 0x80, 0x01, 0x02, 0x00, 0x10, 0x00]) + body
    }

    /// The phone's mirror of the glasses' EndLinkSetup, on channel 0x0001.
    static let endLinkStatus = Data([0x80, 0x04, 0x00, 0x01, 0x03, 0x00, 0x10, 0x00])

    /// svc36 type 4096: {1: SHA-256(owner pubkey x||y), 2: r||s, 3: capabilities 2}
    static func trustMessage(ownerPubkey: Data, signatureRaw: Data) -> Data {
        precondition(signatureRaw.count == 64)
        let digest = Data(SHA256.hash(data: ownerPubkey))
        let body = PB.bytes(1, digest) + PB.bytes(2, signatureRaw) + PB.uint(3, 2)
        return DataX.message(DataX.chSetupMirror,
                             tags: [DataX.tag(1, UInt16(svcIdentity), last: false),
                                    DataX.tag(2, idEnableTrust, last: true)],
                             payload: body)
    }

    // MARK: key schedule

    struct Keys {
        let aes: Data        // 32 bytes
        let hmac: Data       // 32 bytes (same as aes unless multikey)
        let iv: Data         // 16 bytes, chains per frame
        let macWord: Data    // 02 02 00 <quirk>
    }

    static func deriveKeys(shared: Data, nonce: Data, seed: Data, iv: Data,
                           quirks: Quirk, multikey: Bool = false) -> Keys {
        precondition(shared.count == 32)
        let saltAES = Data(SHA256.hash(data: nonce + seed))
        let saltHMAC = Data(SHA256.hash(data: seed + nonce + Data("hmac_derive".utf8)))
        let prk = Data(HMAC<SHA256>.authenticationCode(for: shared, using: SymmetricKey(data: saltAES)))
        let info: Data
        if quirks == .qcs7 {
            var p = Data("AirShield".utf8)
            p.append(Data(repeating: 0, count: 128 - p.count))
            p.append(le32(32)); p.append(le32(256))
            info = p
        } else {
            info = Data("AirShield".utf8) + Data([0x01])
        }
        let aes = Data(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: prk)))
        var hmac = aes
        if multikey {
            let prkH = Data(HMAC<SHA256>.authenticationCode(for: shared, using: SymmetricKey(data: saltHMAC)))
            hmac = Data(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: prkH)))
        }
        return Keys(aes: aes, hmac: hmac, iv: iv,
                    macWord: Data([0x02, 0x02, 0x00, UInt8(quirks.rawValue & 0xFF)]))
    }

    /// Send key: glasses challenge + our seed. Receive key: glasses seed + our challenge.
    static func sessionKeys(shared: Data, ownChallenge: Data, ownSeed: Data,
                            peerChallenge: Data, peerSeed: Data,
                            ownIV: Data, peerIV: Data, peerBaseSeq: UInt32,
                            quirks: Quirk, multikey: Bool = false) -> (send: Direction, recv: Direction) {
        let s = deriveKeys(shared: shared, nonce: peerChallenge, seed: ownSeed, iv: ownIV,
                           quirks: quirks, multikey: multikey)
        let r = deriveKeys(shared: shared, nonce: peerSeed, seed: ownChallenge, iv: peerIV,
                           quirks: quirks, multikey: multikey)
        return (Direction(s, seq: 0), Direction(r, seq: peerBaseSeq))
    }

    /// binding = SHA256( SHA256(glassesChallenge||glassesPubkey) || SHA256(seed||phonePubkey) )
    static func channelBinding(glassesChallenge: Data, glassesPubkey: Data,
                              seed: Data, phonePubkey: Data) -> Data {
        let a = Data(SHA256.hash(data: glassesChallenge + glassesPubkey))
        let b = Data(SHA256.hash(data: seed + phonePubkey))
        return Data(SHA256.hash(data: a + b))
    }
}

// MARK: - padding (custom, not PKCS#7)

enum AirShieldPad {
    static let magic: UInt8 = 0xC0

    static func pad(_ plain: Data) -> Data {
        let n = 16 - (plain.count % 16)
        return plain + Data(repeating: UInt8((n + Int(magic)) & 0xFF), count: n)
    }

    static func unpad(_ data: Data) -> Data {
        guard let last = data.last else { return data }
        let n = Int((UInt32(last) &+ 0x40) & 0xFF)
        guard n >= 1, n <= 16, data.count >= n else { return data }
        let tail = data.suffix(n)
        if tail.allSatisfy({ $0 == last }) { return Data(data.dropLast(n)) }
        return data
    }
}

// MARK: - one direction of the encrypted session

final class Direction {
    static let frameData: UInt8 = 0x40

    let aes: Data
    let hmac: Data
    let macWord: Data
    var iv: Data
    var seq: UInt32
    let stream: UInt8

    init(_ k: AirShield.Keys, seq: UInt32, stream: UInt8 = 0) {
        aes = k.aes; hmac = k.hmac; macWord = k.macWord; iv = k.iv
        self.seq = seq; self.stream = stream
    }

    /// header(1) + mac(8) + blockCount(1) + ciphertext(16n)
    func seal(_ plaintext: Data) throws -> Data {
        let padded = AirShieldPad.pad(plaintext)
        let blocks = padded.count / 16
        let ct = try Self.cbc(padded, key: aes, iv: iv, encrypt: true)
        let count = UInt8((blocks - 1) & 0xFF)
        let mac = Self.mac(hmac, macWord, seq, count, ct)
        iv = Data(ct.suffix(16))
        seq &+= 1
        return Data([Direction.frameData | stream]) + mac + Data([count]) + ct
    }

    func open(_ sdu: Data) throws -> Data {
        guard sdu.count >= 25 else { throw LinkError.shortBuffer }
        guard sdu[0] & 0xC0 == Direction.frameData else { throw LinkError.notDataFrame }
        let tag = Data(sdu[1 ..< 9])
        let count = sdu[9]
        let ct = Data(sdu[10...])
        guard ct.count == 16 * (Int(count) + 1) else { throw LinkError.badLength }
        let want = Self.mac(hmac, macWord, seq, count, ct)
        guard tag == want else { throw LinkError.badMAC }
        let plain = try Self.cbc(ct, key: aes, iv: iv, encrypt: false)
        iv = Data(ct.suffix(16))
        seq &+= 1
        return AirShieldPad.unpad(plain)
    }

    // mac = HMAC-SHA256(mac_word || LE32(seq) || count || ciphertext)[0..<8]
    static func mac(_ key: Data, _ macWord: Data, _ seq: UInt32, _ count: UInt8, _ ct: Data) -> Data {
        let msg = macWord + le32(seq) + Data([count]) + ct
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(mac).prefix(8)
    }

    static func cbc(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            input.withUnsafeBytes { inBuf -> CCCryptorStatus in
                key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivBuf -> CCCryptorStatus in
                        // options = 0: CBC without padding (we pad ourselves)
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyBuf.baseAddress, key.count,
                                ivBuf.baseAddress,
                                inBuf.baseAddress, input.count,
                                outBuf.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw LinkError.io("CCCrypt \(status)") }
        return out.prefix(moved)
    }
}
