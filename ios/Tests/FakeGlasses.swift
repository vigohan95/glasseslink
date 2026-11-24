// FakeGlasses.swift — a peer that speaks the real AirShield protocol from the glasses side.
//
// This is the Swift port of `pi/selftest_session.py`. It exists for one reason: the
// handshake, the trust signature, svc18 enumeration and svc20 file transfer can all be
// proven without the physical glasses, and every one of those paths is otherwise only
// exercised the first time somebody presses "连接" on a real device.
//
// The peer runs on its own thread, reads/writes through a bound `SDUStream` pair, and
// records any assertion it fails so the test can surface it.

import Foundation
import CryptoKit
@testable import GlassesLink

final class FakeGlasses {
    // service / message numbers, spelled out so a protocol change shows up here
    // DataX.Message reports service/type/error as `Int?`, so keep these Int and convert
    // only where a tag needs a UInt16.
    private static let svcCaptures = 18
    private static let svcAirship = 20
    private static let capEnum = 1
    private static let capRecord = 6
    private static let capEnd = 2
    private static let capRequestAsset = 0x83
    private static let airOffer = 1
    private static let airCursor = 2
    private static let airData = 4
    private static let airComplete = 6
    private static let airDrop = 7

    private let stream: SDUStream
    private let records: [Data]
    private let file: (name: String, data: Data)
    private let log: (String) -> Void
    private let expectTrust: Bool

    private var phonePub = Data()
    private var phoneChallenge = Data()
    private var phoneSeed = Data()
    private var phoneIV = Data()

    private var owner = OwnerMaterial(scalar: Data(repeating: 1, count: 32))
    private var tx: Direction?
    private var rx: Direction?

    // observations the test asserts on
    private(set) var failure: String?
    private(set) var sawTrust = false
    private(set) var sawEndLinkStatus = false
    private(set) var gotDrop = false
    private(set) var binding = Data()

    init(stream: SDUStream, records: [Data], file: (name: String, data: Data),
         expectTrust: Bool = true,
         log: @escaping (String) -> Void = { _ in }) {
        self.stream = stream
        self.records = records
        self.file = file
        self.expectTrust = expectTrust
        self.log = log
    }

