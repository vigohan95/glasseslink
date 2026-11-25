// Session.swift — live AirShield session over LE L2CAP CoC, plus the svc18/svc20
// services (capture list, file transfer) and svc36 identity plumbing.
//
// Mirror of pi/session.py, which is verified by selftest_session.py against a fake
// glasses implementation. Every state transition below has a counterpart there.

import Foundation
import CoreBluetooth

// MARK: - SDU reassembly shared by Bluetooth and Wi-Fi

struct SDUFrameBuffer {
    private var bytes: [UInt8] = []
    private var cursor = 0

    var count: Int { bytes.count - cursor }

    mutating func append(_ data: Data) {
        if cursor > 0 {
            bytes.removeFirst(cursor)
            cursor = 0
        }
        bytes.append(contentsOf: data)
    }

    mutating func popFirst() -> Data? {
        guard let need = SDUStream.frameLength(bytes[cursor...]), count >= need else { return nil }
        let result = Data(bytes[cursor ..< cursor + need])
        cursor += need
        if cursor == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            cursor = 0
        }
        return result
    }
}

/// L2CAP CoC hands us a byte stream, not messages. Frame boundaries are recovered
/// from the first byte:
///   * 0x40..0x7F  encrypted DATA frame: 1B header | 8B MAC | 1B blockCount | 16n ct
///   * 0x00..0x3F / 0x80..0xBF  plaintext DataX: 2B length (14 bits) | 2B channel
/// The two ranges are disjoint, which is what makes one-pass demux possible.
final class SDUStream: NSObject, StreamDelegate, SessionTransport {
    private let input: InputStream?
    private let output: OutputStream?

    private var buffer = SDUFrameBuffer()
    private var closed = false
    private var opened = false
    private var terminalFailure: LinkError?
    private var failureHandler: ((LinkError) -> Void)?
    private let cond = NSCondition()

    private var writeHook: ((Data) throws -> Void)?
    private var reader: Thread?

    /// Optional sink for transport-level notes (the app points this at its log).
    var onLog: ((String) -> Void)?

    init(channel: CBL2CAPChannel) {
        input = channel.inputStream
        output = channel.outputStream
        super.init()
        startReader()
    }

    /// Test seam: a pair that never touches Bluetooth.
    private init(nullStreams: Void) {
        input = nil
        output = nil
        super.init()
        opened = true
    }

    private func startReader() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "sdu.reader"
        t.stackSize = 512 * 1024
        reader = t
        t.start()
    }

    /// One thread owns the input stream; it never pumps a run loop, so nothing the
    /// caller does can re-enter it. Frames are handed over through `frames`.
    private func readLoop() {
        guard let input else { return }
        cond.lock()
        guard !closed else { cond.unlock(); return }
        input.open()
        output?.open()
        opened = true
        cond.broadcast()
        cond.unlock()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = input.read(&chunk, maxLength: chunk.count)
            if n <= 0 {
                finish(Self.ioError(input, fallback: "input stream ended"))
                return
            }
            ingest(Data(chunk[0 ..< n]))
        }
    }

    private func ingest(_ bytes: Data) {
        cond.lock()
        defer { cond.unlock() }
        guard !closed else { return }
        buffer.append(bytes)
        cond.broadcast()
    }

    static func loopbackPair() -> (a: SDUStream, b: SDUStream) {
        let a = SDUStream(nullStreams: ())
        let b = SDUStream(nullStreams: ())
        a.writeHook = { [weak b] data in b?.ingest(data) }
        b.writeHook = { [weak a] data in a?.ingest(data) }
        return (a, b)
    }

    /// Bytes pushed by a test (or by a hook) enter exactly the same path as the socket.
    func feed(_ data: Data) { ingest(data) }

    func write(_ data: Data) throws {
        try checkOpen()
        guard !data.isEmpty else { return }
        if let hook = writeHook {
            try hook(data)
            return
        }
        guard let output else { throw LinkError.io("no output stream") }
        try data.withUnsafeBytes { raw in
            var sent = 0
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while sent < data.count {
                try checkOpen()
                let n = output.write(base.advanced(by: sent), maxLength: data.count - sent)
                if n <= 0 {
                    throw finish(Self.ioError(output, fallback: "output stream stopped accepting bytes"))
                }
                sent += n
            }
        }
    }

    private func checkOpen() throws {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !opened, !closed {
            if !cond.wait(until: deadline), !opened, !closed {
                throw LinkError.io("蓝牙数据流打开超时")
            }
        }
        if closed { throw terminalFailure ?? LinkError.io("stream closed") }
    }

    static func frameLength<Bytes: RandomAccessCollection>(_ b: Bytes) -> Int?
        where Bytes.Element == UInt8, Bytes.Index == Int {
        guard b.count >= 1 else { return nil }
        let start = b.startIndex
        let b0 = b[start]
        if b0 & 0xC0 == Direction.frameData {          // encrypted DATA frame
            guard b.count >= 10 else { return nil }
            return 10 + 16 * (Int(b[start + 9]) + 1)
        }
        guard b.count >= 4 else { return nil }         // plaintext DataX
        let payloadLen = Int(b0 & 0x3F) << 8 | Int(b[start + 1])
        return 4 + payloadLen
    }

    func nextFrame(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while !closed {
            if let sdu = buffer.popFirst() { return sdu }
            if deadline.timeIntervalSinceNow <= 0 {
                throw LinkError.unexpected("timeout waiting for a frame (folded? out of range?)")
            }
            _ = cond.wait(until: deadline)
        }
        throw terminalFailure ?? LinkError.io("stream closed")
    }

    func close() {
        finish()
    }

    /// Reports the first transport failure, including one that occurred before registration.
    func setFailureHandler(_ handler: @escaping (LinkError) -> Void) {
        cond.lock()
        let failure = terminalFailure
        if !closed { failureHandler = handler }
        cond.unlock()
        if let failure { handler(failure) }
    }

    @discardableResult
    private func finish(_ error: LinkError? = nil) -> LinkError {
        cond.lock()
        if closed {
            let first = terminalFailure ?? LinkError.io("stream closed")
            cond.unlock()
            return first
        }
        closed = true
        buffer = SDUFrameBuffer()
        terminalFailure = error
        let handler = failureHandler
        failureHandler = nil
        cond.broadcast()
        cond.unlock()
        input?.close()
        output?.close()
        if let error { handler?(error) }
        return error ?? LinkError.io("stream closed")
    }

    private static func ioError(_ source: Stream, fallback: String) -> LinkError {
        let detail = source.streamError.map { String(describing: $0) } ?? fallback
        return .io("stream closed: \(detail)")
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode == .errorOccurred || eventCode == .endEncountered {
            finish(Self.ioError(aStream, fallback: "stream ended"))
        }
    }

    /// Bytes still waiting to be framed, plus whole frames not yet consumed by tests.
    var debugBufferCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return buffer.count
    }
}

