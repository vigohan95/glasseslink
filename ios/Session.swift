// Session.swift — live AirShield session over LE L2CAP CoC, plus the svc18/svc20
// services (capture list, file transfer) and svc36 identity plumbing.
//
// Mirror of pi/session.py, which is verified by selftest_session.py against a fake
// glasses implementation. Every state transition below has a counterpart there.

import Foundation
import CoreBluetooth

// MARK: - SDU stream: reassembly over the L2CAP byte stream

/// L2CAP CoC hands us a byte stream, not messages. Frame boundaries are recovered
/// from the first byte:
///   * 0x40..0x7F  encrypted DATA frame: 1B header | 8B MAC | 1B blockCount | 16n ct
///   * 0x00..0x3F / 0x80..0xBF  plaintext DataX: 2B length (14 bits) | 2B channel
/// The two ranges are disjoint, which is what makes one-pass demux possible.
final class SDUStream: NSObject, StreamDelegate {
    private let input: InputStream
    private let output: OutputStream
    private let cond = NSCondition()
    private var buf = Data()
    private var closed = false
    private(set) var lastError: Error?

    var onLog: ((String) -> Void)?

    init(channel: CBL2CAPChannel) {
        input = channel.inputStream
        output = channel.outputStream
        super.init()
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
    }

    /// Test hook: drive the same reassembly machine from any byte-stream pair, so the
    /// whole handshake can be exercised with no glasses in the room (`boundPair()`).
    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        super.init()
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
    }

    /// Two cross-wired bound pairs: what one side writes the other reads. Both ends are
    /// scheduled on the main run loop, so a test that waits on the main queue delivers
    /// the stream callbacks exactly as CoreBluetooth would.
    static func boundPair(bufferSize: Int = 8192) throws -> (a: SDUStream, b: SDUStream) {
        // `Stream.getStreamsToStream` is macOS-only; CFStreamCreateBoundPair is the
        // portable way to get a pipe whose ends are ordinary NSStreams.
        func pair() throws -> (read: InputStream, write: OutputStream) {
            var read: CFReadStream?
            var write: CFWriteStream?
            CFStreamCreateBoundPair(nil, &read, &write, CFIndex(bufferSize))
            guard let r = read, let w = write else {
                throw LinkError.io("cannot create a bound stream pair")
            }
            return (r as InputStream, w as OutputStream)
        }
        let first = try pair()
        let second = try pair()
        // what one side writes, the other side reads
        return (SDUStream(input: second.read, output: first.write),
                SDUStream(input: first.read, output: second.write))
    }

    func write(_ data: Data) throws {
        var sent = 0
        let total = data.count
        while sent < total {
            cond.lock(); defer { cond.unlock() }
            if closed { throw LinkError.io("stream closed") }
            let n: Int = data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base.advanced(by: sent), maxLength: total - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0 { throw LinkError.io(output.streamError?.localizedDescription ?? "write failed") }
            if let e = output.streamError { throw LinkError.io(e.localizedDescription) }
            cond.wait(until: Date().addingTimeInterval(0.05))
        }
    }

    func close() {
        cond.lock(); closed = true; cond.broadcast(); cond.unlock()
        input.close(); output.close()
    }

    /// Block until one complete SDU is available.
    func nextFrame(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            if closed { throw LinkError.io("stream closed\(lastError.map { ": \($0)" } ?? "")") }
            if let need = Self.frameLength(buf) {
                if buf.count >= need {
                    let frame = Data(buf.prefix(need))
                    buf.removeFirst(need)
                    return frame
                }
            }
            if !cond.wait(until: min(deadline, Date().addingTimeInterval(0.25))) {
                if Date() >= deadline {
                    throw LinkError.unexpected("timeout waiting for a frame (folded? out of range?)")
                }
            }
        }
    }

    /// How many bytes the frame at the head of the buffer occupies, if knowable.
    static func frameLength(_ b: Data) -> Int? {
        guard b.count >= 1 else { return nil }
        let b0 = b[0]
        if b0 & 0xC0 == Direction.frameData {          // encrypted DATA frame
            guard b.count >= 10 else { return nil }
            return 10 + 16 * (Int(b[9]) + 1)
        }
        guard b.count >= 4 else { return nil }         // plaintext DataX
        let payloadLen = Int(b0 & 0x3F) << 8 | Int(b[1])
        return 4 + payloadLen
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = input.read(&chunk, maxLength: chunk.count)
            if n > 0 {
                cond.lock(); buf.append(contentsOf: chunk[0 ..< n]); cond.broadcast(); cond.unlock()
            }
        case .errorOccurred:
            cond.lock(); closed = true; lastError = aStream.streamError; cond.broadcast(); cond.unlock()
        case .endEncountered:
            cond.lock(); closed = true; cond.broadcast(); cond.unlock()
        default:
            break
        }
    }
}