    // MARK: - thread

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.runHandshake()
                try self.serve()
            } catch {
                self.failure = "\(error)"
                self.log("fake glasses stopped: \(error)")
            }
        }
    }

    // MARK: - handshake

    private func runHandshake() throws {
        log("h1 waiting for RequestEncryption")
        let req = try readPlain(timeout: 20)
        log("h1 got \(req.count)B")
        let first = try DataX.parse(req)
        guard first.channel == DataX.chSetup, first.service == 5, first.type == 1 else {
            throw LinkError.unexpected("expected RequestEncryption, got ch=0x\(String(first.channel, radix: 16))")
        }
        let f = try PB.parse(first.payload)
        guard let pub = f[1]?.first as? Data, let challenge = f[2]?.first as? Data else {
            throw LinkError.unexpected("RequestEncryption missing fields")
        }
        phonePub = pub
        phoneChallenge = challenge

        log("h2 answering with our key")
        // 2. answer with our own key + challenge
        let glassKey = P256.KeyAgreement.PrivateKey()
        owner = OwnerMaterial(scalar: glassKey.rawRepresentation)
        let ourChallenge = Data.random(16)
        try write(try AirShield.requestEncryption(pubkey: owner.publicKeyXy, challenge: ourChallenge))

        log("h3 sent ours, waiting for EnableEncryption")
        let en = try readPlain(timeout: 20)
        log("h3 got \(en.count)B")
        let second = try DataX.parse(en)
        guard second.channel == DataX.chSetupMirror, second.type == 2 else {
            throw LinkError.unexpected("expected EnableEncryption")
        }
        let g = try PB.parse(second.payload)
        guard let seed = g[2]?.first as? Data, let iv = g[3]?.first as? Data else {
            throw LinkError.unexpected("EnableEncryption missing fields")
        }
        phoneSeed = seed
        phoneIV = iv

        log("h4 announce ours")
        // 4. announce ours, then both sides derive the mirrored schedule
        let ourSeed = Data.random(32)
        let ourIV = Data.random(16)
        try write(try AirShield.enableEncryption(pubkey: owner.publicKeyXy, seed: ourSeed, iv: ourIV,
                                                 baseSeq: 0))

        let shared = try owner.sharedSecret(peerPubkeyXy: phonePub)
        // our send key == the phone's receive key, and vice versa
        let sendKeys = try AirShield.deriveKeys(shared: shared, nonce: ourSeed, seed: phoneChallenge,
                                            iv: ourIV, quirks: .none)
        let recvKeys = try AirShield.deriveKeys(shared: shared, nonce: ourChallenge, seed: phoneSeed,
                                            iv: phoneIV, quirks: .none)
        tx = Direction(sendKeys, seq: 0)
        rx = Direction(recvKeys, seq: 0)

        binding = AirShield.channelBinding(glassesChallenge: ourChallenge,
                                           glassesPubkey: owner.publicKeyXy,
                                           seed: phoneSeed, phonePubkey: phonePub)

        log("h5 keys derived")
        guard expectTrust else { log("h5 no-trust, returning"); return }     // provisioning link: no trust round at all

        log("h6 waiting for EnableTrust")
        let trustMsg = try readSealed(timeout: 20)
        log("h6 got \(trustMsg.count)B")
        let t = try DataX.parse(trustMsg)
        guard t.service == AirShield.svcIdentity, t.type == Int(AirShield.idEnableTrust) else {
            throw LinkError.unexpected("expected EnableTrust, got type \(t.type.map(String.init) ?? "-")")
        }
        let body = try PB.parse(t.payload)
        guard let publicId = body[1]?.first as? Data,
              let sig = body[2]?.first as? Data else {
            throw LinkError.unexpected("trust message missing fields")
        }
        guard publicId == Data(SHA256.hash(data: phonePub)) else {
            throw LinkError.unexpected("public id mismatch: the phone signed with a different key")
        }
        guard (body[3]?.first as? UInt64) == 2 else {
            throw LinkError.unexpected("capabilities field is not 2")
        }
        try verify(phonePub: phonePub, signature: sig, digest: binding)
        sawTrust = true

        // 6. trust accepted, then the mirrored link-setup dance
        try send(DataX.message(DataX.chSetupMirror,
                               tags: [DataX.tag(1, UInt16(AirShield.svcIdentity), last: false),
                                      DataX.tag(2, AirShield.idEnableTrust &+ 1, last: true)]))
        try send(DataX.status(DataX.chSetupMirror, AirShield.stSuccess))

        let els = try readSealed(timeout: 20)
        let e = try DataX.parse(els)
        guard e.type == 0x1000 else {
            throw LinkError.unexpected("expected EndLinkSetup, got type \(e.type.map(String.init) ?? "-")")
        }
        try send(DataX.message(DataX.chSetupMirror,
                               tags: [DataX.tag(2, 0x1000, last: true)]))

        let status = try readSealed(timeout: 20)
        let s = try DataX.parse(status)
        guard s.error == Int(AirShield.stOK) else {
            throw LinkError.unexpected("phone did not ack EndLinkSetup (error 0x\(String(s.error ?? 0xFFFF, radix: 16)))")
        }
        sawEndLinkStatus = true
    }

    // MARK: - services

    private func serve() throws {
        while true {
            let plain: Data
            do {
                plain = try readSealed(timeout: 25)
            } catch {
                return                      // the test finished; silence is normal
            }
            let m: DataX.Message
            do { m = try DataX.parse(plain) } catch { continue }   // a stray frame must not end the peer
            let svc = m.service, type = m.type

            // the provisioning link skips trust, so EndLinkSetup arrives here instead
            if type == 0x1000 {
                try send(DataX.message(DataX.chSetupMirror,
                                       tags: [DataX.tag(2, 0x1000, last: true)]))
                let ack = try DataX.parse(try readSealed(timeout: 20))
                // 0x1000 is the success code on the mirror channel; 0x0000 also shows up on
                // plain data frames. Checking only one of them is what made this peer
                // reject a correct ack (and the same mistake existed in Session once).
                guard ack.error == Int(AirShield.stOK) || ack.error == Int(AirShield.stSuccess) else {
                    throw LinkError.unexpected("EndLinkSetup not acked (0x\(String(ack.error ?? -1, radix: 16)))")
                }
                sawEndLinkStatus = true
                continue
            }
            if svc == Self.svcCaptures && type == Self.capEnum {
                for rec in records {
                    try send(DataX.message(m.channel,
                                           tags: [DataX.tag(1, UInt16(Self.svcCaptures), last: false),
                                                  DataX.tag(2, UInt16(Self.capRecord), last: true)],
                                           payload: rec))
                }
                try send(DataX.message(m.channel,
                                       tags: [DataX.tag(1, UInt16(Self.svcCaptures), last: false),
                                              DataX.tag(2, UInt16(Self.capEnd), last: true)]))
                continue
            }
            if svc == Self.svcCaptures && type == Self.capRequestAsset {
                try serveFile()
                continue
            }
            if svc == Self.svcAirship && type == Self.airDrop {
                gotDrop = true
                continue
            }
        }
    }

    /// The phone allocates its airship channel when it starts listening, and tells nobody.
    /// So offer on a few candidates and learn the real one from the cursor it answers with.
    private func serveFile() throws {
        let uuid = Data.uuid4()
        var offer = PB.bytes(1, uuid)
        offer += PB.uint(2, UInt64(file.data.count))
        offer += PB.bytes(3, Data("namespace_media".utf8))
        offer += PB.bytes(4, Data(file.name.utf8))

        for candidate in UInt16(0x8002) ... UInt16(0x8008) {
            try send(DataX.message(candidate,
                                   tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                          DataX.tag(2, UInt16(Self.airOffer), last: true)],
                                   payload: offer))
        }

        var channel: UInt16 = 0
        while channel == 0 {
            let m = try DataX.parse(try readSealed(timeout: 20))
            if m.service == Self.svcAirship, m.type == Self.airCursor {
                channel = m.channel
            }
        }

        var offset = 0
        while offset < file.data.count {
            let end = min(offset + 1024, file.data.count)
            try send(DataX.message(channel,
                                   tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                          DataX.tag(2, UInt16(Self.airData), last: true)],
                                   payload: file.data.subdata(in: offset ..< end)))
            offset = end
        }
        try send(DataX.message(channel,
                               tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                      DataX.tag(2, UInt16(Self.airComplete), last: true)],
                               payload: PB.uint(1, UInt64(file.data.count)) +
                                        PB.uint(2, UInt64(Session.adler32(file.data)))))
    }

    // MARK: - plumbing

    private func write(_ data: Data) throws { try stream.write(data) }

    private func readPlain(timeout: TimeInterval) throws -> Data {
        print("[glass] readPlain: buffered=\(stream.debugBufferCount)B")
        let f = try stream.nextFrame(timeout: timeout)
        print("[glass] readPlain: got \(f.count)B")
        return f
    }

    private func readSealed(timeout: TimeInterval) throws -> Data {
        let sdu = try stream.nextFrame(timeout: timeout)
        guard let r = rx else { return sdu }
        return try r.open(sdu)
    }

    private func send(_ plain: Data) throws {
        guard let t = tx else { return try write(plain) }
        try write(try t.seal(plain))
    }

    private func verify(phonePub: Data, signature: Data, digest: Data) throws {
        guard P256ECDSA.verify(digest: digest, signature: signature, publicKeyXy: phonePub) else {
            throw LinkError.unexpected("trust signature does not verify over the channel binding")
        }
    }
}