struct CaptureAsset: Codable {
    let uuid: String
    let type: Int          // 1 video, 2 still, 3 IMU, 4 frame log
    let delivered: Bool
    let size: Int
}

struct Capture: Codable {
    let handle: String
    let kind: Int          // 3073 photo, 3074 video
    let timestampNS: Int?
    let assets: [CaptureAsset]
    var isPhoto: Bool { kind == 3073 }
    var stills: [CaptureAsset] { assets.filter { $0.type == 2 } }

    /// Stable id used for local bookkeeping (thumbnails, "already imported").
    var id: String {
        if let still = stills.first { return still.uuid }
        if let first = assets.first { return first.uuid }
        return handle
    }
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
    static let capDelete: UInt16 = 3
    static let capDeleteOK: UInt16 = 4
    static let capDeleteFailed: UInt16 = 5
    static let capRequestAsset: UInt16 = 0x83
    static let capAssetQueued: UInt16 = 0x84
    static let capAssetGone: UInt16 = 0x85
    static let capSetLink: UInt16 = 0x86
    static let capLinkSet: UInt16 = 0x87

    static let airOffer: UInt16 = 1
    static let airCursor: UInt16 = 2
    static let airReset: UInt16 = 3
    static let airData: UInt16 = 4
    static let airCheck: UInt16 = 5
    static let airComplete: UInt16 = 6
    static let airDrop: UInt16 = 7
    static let airRemoved: UInt16 = 8
    static let airStopped: UInt16 = 11
    static let airOfferMultiscope: UInt16 = 12

    static let svcSettings = 31
    static let mtSyncData: UInt16 = 2
    static let mtAck: UInt16 = 3

    /// Firmware update service. Nothing of ours lives here; the phone is normally the
    /// downloader, so refusing these requests is what actually freezes the firmware.
    static let svcOta: UInt16 = 29

    /// Set before connecting: say no to every svc29 request instead of proxying it.
    var blockOTA = true
    private(set) var otaBlocked = 0

    /// Turn on from the UI before connecting: logs up to 60 frames as full hex
    /// instead of the 16-byte prefix, which is what you need when the glasses
    /// reject a trust frame and all you get back is a status code.
    static var verbose = false

    let stream: any SessionTransport
    let owner: OwnerMaterial
    var quirks: AirShield.Quirk = .none
    // Parameters are 31 on both ends and 31 & 31 & 31 & MULTIKEY(4) != 0, so the two
    // directions use different AES and HMAC keys. With this false the tag can never
    // match, which looks exactly like a wrong key.
    var multikey = true
    var log: (String) -> Void = { _ in }

    private let logLock = NSLock()
    private var verboseLines = 0

    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var send: Direction?
    private var recv: Direction?
    private var ownerTrustCompleted = false
    var hasVerifiedOwner: Bool { ownerTrustCompleted }
    var verifiedPeerKey: Data? { ownerTrustCompleted ? peerPubkey : nil }
    /// Plausible receive-direction keys, built at handshake time and resolved by the
    /// first inbound frame (see `recvMessage`).
    private var rxOptions: [RxCandidate] = []
    private var rxSolved = false
    private var ivSolved = false
    private var rxIVs: [Data] = []
    private var dataXCarry = Data()
    private var decodedMessages: ArraySlice<DataX.Message> = []
    private var pendingSetupMessages: [DataX.Message] = []

    static func uniqueIVs(_ list: [Data]) -> [Data] {
        var out: [Data] = []
        for iv in list where iv.count == 16 && !out.contains(iv) { out.append(iv) }
        return out
    }
    private var nextChannel = chLocalFirst
    private var channels: [UInt16: String] = [:]
    private var idChannel: UInt16?
    private var idFirst = true
    private var statusSubscribed = false
    private var settingsFirst = true
    private var peerPubkey = Data()
    private var binding = Data()
    var streamUUID = Data.uuid4()
    var linkUUID = Data.uuid4()
    var peerSerial = ""

    init(stream: any SessionTransport, owner: OwnerMaterial, log: @escaping (String) -> Void = { _ in }) {
        self.stream = stream
        self.owner = owner
        self.log = log
    }

    // MARK: plumbing

    private func emit(_ s: String, _ data: Data? = nil, inbound: Bool = false) {
        var line = "\(inbound ? "<-" : "->") \(s)"
        if let d = data {
            logLock.lock()
            let verbose = Session.verbose && verboseLines < 60
            if verbose { verboseLines += 1 }
            logLock.unlock()
            line += " (\(d.count)B) \(verbose ? d.hexCapped : d.hexShort)"
        }
        log(line)
    }

    private func sendPlain(_ data: Data) throws {
        emit("plain", data)
        try stream.write(data)
    }

    /// A bare status frame (only an error tag) — how a service answers yes/no.
    func sendStatus(_ channel: UInt16, _ code: UInt16) throws {
        try sendAny(DataX.status(channel, code))
    }