// MARK: - capture records (schema-less flatbuffer)

struct CaptureAsset {
    let uuid: String
    let type: Int          // 1 video, 2 still, 3 IMU, 4 frame log
    let delivered: Bool
    let size: Int
}

struct Capture {
    let handle: String
    let kind: Int          // 3073 photo, 3074 video
    let timestampNS: Int?
    let assets: [CaptureAsset]
    var isPhoto: Bool { kind == 3073 }
    var stills: [CaptureAsset] { assets.filter { $0.type == 2 } }
}

enum FB {
    static func u16(_ b: [UInt8], _ p: Int) throws -> Int {
        guard p >= 0, p + 2 <= b.count else { throw LinkError.shortBuffer }
        return Int(b[p]) | Int(b[p + 1]) << 8
    }
    static func u32(_ b: [UInt8], _ p: Int) throws -> Int {
        guard p >= 0, p + 4 <= b.count else { throw LinkError.shortBuffer }
        return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
    }
    static func i32(_ b: [UInt8], _ p: Int) throws -> Int32 {
        Int32(bitPattern: UInt32(try u32(b, p)))
    }
    static func root(_ b: [UInt8]) throws -> Int { try u32(b, 0) }

    static func fieldOffset(_ b: [UInt8], _ table: Int, _ slot: Int) throws -> Int {
        let vt = table - Int(try i32(b, table))
        let vtSize = try u16(b, vt)
        let idx = 4 + slot * 2
        if idx + 2 > vtSize { return 0 }
        return try u16(b, vt + idx)
    }

    static func scalar(_ b: [UInt8], _ table: Int, _ slot: Int) throws -> Int {
        let off = try fieldOffset(b, table, slot)
        return off == 0 ? 0 : try u32(b, table + off)
    }

    static func string(_ b: [UInt8], _ table: Int, _ slot: Int) throws -> String? {
        let off = try fieldOffset(b, table, slot)
        guard off != 0 else { return nil }
        let p = table + off
        let s = p + (try u32(b, p))
        let n = try u32(b, s)
        guard s + 4 + n <= b.count else { throw LinkError.shortBuffer }
        return String(decoding: b[(s + 4) ..< (s + 4 + n)], as: UTF8.self)
    }

    static func table(_ b: [UInt8], _ pos: Int, _ slot: Int) throws -> Int? {
        let off = try fieldOffset(b, pos, slot)
        guard off != 0 else { return nil }
        let p = pos + off
        return p + (try u32(b, p))
    }

    static func tableVector(_ b: [UInt8], _ pos: Int, _ slot: Int) throws -> [Int] {
        let off = try fieldOffset(b, pos, slot)
        guard off != 0 else { return [] }
        let p = pos + off
        let v = p + (try u32(b, p))
        let n = try u32(b, v)
        var out: [Int] = []
        for i in 0 ..< n {
            let elem = v + 4 + 4 * i
            out.append(elem + (try u32(b, elem)))
        }
        return out
    }
}

// MARK: - the session

final class Session {
    static let chLocalFirst: UInt16 = 0x8002
    static let svcCaptures = 18
    static let svcAirship = 20

    static let capEnum: UInt16 = 1
    static let capRecord: UInt16 = 6
    static let capEnd: UInt16 = 2
    static let capRequestAsset: UInt16 = 0x83
    static let capSetLink: UInt16 = 0x86

    static let airOffer: UInt16 = 1
    static let airCursor: UInt16 = 2
    static let airReset: UInt16 = 3
    static let airData: UInt16 = 4
    static let airCheck: UInt16 = 5
    static let airComplete: UInt16 = 6
    static let airDrop: UInt16 = 7

    static let svcSettings = 31
    static let mtSyncData: UInt16 = 2
    static let mtAck: UInt16 = 3

    let stream: SDUStream
    let owner: OwnerMaterial
    var quirks: AirShield.Quirk = .none
    var multikey = false
    var log: (String) -> Void = { _ in }