// MARK: - a minimal schema-less flatbuffer writer for the svc18 record

enum FlatBuild {
    /// Appends a table whose vtable sits immediately before it, and returns the table
    /// offset plus the absolute position of each four-byte field.
    @discardableResult
    static func table(_ buf: inout Data, slots: [Int]) -> (pos: Int, fields: [Int: Int]) {
        let ordered = slots.sorted()
        let n = (ordered.last ?? 0) + 1
        let vtSize = 4 + 2 * n
        var offsets = [Int: Int]()
        var cur = 4
        for slot in 0 ..< n {
            if ordered.contains(slot) {
                offsets[slot] = cur
                cur += 4
            }
        }
        var vt = Data()
        vt.append(le16(UInt16(vtSize)))
        vt.append(le16(UInt16(cur)))
        for slot in 0 ..< n { vt.append(le16(UInt16(offsets[slot] ?? 0))) }
        while vt.count % 4 != 0 { vt.append(0) }

        let vtPos = buf.count
        buf.append(vt)
        let tablePos = buf.count
        buf.append(le32(UInt32(bitPattern: Int32(tablePos - vtPos))))
        buf.append(Data(repeating: 0, count: 4 * ordered.count))
        pad(&buf)
        var fields = [Int: Int]()
        for slot in ordered { fields[slot] = tablePos + (offsets[slot] ?? 0) }
        return (tablePos, fields)
    }