    private func sendAny(_ data: Data, tracePayload: Bool = true) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        if let s = send {
            if tracePayload { emit("sealed", data) }
            else { emit("sealed service message (\(data.count)B)") }
            try stream.write(try s.seal(data))
        } else {
            try sendPlain(data)
        }
    }

    struct RxCandidate {
        let label: String
        let dir: Direction
    }

    /// Every combination the receive direction could plausibly use on a link where the
    /// peer never announced its own seed/IV.
    static func receiveCandidates(shared: Data, ownChallenge: Data, ownSeed: Data,
                                  peerChallenge: Data, peerSeed: Data,
                                  ownIV: Data, peerIV: Data, peerBase: UInt32,
                                  ownBase: UInt32, quirks: AirShield.Quirk,
                                  multikey: Bool) -> [RxCandidate] {
        let pairs: [(String, Data, Data)] = [
            ("chal:own/seed:peer", ownChallenge, peerSeed),
            ("seed:own/chal:peer", ownSeed, peerChallenge),
            ("seed:peer/chal:own", peerChallenge, ownSeed),
            ("seed:own/chal:own", ownChallenge, ownSeed),
            ("seed:peer/chal:peer", peerSeed, peerChallenge),
        ]
        let ivs: [(String, Data)] = [
            ("iv:own", ownIV),
            ("iv:zero", Data(repeating: 0, count: 16)),
            ("iv:peer", peerIV),
        ]
        var seqs: [(String, UInt32)] = [("seq:0", 0), ("seq:ownBase", ownBase)]
        if peerBase != 0 { seqs.append(("seq:peerBase", peerBase)) }

        // The two directions are allowed to use different AirShield variants: whatever the
        // glasses announce applies to what they *send*, and some firmware announces nothing
        // while using QCS7 anyway. Try both; the HMAC decides.
        let variants: [(String, AirShield.Quirk)] = [("", quirks),
                                                    (quirks == .qcs7 ? " [plain]" : " [qcs7]",
                                                     quirks == .qcs7 ? .none : .qcs7)]
        var out: [RxCandidate] = []
        for (vn, q) in variants {
            for (pn, nonce, seedValue) in pairs {
                guard !nonce.isEmpty, !seedValue.isEmpty else { continue }
                for (ivn, ivValue) in ivs {
                    guard ivValue.count == 16 else { continue }
                    for (sn, seq) in seqs {
                        guard let k = try? AirShield.deriveKeys(shared: shared, nonce: nonce, seed: seedValue,
                                                                iv: ivValue, quirks: q, multikey: multikey)
                        else { continue }
                        out.append(RxCandidate(label: "\(pn) \(ivn) \(sn)\(vn)",
                                               dir: Direction(k, seq: seq)))
                    }
                }
            }
        }
        return out
    }

    /// Try each candidate key against one encrypted frame. A wrong key fails the HMAC,
    /// so at most one candidate can succeed — no guessing in the caller.
    static func firstWorkingCandidate(_ sdu: Data, options: [RxCandidate])
        -> (label: String, dir: Direction, plain: Data)? {
        for option in options {
            if let plain = try? option.dir.open(sdu) {
                return (option.label, option.dir, plain)
            }
        }
        return nil
    }

    static func isEndLinkSetupRequest(_ message: DataX.Message) -> Bool {
        message.channel == DataX.chSetup && message.service == nil
            && message.type == 0x1000 && message.error == nil
    }

    private func openFrame(_ sdu: Data) throws -> Data {
        guard let receiver = recv else { throw LinkError.unexpected("receive direction unavailable") }
        if let plain = try? receiver.open(sdu) {
            rxSolved = true
            return plain
        }
        if !rxSolved, let hit = Self.firstWorkingCandidate(sdu, options: rxOptions) {
            recv = hit.dir
            rxSolved = true
            emit("rx key = \(hit.label)", nil, inbound: true)
            return hit.plain
        }
        emit("decrypt FAILED (bad MAC on \(sdu.count)B)", sdu, inbound: true)
        throw LinkError.badMAC
    }

    private func resolveFirstIV(_ plain: Data, frame sdu: Data) -> Data {
        guard !ivSolved, let receiver = recv else { return plain }
        // Later frames use the previous ciphertext block, even if this plaintext is partial.
        ivSolved = true
        guard (try? DataX.parse(plain)) == nil else { return plain }
        for iv in rxIVs {
            let keys = AirShield.Keys(aes: receiver.aes, hmac: receiver.hmac,
                                      iv: iv, macWord: receiver.macWord)
            let candidate = Direction(keys, seq: receiver.seq &- 1)
            if let rebuilt = try? candidate.open(sdu),
               (try? DataX.parseMessages(rebuilt, requireComplete: true)) != nil {
                emit("rx IV solved after a garbled first frame", nil, inbound: true)
                return rebuilt
            }
        }
        return plain
    }

    private func decodeFrame(_ sdu: Data, bulkChannel: UInt16? = nil, tracePayload: Bool = true) throws -> [DataX.Message] {
        let plain = resolveFirstIV(try openFrame(sdu), frame: sdu)
        let available = dataXCarry.count + plain.count
        let packets = DataX.splitMessages(plain, carry: &dataXCarry)
        var consumed = 0
        let messages = packets.map { packet in
            let msg = packet.message
            consumed += msg.consumed
            let bulk = msg.channel == bulkChannel && msg.error == nil
                && (msg.type == nil || msg.type == Int(Self.airData))
            if !bulk {
                let atc = serviceChannels["media-wifi-atc"]
                let sensitive = msg.service == Int(Assistant.service) || msg.service == 10
                    || atc.map { msg.channel == $0 || msg.channel == ($0 ^ 0x8000) } == true
                emit("ch=0x\(String(msg.channel, radix: 16)) svc=\(msg.service.map(String.init) ?? "-") type=\(msg.type.map { String($0) } ?? "-")",
                     tracePayload && !sensitive ? packet.wire : nil, inbound: true)
            }
            return msg
        }
        let skipped = available - consumed - dataXCarry.count
        if skipped > 0 { emit("skipped \(skipped)B of malformed DataX messages", nil, inbound: true) }
        return messages
    }

    private func recvMessage(timeout: TimeInterval, includePending: Bool = true,
                             handlesAirshipOffers: Bool = false, bulkChannel: UInt16? = nil,
                             tracePayload: Bool = true) throws -> DataX.Message {
        let deadline = Date().addingTimeInterval(timeout)
        receiveLock.lock()
        defer { receiveLock.unlock() }
        while true {
            let msg: DataX.Message
            if includePending, !pendingSetupMessages.isEmpty {
                msg = pendingSetupMessages.removeFirst()
            } else if let decoded = decodedMessages.popFirst() {
                msg = decoded
            } else {
                let sdu = try stream.nextFrame(timeout: max(0, deadline.timeIntervalSinceNow))
                decodedMessages = try decodeFrame(sdu, bulkChannel: bulkChannel, tracePayload: tracePayload)[...]
                continue
            }

            // The glasses start EndLinkSetup; the answer is a bare 0x1000 status on the
            // mirror channel. Callers never see this message.
            if Self.isEndLinkSetupRequest(msg) {
                try sendAny(AirShield.endLinkStatus)
                emit("answered the glasses' EndLinkSetup")
                continue
            }

            // Firmware updates live on svc29; the phone is the one that downloads and feeds
            // the file. Refusing here (and never proxying a download) is what actually keeps
            // the firmware frozen — the cloud_ota_enabled setting only asks nicely.
            if blockOTA, msg.service == Int(Self.svcOta) {
                otaBlocked += 1
                emit("已拦截固件升级请求 svc29 type=\(msg.type.map(String.init) ?? "-")（第 \(otaBlocked) 次）")
                try? sendStatus(msg.channel, 0xC001)
                continue
            }
            if !handlesAirshipOffers, try rejectUnrequestedAirshipOffer(msg) { continue }
            return msg
        }
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

    /// RequestEncryption -> EnableEncryption -> EndLinkSetup -> optional trust.
    /// `trust: false` is the provisioning link: the glasses accept it even before
    /// they know our key, which is what makes an Android-free first pairing possible.
    static let missingPeerEncryptionRequest = "no RequestEncryption from the glasses"

    func handshake(timeout: TimeInterval = 12, trust: Bool = true, quickStart: Bool = false,
                   expectedPeerKey: Data? = nil) throws {
        ownerTrustCompleted = false
        let pub = owner.publicKeyXy
        let challenge = Data.random(16)
        let seed = Data.random(32)
        let iv = Data.random(16)
        // Visor sends a random per-direction preamble seq and starts its own numbering there;
        // a hard-coded 0 makes some firmware reject the whole EnableEncryption.
        let baseSeq = UInt32.random(in: 1 ... 0xFFFF_FFF0)

        var peerRequest: (pub: Data, challenge: Data, quirks: AirShield.Quirk, version: Int)?
        var peerEnable: (seed: Data, iv: Data, base: UInt32, quirks: AirShield.Quirk)?

        func absorb(_ m: DataX.Message) throws {
            // Visor puts RequestEncryption on LINK_SETUP (0x8001) but EnableEncryption on
            // ENABLE (0x0001). Filtering on 0x8001 alone silently dropped the peer's seed and
            // IV, which is exactly what produced "enable=absent" and an underivable rx key.
            guard m.channel == DataX.chSetup || m.channel == DataX.chSetupMirror, let t = m.type else { return }
            let f = try PB.parse(m.payload)
            if t == 1, peerRequest == nil,
               let p = f[1]?.first as? Data, let c = f[2]?.first as? Data {
                let q = (f[6]?.first as? Int) ?? 0
                peerRequest = (p, c, q == 1 ? .qcs7 : .none, (f[7]?.first as? Int) ?? 0)
            } else if t == 2, peerEnable == nil,
                      let s = f[2]?.first as? Data, let i = f[3]?.first as? Data {
                let q = (f[6]?.first as? Int) ?? 0
                guard let base = UInt32(exactly: (f[4]?.first as? Int) ?? 0) else {
                    throw LinkError.unexpected("peer EnableEncryption base sequence out of range")
                }
                peerEnable = (s, i, base, q == 1 ? .qcs7 : .none)
            }
        }

        // Fresh pairings may ignore a request while they switch out of pairing mode.
        // Already trusted Gen 2 (build 94, device log 25, 1728–1731) waited six seconds
        // without an incoming frame, then answered the phone's active request immediately.
        var passive = 0
        let passiveUntil = Date().addingTimeInterval(quickStart ? 0.75 : 6)
        while peerRequest == nil, passiveUntil.timeIntervalSinceNow > 0 {
            let sdu: Data
            do { sdu = try stream.nextFrame(timeout: min(1, passiveUntil.timeIntervalSinceNow)) }
            catch LinkError.unexpected(_) { continue }
            guard let m = try? DataX.parse(sdu) else { continue }
            emit("passive inbound ch=0x\(String(m.channel, radix: 16)) type=\(m.type.map(String.init) ?? "-")",
                 sdu, inbound: true)
            passive += 1
            try absorb(m)
        }
        emit("passive read: \(passive) frame(s) before we spoke")

        // Speak regardless: the exchange needs our challenge and seed even when they went first.
        // Visor's SecureLink.open() sends RequestEncryption *and* EnableEncryption back to back,
        // then reads up to HANDSHAKE_READS frames. Sending ours only after their request is what
        // left Gen 2 silent for twelve seconds and made the link look unbuildable.
        try sendPlain(try AirShield.requestEncryption(pubkey: pub, challenge: challenge, quirks: quirks))
        try stream.write(try AirShield.enableEncryption(pubkey: pub, seed: seed, iv: iv,
                                                        baseSeq: baseSeq, quirks: quirks))
        emit("sent RequestEncryption + EnableEncryption (base=\(baseSeq))")

        // Both messages are plaintext and may arrive in either order, sometimes twice.
        let deadline = Date().addingTimeInterval(timeout)
        // Gen 2 never sends its own EnableEncryption, so only insist on the request; give a
        // short extra window for an EnableEncryption that some firmware does send.
        let enableWindow = Date().addingTimeInterval(4)
        while Date() < deadline {
            let done = peerRequest != nil && (peerEnable != nil || Date() > enableWindow)
            if done { break }
            let sdu: Data
            do { sdu = try stream.nextFrame(timeout: min(2, deadline.timeIntervalSinceNow)) }
            catch LinkError.unexpected(_) { continue }
            guard let m = try? DataX.parse(sdu) else { continue }
            try absorb(m)
        }
        guard let req = peerRequest else {
            throw LinkError.unexpected(Self.missingPeerEncryptionRequest)
        }
        if let expectedPeerKey, expectedPeerKey != req.pub {
            throw LinkError.unexpected("Wi-Fi 会话的眼镜身份与蓝牙会话不一致。")
        }
        let en = peerEnable
        emit("peer version=\(req.version) quirks req=\(req.quirks) enable=\(en == nil ? "absent" : "\(en!.quirks)")")

        quirks = req.quirks

        let shared = try owner.sharedSecret(peerPubkeyXy: req.pub)
        emit("ecdh ok, quirks=\(quirks)")

        // Already sent above, together with the request (Visor does the same). Nothing left to do
        // here but remember that the peer's own EnableEncryption is what the rx key needs.
        emit("EnableEncryption was sent up front (base=\(baseSeq))")

        // The glasses answer our EnableEncryption with their own, carrying the seed and IV our
        // receive direction needs. Wait for it instead of deriving keys from an empty seed.
        if peerEnable == nil {
            let until = Date().addingTimeInterval(3)
            while Date() < until, peerEnable == nil {
                let sdu: Data
                do { sdu = try stream.nextFrame(timeout: min(1, until.timeIntervalSinceNow)) }
                catch LinkError.unexpected(_) { continue }
                guard let m = try? DataX.parse(sdu) else { continue }
                try? absorb(m)
            }
            emit("post-enable read: peer enable=\(peerEnable == nil ? "absent" : "present")")
        }

        let keys = try AirShield.sessionKeys(shared: shared,
                                        ownChallenge: challenge, ownSeed: seed,
                                        peerChallenge: req.challenge, peerSeed: peerEnable?.seed ?? Data(),
                                        ownIV: iv, peerIV: peerEnable?.iv ?? Data(), peerBaseSeq: peerEnable?.base ?? 0,
                                        quirks: quirks, multikey: multikey)
        send = keys.send
        recv = keys.recv
        send?.seq = baseSeq

        // Gen 2 never sends EnableEncryption of its own, so the "peer seed / peer IV" the
        // book says to use for the receive direction does not exist on this link. That
        // leaves three real unknowns (which 32-byte value plays the nonce, which IV the
        // glasses start from, where its sequence begins). Instead of guessing once and
        // failing with bad MAC forever, prepare the plausible combinations; the first
        // frame the glasses send decides — its HMAC verifies under exactly one of them.
        rxOptions = Self.receiveCandidates(shared: shared, ownChallenge: challenge, ownSeed: seed,
                                           peerChallenge: req.challenge, peerSeed: peerEnable?.seed ?? Data(),
                                           ownIV: iv, peerIV: peerEnable?.iv ?? Data(), peerBase: peerEnable?.base ?? 0,
                                           ownBase: baseSeq, quirks: quirks, multikey: multikey)
        emit("rx candidates: \(rxOptions.count)")
        // The MAC proves the key but not the IV; keep the IVs worth trying for the first frame.
        rxIVs = Self.uniqueIVs([peerEnable?.iv ?? Data(), iv, Data(repeating: 0, count: 16)])
        peerPubkey = req.pub
        binding = AirShield.channelBinding(glassesChallenge: req.challenge, glassesPubkey: req.pub,
                                           seed: seed, phonePubkey: pub)
        emit("keys up — encrypted from here")

        // Visor's SecureLink.open() finishes with finishLinkSetup(); everything else (trust,
        // services) happens after that. Without it the glasses answer nothing on svc36 —
        // the log showed `timeout awaiting svc36 0x3001 identity` right after a clean handshake.
        // Tolerate silence here: a device that does not want a link setup answer still gets trust.
        // 2 s, not 6: on this firmware the glasses never answer it, and waiting longer only
        // makes every connect feel like the app froze.
        // Order matters, and the source says so: SecureLink.open() ends with
        // "EndLinkSetup is NOT sent here", and finishLinkSetup() sends it as *the first encrypted
        // DATA frame*. Trust rides svc36 after that; sending trust first is what produced
        // "sealed (114B) … twelve seconds of nothing".
        do {
            try endLinkSetup(timeout: min(timeout, 2), continueOnPeerTrust: trust)
        } catch LinkError.unexpected(let reason) {
            emit("EndLinkSetup 未应答（\(reason)）")
        }
        if trust {
            try doTrust(timeout: timeout)
            ownerTrustCompleted = true
        }
    }

    static func peerTrustReplyChannel(_ message: DataX.Message) -> UInt16? {
        guard message.channel > DataX.chSetup, message.service == AirShield.svcIdentity,
              message.error == nil,
              message.type == Int(AirShield.idEnableTrust) || message.type == Int(AirShield.idEnableTrustEC)
        else { return nil }
        return message.channel ^ 0x8000
    }

    private func doTrust(timeout: TimeInterval) throws {
        let channel = allocChannel("trust")
        let statusChannel = channel ^ 0x8000
        let sig = try owner.signRaw(digest: binding)
        try sendAny(try AirShield.trustMessage(channel: channel, ownerPubkey: owner.publicKeyXy, signatureRaw: sig))
        emit("trust: sent signed request on ch=0x\(String(channel, radix: 16))")

        let deadline = Date().addingTimeInterval(timeout)
        var receivedAcceptance = false
        var acknowledgedPeer = false
        var deferred: [DataX.Message] = []
        defer { pendingSetupMessages.insert(contentsOf: deferred, at: 0) }
        while !(receivedAcceptance && acknowledgedPeer) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let message: DataX.Message
            do {
                message = try recvMessage(timeout: remaining)
            } catch LinkError.unexpected(_) {
                break
            }
            if message.channel == statusChannel, let code = message.error {
                guard code == Int(AirShield.stSuccess) else {
                    throw LinkError.trustRejected(UInt16(truncatingIfNeeded: code))
                }
                receivedAcceptance = true
            } else if let replyChannel = Self.peerTrustReplyChannel(message) {
                // Acknowledge the peer's message independently of the result of our signed request.
                try sendStatus(replyChannel, AirShield.stSuccess)
                acknowledgedPeer = true
                emit("trust: acknowledged peer on ch=0x\(String(replyChannel, radix: 16))")
            } else {
                deferred.append(message)
            }
        }
        guard receivedAcceptance && acknowledgedPeer else {
            let step = receivedAcceptance ? "未收到眼镜的主人验证消息" : "眼镜未确认本机的签名请求"
            throw LinkError.unexpected("主人验证超时：\(step)")
        }
        emit("trust ok (0x1000)")
    }

    /// Wait for the mirror status. The reader answers peer setup requests as they arrive.
    private func endLinkSetup(timeout: TimeInterval, continueOnPeerTrust: Bool) throws {
        let frame = try AirShield.endLinkSetup(streamUUID: streamUUID, linkUUID: linkUUID)
        emit("EndLinkSetup (\(frame.count)B)")
        try sendAny(frame)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let m = try recvMessage(timeout: max(0.5, deadline.timeIntervalSinceNow), includePending: false)
            guard m.channel == DataX.chSetupMirror, m.service == nil, m.type == nil, let code = m.error else {
                // Keep early service messages, but keep their status replies out of trust.
                if m.error == nil { pendingSetupMessages.append(m) }
                if continueOnPeerTrust, Self.peerTrustReplyChannel(m) != nil { return }
                continue
            }
            guard code == Int(AirShield.stSuccess) || code == Int(AirShield.stOK) else {
                throw LinkError.serviceError("EndLinkSetup", UInt16(truncatingIfNeeded: code))
            }
            emit("link up")
            return
        }
        throw LinkError.unexpected("EndLinkSetup: no status frame from the glasses")
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
    func sendOnService(_ name: String, service: Int, type: UInt16, payload: Data = Data(),
                       tracePayload: Bool = true) throws {
        let ch = serviceChannel(name, service: service)
        var tags: [Data] = []
        if !servicesNamed.contains(ch) {
            tags.append(DataX.tag(1, UInt16(service), last: false))
            servicesNamed.insert(ch)
        }
        tags.append(DataX.tag(2, type, last: true))
        try sendAny(DataX.message(ch, tags: tags, payload: payload),
                    tracePayload: tracePayload && service != Int(Assistant.service) && service != 10)
    }

    private var servicesNamed: Set<UInt16> = []

    /// The next message from any channel, for a reader loop that owns the link.
    func nextMessage(timeout: TimeInterval, tracePayload: Bool = true) throws -> DataX.Message {
        try recvMessage(timeout: timeout, tracePayload: tracePayload)
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
                // svc36 answers with 0x1000 (SUCCESS) on the mirror channel; 0x0000 also
                // appears on plain data frames. Treating only the latter as success is what
                // made an earlier build report "trust rejected" for a correct answer.
                if e != Int(AirShield.stOK), e != Int(AirShield.stSuccess) {
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

    private var requestedCaptureAsset: UUID?

    func captureList(timeout: TimeInterval = 15) throws -> [Capture] {
        let ch = serviceChannel("captures", service: Self.svcCaptures)
        let mirror = ch ^ 0x8000
        try sendOnService("captures", service: Self.svcCaptures, type: Self.capEnum)
        var out: [Capture] = []
        var lastType: Int?
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("capture enumeration did not finish") }
            let m = try recvMessage(timeout: left)
            guard m.channel == mirror else { continue }
            if let code = m.error {
                guard code == Int(AirShield.stSuccess) || code == Int(AirShield.stOK) else {
                    throw LinkError.serviceError("capture enumeration", UInt16(truncatingIfNeeded: code))
                }
                continue
            }
            if let type = m.type { lastType = type }
            if lastType == Int(Self.capEnd) { return out }
            if lastType == Int(Self.capRecord), let cap = Self.parseCapture(m.payload) {
                out.append(cap)
            }
        }
    }

    func requestCaptureDeletion(handle: String, timeout: TimeInterval = 8) throws {
        guard ownerTrustCompleted else { throw LinkError.unexpected("删除前需要验证眼镜主人身份") }
        let payload = Data(handle.utf8)
        // One sealed frame allows 4,095 plaintext bytes. Reserve 12 for DataX and its tags.
        guard !payload.isEmpty, payload.count <= 4_083, !payload.contains(0) else {
            throw LinkError.unexpected("无法识别要删除的素材")
        }
        let channel = serviceChannel("captures", service: Self.svcCaptures)
        let mirror = channel ^ 0x8000
        try sendOnService("captures", service: Self.svcCaptures, type: Self.capDelete, payload: payload)

        let failurePrefix = payload + Data([0x3A])
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            let message: DataX.Message
            do { message = try recvMessage(timeout: deadline.timeIntervalSinceNow, tracePayload: false) }
            catch LinkError.unexpected(_) { break }
            guard message.channel == mirror, message.service == nil || message.service == Self.svcCaptures else { continue }
            if let error = message.error {
                if error != Int(AirShield.stOK), error != Int(AirShield.stSuccess) {
                    throw LinkError.serviceError("删除素材", UInt16(truncatingIfNeeded: error))
                }
                continue
            }
            var reply = message.payload
            while reply.last == 0 { reply.removeLast() }
            if message.type == Int(Self.capDeleteOK), reply == payload { return }
            if message.type == Int(Self.capDeleteFailed), reply.starts(with: failurePrefix) {
                throw LinkError.unexpected("眼镜拒绝删除该素材")
            }
        }
        throw LinkError.unexpected("眼镜未确认删除，请刷新相册核对")
    }

    func requestAsset(handle: String, assetID: String) throws {
        let payload = Data("\(handle):\(assetID)".utf8)
        try sendOnService("captures", service: Self.svcCaptures, type: Self.capRequestAsset, payload: payload)
        // A full capture is queued on the Bluetooth link. The asset request also covers an
        // asset the glasses have delivered before, which the capture request may skip.
        try sendOnService("captures", service: Self.svcCaptures, type: Self.capSetLink,
                          payload: Data("\(handle):1".utf8))
        requestedCaptureAsset = UUID(uuidString: assetID)
        emit("media: requested selected asset over Bluetooth")
    }

    /// Queue before switching transport. The same capture catalog is shared by both links.
    func queueAssetForMediaWiFi(handle: String, assetID: String, delivered: Bool) throws {
        guard ownerTrustCompleted, !handle.isEmpty, handle.utf8.count <= 1024,
              !handle.contains(":"), !handle.utf8.contains(0), UUID(uuidString: assetID) != nil else {
            throw LinkError.unexpected("无法验证 Wi-Fi 导入的素材。")
        }
        if delivered {
            try sendOnService("captures", service: Self.svcCaptures, type: Self.capRequestAsset,
                              payload: Data("\(handle):\(assetID)".utf8))
        }
        try sendOnService("captures", service: Self.svcCaptures, type: Self.capSetLink,
                          payload: Data("\(handle):7".utf8))
    }

    static func parseCapture(_ body: Data) -> Capture? {
        let b = [UInt8](body)
        do {
            let root = try FB.root(b)
            let wrapped = try FB.table(b, root, 0)
            let info = wrapped ?? root
            // Wire vtable slots are byte offsets. Older direct records use field indices.
            let slot: (Int) -> Int = wrapped == nil ? { $0 } : { ($0 - 4) / 2 }
            guard let handle = try FB.string(b, info, slot(4)), !handle.isEmpty else { return nil }
            let kind = try FB.scalar(b, info, slot(8))
            var ts: Int?
            if let meta = try FB.table(b, info, slot(12)) {
                let offset = try FB.fieldOffset(b, meta, slot(4))
                if offset != 0 {
                    let time = meta + offset
                    let low = UInt64(try FB.u32(b, time))
                    let high = wrapped == nil ? 0 : UInt64((try? FB.u32(b, time + 4)) ?? 0)
                    ts = Int(exactly: high << 32 | low)
                }
            }
            var assets: [CaptureAsset] = []
            for a in try FB.tableVector(b, info, slot(10)) {
                guard let uuid = try FB.string(b, a, slot(4)), !uuid.isEmpty else { continue }
                let word = try FB.scalar(b, a, slot(6))
                assets.append(CaptureAsset(uuid: uuid,
                                           type: word & 0xFF,
                                           delivered: word & 0x100000 != 0,
                                            size: try FB.scalar(b, a, slot(12))))
            }
            return Capture(handle: handle, kind: kind, timestampNS: ts, assets: assets)
        } catch {
            return nil
        }
    }

    // MARK: svc20 airship

    struct Transfer { let name: String; let size: Int; let data: Data }

    struct AirshipOffer {
        let channel: UInt16
        let id: Data
        let name: String
        let namespace: String
        let size: Int

        var mirror: UInt16 { channel ^ 0x8000 }
    }

    static func airshipOffer(_ message: DataX.Message) throws -> AirshipOffer? {
        guard message.channel & 0x8000 != 0, message.error == nil, message.service == Self.svcAirship,
              message.type == Int(Self.airOffer) || message.type == Int(Self.airOfferMultiscope)
        else { return nil }
        let fields = try PB.parse(message.payload)
        let size = fields[2]?.first as? Int ?? 0
        guard let id = fields[1]?.first as? Data, id.count == 16, size >= 0 else {
            throw LinkError.unexpected("invalid Airship file offer")
        }
        let name = fields[4]?.first as? Data
        let namespace = fields[3]?.first as? Data ?? Data()
        return AirshipOffer(channel: message.channel, id: id,
                            name: name.map { String(decoding: $0, as: UTF8.self) } ?? "capture.bin",
                            namespace: String(decoding: namespace, as: UTF8.self), size: size)
    }

    private func rejectUnrequestedAirshipOffer(_ message: DataX.Message) throws -> Bool {
        guard serviceChannels["captures"] != nil, let offer = try Self.airshipOffer(message) else { return false }
        // Drop answers this queue entry. Deleting a capture is a separate svc18 command.
        try sendAirshipReply(Self.airDrop, on: offer.mirror, payload: PB.bytes(1, offer.id))
        emit("media: declined an unrequested Airship offer")
        return true
    }

    /// The glasses open the transfer channel. Cursor and Drop use its mirror.
    func receiveFile(timeout: TimeInterval = 120, maximumDuration: TimeInterval? = nil,
                     expectedAssetID: String? = nil,
                     onBytes: ((Int, Int) -> Void)? = nil) throws -> Transfer? {
        let expectedAsset: UUID?
        if let expectedAssetID {
            guard let asset = UUID(uuidString: expectedAssetID) else {
                throw LinkError.unexpected("无法识别要导入的文件。")
            }
            expectedAsset = asset
        } else {
            expectedAsset = requestedCaptureAsset
        }
        let wantedID = expectedAsset.map { asset in withUnsafeBytes(of: asset.uuid) { Data($0) } }
        requestedCaptureAsset = nil
        let capturesMirror = serviceChannels["captures"].map { $0 ^ 0x8000 }
        var accepted: AirshipOffer?
        var lastType: Int?
        var buf = Data()
        var checksum: UInt32 = 1
        let maximumDeadline = maximumDuration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        var idleDeadline = Date().addingTimeInterval(timeout)
        while true {
            let left = min(idleDeadline, maximumDeadline).timeIntervalSinceNow
            if left <= 0 { throw LinkError.unexpected("眼镜文件传输超时，请重试。") }
            let m: DataX.Message
            do {
                m = try recvMessage(timeout: left, handlesAirshipOffers: true, bulkChannel: accepted?.channel)
            } catch LinkError.unexpected(let reason) where reason.hasPrefix("timeout waiting for a frame") {
                throw LinkError.unexpected("眼镜文件传输暂停过久，请重试。")
            }
            if m.channel == capturesMirror {
                if m.type == Int(Self.capAssetGone) {
                    throw LinkError.unexpected("the selected asset is no longer on the glasses")
                }
                if m.type == Int(Self.capAssetQueued) || m.type == Int(Self.capLinkSet) {
                    emit("media: glasses acknowledged the transfer request")
                }
                continue
            }
            guard m.channel & 0x8000 != 0, m.error == nil else { continue }
            let mirror = m.channel ^ 0x8000
            if let offer = try Self.airshipOffer(m) {
                guard accepted == nil || (accepted?.channel == m.channel && accepted?.id == offer.id),
                      offer.namespace == "namespace_media", wantedID == nil || wantedID == offer.id else {
                    try sendAirshipReply(Self.airDrop, on: mirror, payload: PB.bytes(1, offer.id))
                    continue
                }
                if accepted == nil { idleDeadline = Date().addingTimeInterval(timeout) }
                accepted = offer
                lastType = m.type
                buf.removeAll(keepingCapacity: true)
                checksum = 1
                try sendAirshipReply(Self.airCursor, on: mirror, payload: PB.uint(2, 1))
                emit("media: accepted selected Airship offer (\(offer.size)B)")
                continue
            }
            guard let offer = accepted, m.channel == offer.channel else { continue }
            if let type = m.type { lastType = type }
            guard let t = lastType else { continue }
            switch UInt16(t) {
            case Self.airData:
                guard m.payload.count <= offer.size - buf.count else {
                    try sendAirshipReply(Self.airDrop, on: mirror, payload: PB.bytes(1, offer.id))
                    throw LinkError.unexpected("file data exceeds the offered size")
                }
                buf.append(m.payload)
                if !m.payload.isEmpty { idleDeadline = Date().addingTimeInterval(timeout) }
                checksum = Self.updateAdler32(checksum, with: m.payload)
                onBytes?(buf.count, offer.size)
            case Self.airCheck:
                let offset = buf.isEmpty ? Data() : PB.uint(1, UInt64(buf.count))
                try sendAirshipReply(Self.airCursor, on: mirror, payload: offset + PB.uint(2, UInt64(checksum)))
            case Self.airComplete:
                let fields = try? PB.parse(m.payload)
                let size = fields?[1]?.first as? Int ?? 0
                let adler = fields?[2]?.first as? Int
                try sendAirshipReply(Self.airDrop, on: mirror, payload: PB.bytes(1, offer.id))
                guard fields != nil, size == offer.size, size == buf.count, adler == Int(checksum) else {
                    throw LinkError.unexpected("file size or checksum did not match")
                }
                return Transfer(name: offer.name, size: size, data: buf)
            case Self.airReset:
                buf.removeAll(keepingCapacity: true)
                checksum = 1
                onBytes?(0, offer.size)
            case Self.airStopped:
                // Large Bluetooth files may be offered again after the glasses pause them.
                accepted = nil
                lastType = nil
                buf.removeAll(keepingCapacity: false)
                checksum = 1
                onBytes?(0, offer.size)
                emit("media: glasses paused the transfer; waiting for a new offer")
            case Self.airDrop, Self.airRemoved:
                throw LinkError.unexpected("transfer aborted by the glasses (\(t))")
            default:
                continue
            }
        }
    }

    private func sendAirshipReply(_ type: UInt16, on channel: UInt16, payload: Data) throws {
        try sendAny(DataX.message(channel, tags: [DataX.tag(2, type, last: true)], payload: payload))
    }

    static func adler32(_ data: Data) -> UInt32 {
        updateAdler32(1, with: data)
    }

    private static func updateAdler32(_ checksum: UInt32, with data: Data) -> UInt32 {
        var a = checksum & 0xFFFF
        var b = checksum >> 16
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: svc33 RLDrive — the settings store

    private var drivePeerChannels: Set<UInt16> = []

    private func driveReply(_ message: DataX.Message, on channel: UInt16, namespace: String,
                            requestID: String, assembler: Drive.Assembler) throws -> Drive.Reply? {
        if let service = message.service {
            guard service == Drive.service else {
                drivePeerChannels.remove(message.channel)
                return nil
            }
            if message.channel & 0x8000 != 0 { drivePeerChannels.insert(message.channel) }
        }
        let mirror = channel ^ 0x8000
        guard message.channel == channel || message.channel == mirror || drivePeerChannels.contains(message.channel) else {
            return nil
        }
        if let code = message.error {
            if message.channel == mirror, code != Int(AirShield.stOK), code != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("设置同步", UInt16(truncatingIfNeeded: code))
            }
            return nil
        }
        guard message.type == nil || message.type == Int(Drive.syncMessage),
              let whole = assembler.add(message.payload), let reply = Drive.decode(whole),
              reply.namespace == namespace, reply.requestID == requestID else { return nil }
        return reply
    }

    /// Every object the glasses keep in `namespace`; settings live in `Drive.deviceSettings`.
    func driveObjects(namespace: String = Drive.deviceSettings,
                      types: [String] = Drive.defaultTypes,
                      timeout: TimeInterval = 8) throws -> [Drive.Object] {
        let ch = serviceChannel("drive", service: Drive.service)
        let requestID = UUID().uuidString.lowercased()
        let sync = Drive.build(namespace: namespace, requestID: requestID, round: 0, types: types)
        try sendOnService("drive", service: Drive.service, type: Drive.syncMessage, payload: sync)
        let assembler = Drive.Assembler()
        var collected: [Drive.Object] = []
        var receivedValues = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m: DataX.Message
            do { m = try recvMessage(timeout: left) }
            catch LinkError.unexpected(_) where receivedValues { break }
            guard let reply = try driveReply(m, on: ch, namespace: namespace,
                                             requestID: requestID, assembler: assembler) else { continue }
            if reply.round == 1 {
                collected += reply.objects
                if !receivedValues {
                    let replyTypes = Set(reply.types.keys).union([Drive.kv]).sorted()
                    let acknowledgement = Drive.build(namespace: namespace, requestID: requestID, round: 2,
                                                      known: reply.types, types: replyTypes, usecaseTag: reply.usecaseTag)
                    try sendOnService("drive", service: Drive.service, type: Drive.syncMessage, payload: acknowledgement)
                    receivedValues = true
                }
            }
            if reply.terminated { break }
        }
        guard receivedValues else { throw LinkError.unexpected("眼镜没有返回此设置读取的值") }
        emit("drive \(namespace): \(collected.count) objects")
        return collected
    }

    /// Writes one setting the way another replica would: present a newer version of the object.
    /// The ack proves nothing on this service, so the value is read back before reporting success.
    @discardableResult
    func driveWrite(key: String, value: String, namespace: String = Drive.deviceSettings,
                    timeout: TimeInterval = 8) throws -> Bool {
        let ch = serviceChannel("drive", service: Drive.service)
        let known = try driveObjects(namespace: namespace, timeout: timeout)
        var versions: Drive.Versions = [:]
        for object in known {
            versions[object.type, default: [:]][Drive.localWriter] = (versions[object.type]?[Drive.localWriter] ?? 0) + 1
        }
        let requestID = UUID().uuidString.lowercased()
        let object = Drive.Object(uri: key, type: Drive.kv, data: value, deleted: false, raw: Data())
        let sync = Drive.build(namespace: namespace, requestID: requestID, round: 1,
                               known: versions, types: [Drive.kv], objects: [object])
        try sendOnService("drive", service: Drive.service, type: Drive.syncMessage, payload: sync)
        let assembler = Drive.Assembler()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let m = try recvMessage(timeout: left)
            if let reply = try driveReply(m, on: ch, namespace: namespace,
                                          requestID: requestID, assembler: assembler), reply.terminated { break }
        }
        let after = try driveObjects(namespace: namespace, timeout: timeout)
        return after.contains { $0.uri == key && !$0.deleted && $0.data == value }
    }

    // MARK: svc28 device state

    private func statusChannel() -> UInt16 { serviceChannel("status", service: Status.service) }

    private static let cameraStateType = 2009

    private func deviceStatusType(_ message: DataX.Message, channel: UInt16, lastType: inout Int?) -> Int? {
        guard message.channel == (channel ^ 0x8000), message.error == nil,
              message.service == nil || message.service == Status.service else { return nil }
        if let type = message.type { lastType = type }
        guard let type = lastType, Status.isStateType(type) else { return nil }
        return type
    }

    /// Subscribes (or re-asks on the existing channel) and merges pushes until the snapshot has
    /// battery and storage, allowing one short grace window for volume and case updates.
    func subscribeStatus(timeout: TimeInterval = 4, requireReport: Bool = true) throws -> GlassesState {
        let ch = statusChannel()
        let mirror = ch ^ 0x8000
        try sendOnService("status", service: Status.service, type: Status.mtInit, payload: Status.subscribePayload())

        var state = GlassesState()
        var lastType: Int?
        var optionalStatusDeadline: Date?
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = min(deadline, optionalStatusDeadline ?? deadline).timeIntervalSinceNow
            if left <= 0 { break }
            let m: DataX.Message
            do { m = try recvMessage(timeout: left) } catch LinkError.unexpected(_) { break }
            guard m.channel == mirror, m.service == nil || m.service == Status.service else { continue }
            if let code = m.error {
                guard code == Int(AirShield.stOK) || code == Int(AirShield.stSuccess) else {
                    throw LinkError.serviceError("设备状态", UInt16(truncatingIfNeeded: code))
                }
                continue
            }
            if m.type == Status.mtInitAck { statusSubscribed = true }
            guard deviceStatusType(m, channel: ch, lastType: &lastType) != nil else { continue }
            Status.merge(m.payload, into: &state)
            if state.hasReportedState { statusSubscribed = true }
            if state.batteryPercent != nil, state.storageFreeMb != nil {
                if state.receivedVolume, state.receivedCaseBattery { break }
                if optionalStatusDeadline == nil { optionalStatusDeadline = Date().addingTimeInterval(0.65) }
            }
        }
        if requireReport, !state.hasReportedState {
            throw LinkError.unexpected("眼镜没有返回设备状态")
        }
        emit("status: \(state.lines.joined(separator: " / "))")
        return state
    }

    func confirmedShutter(_ payload: Data, matching confirmed: (Int) -> Bool) throws -> GlassesState {
        if !statusSubscribed { _ = try subscribeStatus(timeout: 2, requireReport: false) }
        let ch = statusChannel()
        try sendOnService("status", service: Shutter.service, type: Shutter.mtSnIntent, payload: payload)

        let deadline = Date().addingTimeInterval(5)
        var state = GlassesState()
        var lastType: Int?
        while deadline.timeIntervalSinceNow > 0 {
            let message: DataX.Message
            do { message = try recvMessage(timeout: deadline.timeIntervalSinceNow) }
            catch LinkError.unexpected(_) { break }
            if message.channel == (ch ^ 0x8000), let code = message.error,
               code != Int(AirShield.stOK), code != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("拍摄请求", UInt16(truncatingIfNeeded: code))
            }
            guard let type = deviceStatusType(message, channel: ch, lastType: &lastType) else { continue }
            Status.merge(message.payload, into: &state)
            guard type == Self.cameraStateType, let camera = Status.cameraCode(message.payload) else { continue }
            if camera == 4 || camera == 6 { throw LinkError.unexpected("眼镜报告拍摄失败") }
            if confirmed(camera) { return state }
        }
        throw LinkError.unexpected("眼镜没有确认拍摄状态")
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