    private var send: Direction?
    private var recv: Direction?
    private var nextChannel = chLocalFirst
    private var channels: [UInt16: String] = [:]
    private var idChannel: UInt16?
    private var idFirst = true
    private var statusFirst = true
    private var settingsFirst = true
    private var peerPubkey = Data()
    private var binding = Data()
    var streamUUID = Data.uuid4()
    var linkUUID = Data.uuid4()
    var peerSerial = ""

    init(stream: SDUStream, owner: OwnerMaterial, log: @escaping (String) -> Void = { _ in }) {
        self.stream = stream
        self.owner = owner
        self.log = log
    }

    // MARK: plumbing

    private func emit(_ s: String, _ data: Data? = nil, inbound: Bool = false) {
        var line = "\(inbound ? "<-" : "->") \(s)"
        if let d = data { line += " (\(d.count)B) \(d.hexShort)" }
        log(line)
    }

    private func sendPlain(_ data: Data) throws {
        emit("plain", data)
        try stream.write(data)
    }

    private func sendAny(_ data: Data) throws {
        if let s = send {
            emit("sealed", data)
            try stream.write(try s.seal(data))
        } else {
            try sendPlain(data)
        }
    }

    private func recvMessage(timeout: TimeInterval) throws -> DataX.Message {
        let sdu = try stream.nextFrame(timeout: timeout)
        let plain: Data
        if let r = recv { plain = try r.open(sdu) } else { plain = sdu }
        let msg = try DataX.parse(plain)
        emit("ch=0x\(String(msg.channel, radix: 16)) svc=\(msg.service.map(String.init) ?? "-") type=\(msg.type.map { String($0) } ?? "-")",
             plain, inbound: true)
        return msg
    }

    private func allocChannel(_ name: String) -> UInt16 {
        let ch = nextChannel
        nextChannel &+= 1
        channels[ch] = name
        return ch
    }

    private func channel(named name: String) -> UInt16? {
        channels.first { $0.value == name }?.key
    }

    // MARK: handshake

    /// RequestEncryption -> EnableEncryption -> [trust] -> EndLinkSetup.
    /// `trust: false` is the provisioning link: the glasses accept it even before
    /// they know our key, which is what makes an Android-free first pairing possible.
    func handshake(timeout: TimeInterval = 12, trust: Bool = true) throws {
        let pub = owner.publicKeyXy
        let challenge = Data.random(16)
        let seed = Data.random(32)
        let iv = Data.random(16)

        try sendPlain(AirShield.requestEncryption(pubkey: pub, challenge: challenge, quirks: quirks))
        let first = try recvMessage(timeout: timeout)
        guard first.channel == DataX.chSetup, first.service == 5, first.type == 1 else {
            throw LinkError.unexpected("expected RequestEncryption, got ch=0x\(String(first.channel, radix: 16))")
        }
        let f = try PB.parse(first.payload)
        guard let peerPub = f[1]?.first as? Data, let peerChallenge = f[2]?.first as? Data else {
            throw LinkError.unexpected("RequestEncryption missing fields")
        }
        if let q = f[6]?.first as? Int, q != 0, quirks == .none {
            quirks = q == 1 ? .qcs7 : .none      // follow what the glasses advertise
        }

        let shared = try owner.sharedSecret(peerPubkeyXy: peerPub)
        emit("ecdh ok, shared=\(shared.hexShort) quirks=\(quirks)")

        try stream.write(AirShield.enableEncryption(pubkey: pub, seed: seed, iv: iv,
                                                    baseSeq: 0, quirks: quirks))
        emit("EnableEncryption sent")

        // The glasses' own EnableEncryption is still plaintext.
        let sdu = try stream.nextFrame(timeout: timeout)
        let second = try DataX.parse(sdu)
        guard second.channel == DataX.chSetupMirror, second.type == 2 else {
            throw LinkError.unexpected("expected EnableEncryption, got ch=0x\(String(second.channel, radix: 16))")
        }
        let g = try PB.parse(second.payload)
        guard let peerSeed = g[2]?.first as? Data, let peerIV = g[3]?.first as? Data else {
            throw LinkError.unexpected("EnableEncryption missing fields")
        }
        let baseSeq = UInt32((g[4]?.first as? Int) ?? 0)

        let keys = AirShield.sessionKeys(shared: shared,
                                        ownChallenge: challenge, ownSeed: seed,
                                        peerChallenge: peerChallenge, peerSeed: peerSeed,
                                        ownIV: iv, peerIV: peerIV, peerBaseSeq: baseSeq,
                                        quirks: quirks, multikey: multikey)
        send = keys.send
        recv = keys.recv
        peerPubkey = peerPub
        binding = AirShield.channelBinding(glassesChallenge: peerChallenge, glassesPubkey: peerPub,
                                           seed: seed, phonePubkey: pub)
        emit("keys up — encrypted from here")

        if trust { try doTrust(timeout: timeout) }
        try endLinkSetup(timeout: timeout)
    }