    static func string(_ buf: inout Data, _ s: String) -> Int {
        let raw = Data(s.utf8)
        let pos = buf.count
        buf.append(le32(UInt32(raw.count)))
        buf.append(raw)
        buf.append(0)
        pad(&buf)
        return pos
    }

    static func putU32(_ buf: inout Data, _ at: Int, _ v: UInt32) {
        let b = le32(v)
        for (i, byte) in b.enumerated() { buf[at + i] = byte }
    }

    /// Forward reference: stores the distance from a field to the object it points at.
    static func putRef(_ buf: inout Data, _ at: Int, _ target: Int) {
        putU32(&buf, at, UInt32(bitPattern: Int32(target - at)))
    }

    static func pad(_ buf: inout Data, _ n: Int = 4) {
        while buf.count % n != 0 { buf.append(0) }
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }

    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    /// One svc18 record: handle, kind (3073 photo / 3074 video), a vector of assets
    /// (uuid / type / size) and the metadata table whose slot 4 is the capture time.
    static func captureRecord(handle: String, kind: UInt32, timestampNS: UInt64,
                             assets: [(uuid: String, type: UInt32, size: UInt32)]) -> Data {
        var buf = Data(repeating: 0, count: 4)          // root offset, patched last

        let (rec, recFields) = table(&buf, slots: [4, 8, 10, 12])
        putU32(&buf, recFields[8]!, kind)

        // vector of asset tables: count, then one relative offset per element
        let vecPos = buf.count
        buf.append(le32(UInt32(assets.count)))
        var elementPositions: [Int] = []
        for _ in assets {
            elementPositions.append(buf.count)
            buf.append(le32(0))
        }
        pad(&buf)

        for (i, asset) in assets.enumerated() {
            let (tbl, f) = table(&buf, slots: [4, 6, 12])
            putU32(&buf, f[6]!, asset.type)
            putU32(&buf, f[12]!, asset.size)
            putRef(&buf, elementPositions[i], tbl)
            let sPos = string(&buf, asset.uuid)
            putRef(&buf, f[4]!, sPos)
        }

        putRef(&buf, recFields[10]!, vecPos)
        let hPos = string(&buf, handle)
        putRef(&buf, recFields[4]!, hPos)

        let (meta, metaFields) = table(&buf, slots: [4])
        putU32(&buf, metaFields[4]!, UInt32(truncatingIfNeeded: timestampNS))
        putRef(&buf, recFields[12]!, meta)

        putU32(&buf, 0, UInt32(rec))
        return buf
    }
}