    private func doTrust(timeout: TimeInterval) throws {
        let sig = try owner.signRaw(digest: binding)
        try sendAny(AirShield.trustMessage(ownerPubkey: owner.publicKeyXy, signatureRaw: sig))
        // 1) the glasses' own ENABLE_TRUST (0x1001), 2) a status frame on the mirror channel
        while true {
            let m = try recvMessage(timeout: timeout)
            if m.service == AirShield.svcIdentity, m.type == Int(AirShield.idEnableTrustEC) { break }
            log("   (ignoring during trust: ch=0x\(String(m.channel, radix: 16)) type=\(m.type.map(String.init) ?? "-"))")
        }
        while true {
            let m = try recvMessage(timeout: timeout)
            if let code = m.error {
                guard code != Int(AirShield.stOK) else { return }
                throw LinkError.trustRejected(UInt16(code))
            }
            if let code = m.error, code == Int(AirShield.stSuccess) { return }
        }
    }

    private func endLinkSetup(timeout: TimeInterval) throws {
        try sendAny(try AirShield.endLinkSetup(streamUUID: streamUUID, linkUUID: linkUUID))
        while true {
            let m = try recvMessage(timeout: timeout)
            if m.type == 0x1000 { break }
        }
        try sendAny(AirShield.endLinkStatus)
        emit("link up")
    }

    // MARK: long-lived service channels (streaming)

    /// One channel per named service. The service id is only sent on the first message of a
    /// channel; after that the glasses remember it.
    private var serviceChannels: [String: UInt16] = [:]

    func serviceChannel(_ name: String, service: Int) -> UInt16 {
        if let ch = serviceChannels[name] { return ch }
        let ch = allocChannel(name)
        serviceChannels[name] = ch
        return ch
    }

    /// Fire-and-forget on a named service: no waiting, so a push-heavy stream can keep sending.
    func sendOnService(_ name: String, service: Int, type: UInt16, payload: Data = Data()) throws {
        let ch = serviceChannel(name, service: service)
        var tags: [Data] = []
        if !servicesNamed.contains(ch) {
            tags.append(DataX.tag(1, UInt16(service), last: false))
            servicesNamed.insert(ch)
        }
        tags.append(DataX.tag(2, type, last: true))
        try sendAny(DataX.message(ch, tags: tags, payload: payload))
    }

    private var servicesNamed: Set<UInt16> = []

    /// The next message from any channel, for a reader loop that owns the link.
    func nextMessage(timeout: TimeInterval) throws -> DataX.Message {
        try recvMessage(timeout: timeout)
    }

    /// Sends and waits for the answer of one type on the same channel.
    func askOnService(_ name: String, service: Int, type: UInt16, payload: Data = Data(),
                      answerType: UInt16, timeout: TimeInterval = 6) throws -> Data {
        let ch = serviceChannel(name, service: service)
        try sendOnService(name, service: service, type: type, payload: payload)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("no answer to svc\(service)/type\(type)") }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            if let e = m.error, e != Int(AirShield.stOK), e != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("svc\(service)/type\(type)", UInt16(e))
            }
            if m.type == Int(answerType) { return m.payload }
        }
    }

    // MARK: generic request

    @discardableResult
    func request(channel: UInt16, service: Int, type: UInt16, payload: Data = Data(),
                 timeout: TimeInterval = 8, want: (Int?, UInt16)? = nil) throws -> (DataX.Message, Data) {
        let msg = DataX.message(channel, tags: [DataX.tag(1, UInt16(service), last: false),
                                                DataX.tag(2, type, last: true)], payload: payload)
        try sendAny(msg)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("no answer to svc\(service)/type\(type)") }
            let m = try recvMessage(timeout: left)
            if m.channel != channel { continue }
            if let e = m.error, e != Int(AirShield.stOK), e != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("svc\(service)/type\(type)", UInt16(e))
            }
            if let w = want {
                if m.service == w.0 && m.type == Int(w.1) { return (m, m.payload) }
                continue
            }
            return (m, m.payload)
        }
    }

    // MARK: svc36 identity

    @discardableResult
    func openIdentity() -> UInt16 {
        let ch = allocChannel("identity")
        idChannel = ch
        idFirst = true
        return ch
    }

    private func idSend(_ type: UInt16, payload: Data = Data()) throws {
        guard let ch = idChannel else { throw LinkError.unexpected("identity channel not open") }
        var tags: [Data] = []
        if idFirst {
            tags.append(DataX.tag(1, UInt16(AirShield.svcIdentity), last: false))
            idFirst = false
        }
        tags.append(DataX.tag(2, type, last: true))
        try sendAny(DataX.message(ch, tags: tags, payload: payload))
    }

    private func idRecv(_ want: UInt16, timeout: TimeInterval, step: String,
                        onWait: (() -> Void)? = nil, waitAfter: TimeInterval = 3) throws -> Data {
        guard let ch = idChannel else { throw LinkError.unexpected("identity channel not open") }
        let mirror = ch ^ 0x8000
        let started = Date()
        var warned = onWait == nil
        while true {
            let left = timeout - Date().timeIntervalSince(started)
            if left <= 0 { throw LinkError.unexpected("timeout awaiting svc36 0x\(String(want, radix: 16)) \(step)") }
            if !warned, Date().timeIntervalSince(started) >= waitAfter {
                warned = true
                onWait?()
            }
            let slice = warned ? left : min(left, 3)
            let m: DataX.Message
            do { m = try recvMessage(timeout: slice) } catch { continue }
            if let e = m.error, m.channel == mirror {
                if e != Int(AirShield.stOK) {
                    throw LinkError.trustRejected(UInt16(e))
                }
                continue
            }
            if m.channel != ch { continue }
            if m.type == Int(want) { return m.payload }
        }
    }

    struct Identity {
        let cert: Data
        let serial: String
        let registration: Data
        let secondaryCert: Data
    }

    func identity(timeout: TimeInterval = 20) throws -> Identity {
        if idChannel == nil { openIdentity() }
        try idSend(AirShield.idIdentityRequest)
        let body = try idRecv(AirShield.idIdentityRequest + 1, timeout: timeout, step: "identity")
        let f = try PB.parse(body)
        let cert = (f[1]?.first as? Data) ?? Data()
        let serialData = (f[2]?.first as? Data) ?? Data()
        peerSerial = String(decoding: serialData, as: UTF8.self)
        return Identity(cert: cert, serial: peerSerial,
                        registration: (f[3]?.first as? Data) ?? Data(),
                        secondaryCert: (f[5]?.first as? Data) ?? Data())
    }

    /// Returns the 16-byte device nonce that Meta's pair_request wants.
    func skipChallenge(timeout: TimeInterval = 20) throws -> Data {
        if idChannel == nil { openIdentity() }
        try idSend(AirShield.idSkipChallenge)
        let body = try idRecv(0x2001, timeout: timeout, step: "skip_challenge")
        let f = try PB.parse(body)
        guard let nonce = f[1]?.first as? Data else { throw LinkError.unexpected("no nonce") }
        return nonce
    }

    /// Hands Meta's pending receipt over; the glasses answer with theirs
    /// (signature + JSON that carries the device certificate).
    func startChangeOwner(pending: Data, timeout: TimeInterval = 120,
                          onWait: (() -> Void)? = nil) throws -> Data {
        if idChannel == nil { openIdentity() }
        try idSend(AirShield.idStartChangeOwner, payload: pending)
        return try idRecv(0x2003, timeout: timeout, step: "start_change_owner",
                          onWait: onWait, waitAfter: 4)
    }

    func finishChangeOwner(final: Data, timeout: TimeInterval = 25) throws {
        if idChannel == nil { openIdentity() }
        try idSend(AirShield.idFinishChangeOwner, payload: final)
        _ = try idRecv(0x2005, timeout: timeout, step: "finish_change_owner")
    }

    // MARK: svc18 captures

    func captureList(timeout: TimeInterval = 15) throws -> [Capture] {
        let ch = allocChannel("captures")
        try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Self.svcCaptures), last: false),
                                             DataX.tag(2, Self.capEnum, last: true)]))
        var out: [Capture] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("capture enumeration did not finish") }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            guard let t = m.type else { continue }
            if UInt16(t) == Self.capEnd { return out }
            if UInt16(t) == Self.capRecord, let cap = Self.parseCapture(m.payload) {
                out.append(cap)
            }
        }
    }

    func requestAsset(handle: String, assetID: String) throws {
        guard let ch = channel(named: "captures") else { throw LinkError.unexpected("no capture channel") }
        let payload = Data("\(handle):\(assetID)".utf8)
        try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Self.svcCaptures), last: false),
                                             DataX.tag(2, Self.capRequestAsset, last: true)],
                                  payload: payload))
    }

    static func parseCapture(_ body: Data) -> Capture? {
        let b = [UInt8](body)
        do {
            let root = try FB.root(b)
            let handle = try FB.string(b, root, 4) ?? ""
            let kind = try FB.scalar(b, root, 8)
            var ts: Int?
            if let meta = try FB.table(b, root, 12) { ts = try FB.scalar(b, meta, 4) }
            var assets: [CaptureAsset] = []
            for a in try FB.tableVector(b, root, 10) {
                let word = try FB.scalar(b, a, 6)
                assets.append(CaptureAsset(uuid: try FB.string(b, a, 4) ?? "",
                                           type: word & 0xFF,
                                           delivered: word & 0x100000 != 0,
                                           size: try FB.scalar(b, a, 12)))
            }
            guard !handle.isEmpty else { return nil }
            return Capture(handle: handle, kind: kind, timestampNS: ts, assets: assets)
        } catch {
            return nil
        }
    }

    // MARK: svc20 airship

    struct Transfer { let name: String; let size: Int; let data: Data }

    /// Serves exactly one incoming file. Every offer must be answered with type 7
    /// (drop), even when we keep the bytes — skipping it stalls the glasses' queue.
    func receiveFile(timeout: TimeInterval = 120) throws -> Transfer? {
        let ch = allocChannel("airship")
        var name = "capture.bin"
        var buf = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("file transfer did not complete") }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            guard let t = m.type else { continue }
            switch UInt16(t) {
            case Self.airOffer:
                let f = try PB.parse(m.payload)
                if let n = f[4]?.first as? Data { name = String(decoding: n, as: UTF8.self) }
                // cursor {1: offset, 2: adler32} — zeros for the start of a file
                try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                                     DataX.tag(2, Self.airCursor, last: true)],
                                          payload: PB.uint(1, 0) + PB.uint(2, 0)))
            case Self.airData:
                buf.append(m.payload)
            case Self.airCheck:
                try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                                     DataX.tag(2, Self.airCursor, last: true)],
                                          payload: PB.uint(1, UInt64(buf.count)) +
                                                   PB.uint(2, UInt64(Self.adler32(buf)))))
            case Self.airComplete:
                try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Self.svcAirship), last: false),
                                                     DataX.tag(2, Self.airDrop, last: true)]))
                return Transfer(name: name, size: buf.count, data: buf)
            case Self.airReset, Self.airDrop:
                throw LinkError.unexpected("transfer aborted by the glasses (\(t))")
            default:
                continue
            }
        }
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: svc33 RLDrive — the settings store

    /// Every object the glasses keep in `namespace`; settings live in `Drive.deviceSettings`.
    /// Round 0 asks for the whole namespace, so one round is normally enough.
    func driveObjects(namespace: String = Drive.deviceSettings,
                      types: [String] = Drive.defaultTypes,
                      timeout: TimeInterval = 8) throws -> [Drive.Object] {
        let ch = channel(named: "drive") ?? allocChannel("drive")
        let requestID = UUID().uuidString.lowercased()
        let sync = Drive.build(namespace: namespace, requestID: requestID, round: 0, types: types)
        try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Drive.service), last: false),
                                             DataX.tag(2, Drive.syncMessage, last: true)], payload: sync))
        let assembler = Drive.Assembler()
        var collected: [Drive.Object] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            guard m.type == Int(Drive.syncMessage) else { continue }
            guard let whole = assembler.add(m.payload), let reply = Drive.decode(whole) else { continue }
            collected += reply.objects
            if reply.terminated { break }
        }
        emit("drive \(namespace): \(collected.count) objects")
        return collected
    }

    /// Writes one setting the way another replica would: present a newer version of the object.
    /// The ack proves nothing on this service, so the value is read back before reporting success.
    @discardableResult
    func driveWrite(key: String, value: String, namespace: String = Drive.deviceSettings,
                    timeout: TimeInterval = 8) throws -> Bool {
        let ch = channel(named: "drive") ?? allocChannel("drive")
        let known = try driveObjects(namespace: namespace, timeout: timeout)
        var versions: Drive.Versions = [:]
        for object in known {
            versions[object.type, default: [:]][Drive.localWriter] = (versions[object.type]?[Drive.localWriter] ?? 0) + 1
        }
        let requestID = UUID().uuidString.lowercased()
        let object = Drive.Object(uri: key, type: Drive.kv, data: value, deleted: false, raw: Data())
        let sync = Drive.build(namespace: namespace, requestID: requestID, round: 1,
                               known: versions, types: [Drive.kv], objects: [object])
        try sendAny(DataX.message(ch, tags: [DataX.tag(1, UInt16(Drive.service), last: false),
                                             DataX.tag(2, Drive.syncMessage, last: true)], payload: sync))
        let assembler = Drive.Assembler()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m = try recvMessage(timeout: left)
            if m.channel != ch || m.type != Int(Drive.syncMessage) { continue }
            if let whole = assembler.add(m.payload), let reply = Drive.decode(whole), reply.terminated { break }
        }
        let after = try driveObjects(namespace: namespace, timeout: timeout)
        return after.contains { $0.uri == key && $0.data == value }
    }

    // MARK: svc28 device state

    private func statusChannel() -> UInt16 { channel(named: "status") ?? allocChannel("status") }

    /// Subscribes (or re-asks on the existing channel) and merges pushes until the snapshot has
    /// battery and storage, or the timeout runs out.
    func subscribeStatus(timeout: TimeInterval = 4) throws -> GlassesState {
        let ch = statusChannel()
        var tags: [Data] = []
        if statusFirst {
            tags.append(DataX.tag(1, UInt16(Status.service), last: false))
            statusFirst = false
        }
        tags.append(DataX.tag(2, Status.mtInit, last: true))
        try sendAny(DataX.message(ch, tags: tags, payload: Status.subscribePayload()))

        var state = GlassesState()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            guard let type = m.type, Status.isStateType(type) else { continue }
            Status.merge(m.payload, into: &state)
            if state.batteryPercent != nil && state.storageFreeMb != nil { break }
        }
        emit("status: \(state.lines.joined(separator: " / "))")
        return state
    }

    // MARK: svc31 settings (write-only)

    /// svc31, smartglasses_settings: the firmware's own write path. The ack is always SUCCESS,
    /// so the caller has to read the value back to know whether it took.
    @discardableResult
    func writeSettingsField(_ schema: SettingSchema, value: String, timeout: TimeInterval = 6) throws -> Bool {
        var payload = Data()
        switch schema.kind {
        case "bool":
            let on = ["1", "true", "on", "yes"].contains(value.lowercased())
            payload = PB.uint(schema.field ?? 0, on ? 1 : 0)
        case "int":
            // Unsigned varint: a negative number goes out as protobuf's ten-byte two's complement.
            guard let n = Int64(value.trimmingCharacters(in: .whitespaces)) else { return false }
            payload = PB.key(schema.field ?? 0, 0) + PB.varint(UInt64(bitPattern: n))
        case "str":
            payload = PB.string(schema.field ?? 0, value)
        case "float":
            guard let d = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
            payload = PB.double(schema.field ?? 0, d)
        default:
            return false
        }
        let ch = channel(named: "settings") ?? allocChannel("settings")
        var tags: [Data] = []
        if settingsFirst {
            tags.append(DataX.tag(1, UInt16(Self.svcSettings), last: false))
            settingsFirst = false
        }
        tags.append(DataX.tag(2, Self.mtSyncData, last: true))
        try sendAny(DataX.message(ch, tags: tags, payload: payload))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m = try recvMessage(timeout: left)
            if m.channel != ch { continue }
            guard m.type == Int(Self.mtAck) else { continue }
            if let e = m.error, e != Int(AirShield.stOK), e != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("svc31 ack", UInt16(e))
            }
            emit("svc31 wrote \(schema.key) = \(value)")
            return true
        }
        emit("svc31 no ack for \(schema.key)")
        return false
    }

    func close() { stream.close() }
}
