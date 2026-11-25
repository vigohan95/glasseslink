import Compression
import Foundation

/// The authenticated text assistant session on service 15.
final class Assistant {
    static let service: UInt16 = 15

    // Message types on the channel.
    enum MT {
        static let pairedDeviceAndroid: Int32 = 11
        static let initMessageRequest: Int32 = 1000
        static let initMessageResponse: Int32 = 1001
        static let segmentedHeader: Int32 = 1002
        static let segmentedBuffer: Int32 = 1003
        static let netEvent: Int32 = 1010
        static let deviceActive: Int32 = 1016
        static let startInteraction: Int32 = 1023
        static let runningLocale: Int32 = 1026
        static let numOfDevicesPaired: Int32 = 1029
        static let airResourcesUnavailable: Int32 = 1031
        static let airResourcesAvailable: Int32 = 1032
        static let liveModeUnavailable: Int32 = 1038
        static let liveModeAvailable: Int32 = 1039
        static let initStreamRequest: Int32 = 5000
        static let initStreamResponse: Int32 = 5001
        static let streamHeader: Int32 = 5002
        static let streamAudio: Int32 = 5003
        static let streamEnd: Int32 = 6000
        static let envelope: Int32 = 9000
        static let envelopeAck: Int32 = 9001
    }

    // NetEvent ids we care about.
    enum EV {
        static let finalTranscription = 52
        static let voiceAnswer = 53
        static let fulfillmentRequest = 57
        static let interactionClosed = 59
        static let voiceComplete = 60
        static let startOfUserSpeech = 71
        static let sessionModeUpdateResponse = 289
        static let sessionStateBroadcast = 333
        static let sessionStateUpdate = 339
        static let onPhoneUnderstanding = 342
        static let remoteInteractionComplete = 360
        static let keepAirSessionAlive = 392
    }

    private let session: Session
    private let clientId = UUID().uuidString
    private let stateLock = NSLock()
    private let eventWriteLock = NSLock()
    private(set) var protocolVersion = 0
    private(set) var locale = ""
    private var registrationComplete = false
    private var stopped = false
    private var running = false
    private var turn: Turn?
    private var recentInteractions: [String] = []
    private var segments: [Data: Segment] = [:]
    private var incomingTypes = IncomingTypes()
    private var m0: UInt16 = 0
    private var s0: UInt16 = 0

    private enum Endpoint: String {
        case messages = "assistant-m0"
        case stream = "assistant-s0"
    }

    struct Turn {
        let wakeID: String
        var relatedWakeID: String?
        var requestID: String?
        var simplified = true
        var supportsSpeech: Bool?
        var replying = false
        var microphone: MicrophoneStream?
        var confirmedSpeechStart = false
        var deadline = ProcessInfo.processInfo.systemUptime + 30
        var keepaliveSequence = 0
        var nextKeepalive = TimeInterval.infinity

        func includes(_ id: String) -> Bool {
            wakeID == id || relatedWakeID == id || requestID == id
        }

        mutating func claimSpeechStart(_ fields: [Int: Any]) -> String? {
            // Mode 2 is Live AI. Its audio belongs to a separate flow.
            guard !confirmedSpeechStart, requestID == nil, supportsSpeech != false,
                  deadline > ProcessInfo.processInfo.systemUptime,
                  let mode = fields.int(2), mode >= 0, mode != 2 else { return nil }
            let interaction = fields.text(1)
            guard !interaction.isEmpty, includes(interaction) else { return nil }
            confirmedSpeechStart = true
            return interaction
        }
    }

    struct MicrophoneStream {
        private(set) var frames = 0
        private(set) var bytes = 0
        private(set) var endedAt: TimeInterval?
        var reportedMissingTranscript = false

        mutating func noteAudio(bytes count: Int) {
            guard endedAt == nil, count > 0 else { return }
            frames = min(frames + 1, 4_096)
            bytes += min(count, 1_048_576 - bytes)
        }

        mutating func finish(at time: TimeInterval) -> Bool {
            guard endedAt == nil else { return false }
            endedAt = time
            return true
        }

        func shouldReportMissingTranscript(at time: TimeInterval) -> Bool {
            guard let endedAt else { return false }
            return frames > 0 && !reportedMissingTranscript && time - endedAt >= 3
        }
    }

    struct IncomingTypes {
        private var last: [UInt16: Int] = [:]

        // DataX delta-encodes types per wire channel. Status-only frames never inherit a type.
        mutating func resolve(_ message: DataX.Message) -> Int? {
            guard message.error == nil else { return nil }
            if let type = message.type { last[message.channel] = type }
            return last[message.channel]
        }
    }

    private struct Segment {
        let type: Int32
        let size: Int
        let expires = ProcessInfo.processInfo.systemUptime + 15
        var bytes = Data()
    }

    private static let segmentBytes = 1024
    private static let maxMessageBytes = 64 * 1024

    var log: (String) -> Void = { _ in }
    /// A wake alone only updates the UI.
    var onTurn: ((String) -> Void)?
    /// (transcript, interaction): an actual spoken question from the glasses.
    var onTranscript: ((String, String) -> Void)?
    /// A finished plain microphone turn had audio but the glasses did not provide usable text.
    var onAudioWithoutTranscript: (() -> Void)?
    var onTurnEnded: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    var registered: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return registrationComplete && !stopped
    }

    init(session: Session) {
        self.session = session
    }

    // MARK: registration

    func register(timeout: TimeInterval = 8) throws {
        try checkRegistrationActive()
        let registrationID = timedID()
        m0 = session.serviceChannel(Endpoint.messages.rawValue, service: Int(Self.service))
        try write(MT.initMessageRequest, registration(registrationID, endpoint: "\(clientId)-m0"))
        let response = try awaitRegistration(MT.initMessageResponse, channel: m0, timeout: timeout / 2)
        protocolVersion = Self.registrationVersion(response)
        log("assistant: message registration confirmed (protocol \(protocolVersion))")

        s0 = session.serviceChannel(Endpoint.stream.rawValue, service: Int(Self.service))
        try write(MT.initStreamRequest, registration(registrationID, endpoint: "\(clientId)-s0"), on: .stream)
        _ = try awaitRegistration(MT.initStreamResponse, channel: s0, timeout: timeout / 2)
        log("assistant: stream registration confirmed")

        let resources: [(Int32, Data)] = [
            (MT.pairedDeviceAndroid, PB.string(1, timedID())),
            (MT.airResourcesUnavailable, idOnly()),
            (MT.liveModeUnavailable, idOnly()),
            (MT.deviceActive, Data()),
            (MT.numOfDevicesPaired, Data("1".utf8)),
            (MT.liveModeAvailable, idOnly()),
            (MT.airResourcesAvailable, idOnly()),
        ]
        for (type, payload) in resources {
            try write(type, payload)
        }
        try announce()
        try checkRegistrationActive()
        stateLock.lock()
        registrationComplete = !stopped
        stateLock.unlock()
        log("assistant: registration complete; waiting for a glasses interaction")
    }

    private func idOnly() -> Data { PB.string(1, UUID().uuidString) }

    private func timedID() -> String { "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)" }

    private func registration(_ id: String, endpoint: String) -> Data {
        PB.string(1, id) + PB.string(2, clientId) + PB.string(3, endpoint) + PB.uint(4, 2)
    }

    private func checkRegistrationActive() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if stopped { throw CancellationError() }
    }

    private func awaitRegistration(_ type: Int32, channel: UInt16, timeout: TimeInterval) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try checkRegistrationActive()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  let message = try nextIfAvailable(timeout: remaining) else {
                throw LinkError.unexpected("助手注册未收到眼镜确认（\(type)）")
            }
            let awaitingChannel = accepts(message, on: channel)
            let messageChannel = accepts(message, on: m0)
            guard awaitingChannel || messageChannel else { continue }
            let receivedType = incomingTypes.resolve(message)
            if awaitingChannel {
                try checkStatus(message, operation: "助手注册 \(type)")
                if receivedType == Int(type) { return message.payload }
            }
            if messageChannel, receivedType == Int(MT.runningLocale) {
                readLocale(message.payload)
            }
        }
    }

    static func registrationVersion(_ payload: Data) -> Int {
        if payload.count == 4 {
            return payload.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        guard payload.count > 4 else { return 0 }
        return (try? PB.parse(payload))?[1]?.first as? Int ?? 0
    }

    private func accepts(_ message: DataX.Message, on channel: UInt16) -> Bool {
        channel != 0 && (message.channel == channel || message.channel == (channel ^ 0x8000))
            && (message.service == nil || message.service == Int(Self.service))
    }

    private func checkStatus(_ message: DataX.Message, operation: String) throws {
        if let code = message.error, code != Int(AirShield.stOK), code != Int(AirShield.stSuccess) {
            throw LinkError.serviceError(operation, UInt16(truncatingIfNeeded: code))
        }
    }

    private func nextIfAvailable(timeout: TimeInterval) throws -> DataX.Message? {
        do {
            return try session.nextMessage(timeout: timeout, tracePayload: false)
        } catch LinkError.unexpected(let message) where message.hasPrefix("timeout waiting for a frame") {
            return nil
        }
    }

    private func announce() throws {
        let sid = UUID().uuidString
        var events: [(Int, Data)] = [
            (265, ThriftWriter().string(1, sid).bool(2, true).bool(3, false)
                .string(4, UUID().uuidString.uppercased()).string(5, "prod.facebookvirtualassistant.com")
                .string(6, "ble").string(10, timedID())
                .bool(11, false).bool(13, true).bool(14, false).done()),
            (263, ThriftWriter().string(1, sid).bool(2, false).bool(3, false).i32(4, 1).bool(7, false).done()),
            (263, ThriftWriter().string(1, sid).bool(2, true).bool(3, false).i32(4, 2).done()),
        ]
        events.append((262, ThriftWriter().string(1, sid).i32(2, 1).i32(3, 0).done()))
        for (event, body) in events {
            try send(event, body)
        }
    }

    /// NetEvent carrier: field 4 must be I64 or the glasses drop the whole event silently.
    func netEvent(_ eventId: Int, _ body: Data) -> Data {
        ThriftWriter().i32(1, Int32(eventId)).binary(2, body).bool(3, false)
            .i64(4, Int64(body.count)).bool(11, false).done()
    }

    // MARK: turn loop

    func startLoop() {
        stateLock.lock()
        guard registrationComplete, !running, !stopped else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()
        let worker = Thread { [weak self] in self?.loop() }
        worker.name = "assistant"
        worker.start()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        running = false
        turn = nil
        stateLock.unlock()
    }

    private func loop() {
        do {
            while registered {
                if let message = try nextIfAvailable(timeout: receiveTimeout), registered {
                    try handle(message)
                }
                try maintainTurn()
            }
        } catch {
            guard registered else { return }
            stop()
            DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
        }
    }

    private var receiveTimeout: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Incoming frames wake the transport immediately. Only an active turn has time-based work.
        return turn == nil ? 15 : 1
    }

    private func handle(_ message: DataX.Message) throws {
        if accepts(message, on: s0) {
            try checkStatus(message, operation: "助手语音通道")
            guard let type = incomingTypes.resolve(message) else { return }
            switch type {
            case Int(MT.streamHeader):
                if let fields = try? PB.parse(message.payload),
                   let bytes = fields[2]?.first as? Data,
                   let interaction = String(data: bytes, encoding: .utf8) {
                    beginTurn(interaction)
                    stateLock.lock()
                    if turn?.includes(interaction) == true, turn?.microphone == nil {
                        turn?.microphone = MicrophoneStream()
                    }
                    stateLock.unlock()
                }
            case Int(MT.streamAudio), 0:
                stateLock.lock()
                turn?.microphone?.noteAudio(bytes: message.payload.count)
                stateLock.unlock()
            case Int(MT.streamEnd):
                finishMicrophoneStream()
            default:
                break
            }
            return
        }
        guard accepts(message, on: m0) else { return }
        try checkStatus(message, operation: "助手消息通道")
        guard let type = incomingTypes.resolve(message) else { return }
        switch Int32(truncatingIfNeeded: type) {
        case MT.envelope:
            guard let fields = try? PB.parse(message.payload) else { return }
            if let id = fields[1]?.first as? Int {
                try write(MT.envelopeAck, PB.uint(1, UInt64(bitPattern: Int64(id))))
            }
            if let innerType = fields[2]?.first as? Int, let kind = Int32(exactly: innerType),
               let inner = fields[3]?.first as? Data {
                try handleInner(kind, inner)
            }
        case MT.runningLocale:
            readLocale(message.payload)
        default:
            try handleInner(Int32(truncatingIfNeeded: type), message.payload)
        }
    }

    private func readLocale(_ payload: Data) {
        let nested = (try? PB.parse(payload))?[1]?.first as? Data
        if let value = String(data: nested ?? payload, encoding: .utf8), value != locale {
            locale = value
        }
    }

    private func handleInner(_ type: Int32, _ payload: Data) throws {
        switch type {
        case MT.startInteraction:
            guard let fields = try? ThriftCompact.loads(payload) else { return }
            // The plain text route has no on-device media, typed, or partner session handling.
            let useCase = fields.int(5)
            let partner = fields.structField(18).text(30).hasPrefix("3p_")
            beginTurn(fields.text(1), supportsSpeech: useCase != 3 && useCase != 7 && !partner && !fields.bool(55))
        case MT.segmentedHeader, MT.segmentedBuffer:
            try appendSegment(type, payload)
        case MT.netEvent:
            try handleEvent(payload)
        default:
            break
        }
    }

    private func appendSegment(_ type: Int32, _ payload: Data) throws {
        guard let fields = try? PB.parse(payload) else { return }
        let idField = type == MT.segmentedHeader ? 3 : 2
        guard let id = fields[idField]?.first as? Data, !id.isEmpty, id.count <= 64 else { return }
        if type == MT.segmentedHeader {
            let now = ProcessInfo.processInfo.systemUptime
            segments = segments.filter { $0.value.expires > now }
            guard let size = fields[2]?.first as? Int, (1...Self.maxMessageBytes).contains(size),
                  let kind = fields[1]?.first as? Int, kind == Int(MT.netEvent) || kind == Int(MT.startInteraction),
                  segments.count < 4, segments[id] == nil else { return }
            segments[id] = Segment(type: Int32(kind), size: size)
            return
        }
        guard var segment = segments.removeValue(forKey: id),
              segment.expires > ProcessInfo.processInfo.systemUptime,
              let bytes = fields[1]?.first as? Data, !bytes.isEmpty,
              bytes.count <= segment.size - segment.bytes.count else { return }
        segment.bytes.append(bytes)
        if (fields[3]?.first as? Int ?? 0) != 0 {
            if segment.bytes.count == segment.size { try handleInner(segment.type, segment.bytes) }
        } else if segment.bytes.count < segment.size {
            segments[id] = segment
        }
    }

    private func handleEvent(_ payload: Data) throws {
        guard payload.count <= Self.maxMessageBytes,
              let fields = try? ThriftCompact.loads(payload), let id = fields.int(1) else { return }
        guard let body = Self.netEventBody(fields), let inner = try? ThriftCompact.loads(body) else {
            if id == EV.fulfillmentRequest || id == EV.sessionModeUpdateResponse {
                log("assistant: could not decode event \(id) body (compressed=\(fields.bool(3)))")
            }
            return
        }
        switch id {
        case EV.fulfillmentRequest:
            guard let request = Self.spokenRequest(inner) else {
                log("assistant: glasses fulfillment event did not contain a supported question")
                closeTurn(inner.text(1))
                return
            }
            acceptTranscript(request.transcript, interaction: request.interaction, simplified: request.simplified)
        case EV.sessionModeUpdateResponse:
            try acknowledgeSpeechStart(inner)
        case EV.interactionClosed, EV.remoteInteractionComplete:
            closeTurn(inner.text(1))
        case EV.sessionStateUpdate:
            let reply = ThriftWriter()
            for field in inner.keys.sorted() {
                if let value = inner.int(field), let number = Int32(exactly: value) {
                    reply.i32(field, number)
                }
            }
            try send(EV.sessionStateBroadcast, reply.done())
        default:
            break
        }
    }

    static func netEventBody(_ fields: [Int: Any]) -> Data? {
        guard let body = fields.bytes(2), body.count <= maxMessageBytes else { return nil }
        if !fields.bool(3) { return body }
        // The sender uses an RFC 1950 zlib stream. Apple's Compression decoder takes raw DEFLATE.
        guard body.count > 6 else { return nil }
        let header = Int(body[body.startIndex])
        let flags = Int(body[body.startIndex + 1])
        guard header & 15 == 8, header >> 4 <= 7, (header * 256 + flags) % 31 == 0,
              flags & 32 == 0 else { return nil }
        let compressed = body.dropFirst(2).dropLast(4)
        let expectedChecksum = body.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }
        var decoded = Data(count: maxMessageBytes + 1)
        let count: Int? = compressed.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            decoded.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                guard let source = input.bindMemory(to: UInt8.self).baseAddress,
                      let destination = output.bindMemory(to: UInt8.self).baseAddress else { return nil }
                stream.pointee.src_ptr = source
                stream.pointee.src_size = input.count
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = output.count
                while true {
                    let beforeInput = stream.pointee.src_size
                    let beforeOutput = stream.pointee.dst_size
                    let result = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if result == COMPRESSION_STATUS_END, stream.pointee.src_size == 0 {
                        return output.count - stream.pointee.dst_size
                    }
                    guard result == COMPRESSION_STATUS_OK, stream.pointee.dst_size > 0,
                          beforeInput != stream.pointee.src_size || beforeOutput != stream.pointee.dst_size else { return nil }
                }
            }
        }
        guard let count, count <= maxMessageBytes else { return nil }
        decoded.removeSubrange(count..<decoded.count)
        return Session.adler32(decoded) == expectedChecksum ? decoded : nil
    }

    private func acknowledgeSpeechStart(_ fields: [Int: Any]) throws {
        stateLock.lock()
        let interaction = stopped ? nil : turn?.claimSpeechStart(fields)
        stateLock.unlock()
        guard let interaction else {
            log("assistant: session mode response did not match a pending plain turn")
            return
        }
        try send(EV.startOfUserSpeech, ThriftWriter().string(1, interaction).done())
        log("assistant: confirmed speech start for a matching glasses turn")
    }

    static func spokenRequest(_ fields: [Int: Any]) -> (interaction: String, transcript: String, simplified: Bool)? {
        let understanding = fields.structField(2)
        let onDevice = fields.structField(55)
        let fallbackIntent = onDevice.text(1)
        let intent = fields.text(23).isEmpty ? fallbackIntent : fields.text(23)
        guard intent != "IN:WAKE_WORD", intent != "IN:START_LIVE_AI" else { return nil }

        let image = understanding.structField(4)
        guard !understanding.bool(5), !image.bool(20), !onDevice.bool(8),
              image.text(3).isEmpty, image.text(8).isEmpty,
              (image.bytes(4)?.count ?? 0) <= 100, (image.bytes(16)?.count ?? 0) <= 100 else { return nil }
        let interaction = fields.text(1)
        let transcript = understanding.structField(1).text(1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interaction.isEmpty, interaction.utf8.count <= 128,
              !transcript.isEmpty, transcript.utf8.count <= Self.maxMessageBytes else { return nil }
        return (interaction, transcript, (fields[30] as? Bool) ?? true)
    }

    private func beginTurn(_ interaction: String, supportsSpeech: Bool? = nil) {
        guard !interaction.isEmpty, interaction.utf8.count <= 128 else { return }
        stateLock.lock()
        guard !stopped, !recentInteractions.contains(interaction) else {
            stateLock.unlock()
            return
        }
        if let active = turn, active.includes(interaction) {
            if let supportsSpeech { turn?.supportsSpeech = supportsSpeech }
            stateLock.unlock()
            return
        }
        // The message and microphone headers can use different IDs for the same wake.
        if let active = turn, active.requestID == nil, active.relatedWakeID == nil,
           (active.supportsSpeech == nil) != (supportsSpeech == nil) {
            turn?.relatedWakeID = interaction
            if let supportsSpeech { turn?.supportsSpeech = supportsSpeech }
            stateLock.unlock()
            return
        }
        forgetTurn()
        turn = Turn(wakeID: interaction, supportsSpeech: supportsSpeech)
        stateLock.unlock()
        notifyWake(interaction)
    }

    private func notifyWake(_ interaction: String) {
        log("assistant: received glasses wake")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registered else { return }
            self.onTurn?(interaction)
        }
    }

    private func acceptTranscript(_ transcript: String, interaction: String, simplified: Bool) {
        stateLock.lock()
        guard !stopped, !recentInteractions.contains(interaction), turn?.requestID == nil,
              turn?.supportsSpeech != false, onTranscript != nil else {
            stateLock.unlock()
            return
        }
        let newlyAwake = turn == nil
        if newlyAwake { turn = Turn(wakeID: interaction) }
        let now = ProcessInfo.processInfo.systemUptime
        turn?.requestID = interaction
        turn?.simplified = simplified
        turn?.deadline = now + 65
        turn?.nextKeepalive = now + 3
        stateLock.unlock()
        if newlyAwake { notifyWake(interaction) }
        log("assistant: received glasses fulfillment request")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRequest(interaction) else { return }
            self.onTranscript?(transcript, interaction)
        }
    }

    private func closeTurn(_ interaction: String) {
        guard !interaction.isEmpty else { return }
        stateLock.lock()
        guard let active = turn, active.includes(interaction) else {
            stateLock.unlock()
            return
        }
        forgetTurn()
        stateLock.unlock()
        notifyTurnEnded(active.requestID ?? active.wakeID)
    }

    private func forgetTurn() {
        if let active = turn {
            recentInteractions.append(active.wakeID)
            if let alias = active.relatedWakeID { recentInteractions.append(alias) }
            if let request = active.requestID, request != active.wakeID, request != active.relatedWakeID {
                recentInteractions.append(request)
            }
            if recentInteractions.count > 24 {
                recentInteractions.removeFirst(recentInteractions.count - 24)
            }
        }
        turn = nil
    }

    private func notifyTurnEnded(_ interaction: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registered else { return }
            self.onTurnEnded?(interaction)
        }
    }

    private func isCurrentRequest(_ interaction: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && turn?.requestID == interaction && turn?.supportsSpeech != false
    }

    private func finishMicrophoneStream() {
        stateLock.lock()
        let finished = turn?.microphone?.finish(at: ProcessInfo.processInfo.systemUptime) == true
            ? turn?.microphone : nil
        stateLock.unlock()
        if let finished {
            log("assistant: glasses microphone stream ended, \(finished.frames) audio frames, \(finished.bytes) audio bytes")
        }
    }

    private func notifyMissingTranscript(_ wakeID: String) {
        log("assistant: glasses sent microphone audio without a usable transcript")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let waiting = !self.stopped && self.turn?.wakeID == wakeID && self.turn?.requestID == nil
            self.stateLock.unlock()
            if waiting { self.onAudioWithoutTranscript?() }
        }
    }

    private func maintainTurn() throws {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        guard let active = turn, !active.replying else {
            stateLock.unlock()
            return
        }
        if now >= active.deadline {
            forgetTurn()
            stateLock.unlock()
            notifyTurnEnded(active.requestID ?? active.wakeID)
        } else if active.requestID == nil, active.supportsSpeech != false,
                  active.microphone?.shouldReportMissingTranscript(at: now) == true {
            turn?.microphone?.reportedMissingTranscript = true
            stateLock.unlock()
            notifyMissingTranscript(active.wakeID)
        } else if now >= active.nextKeepalive {
            let next = active.keepaliveSequence + 1
            turn?.nextKeepalive = now + 3
            turn?.keepaliveSequence = next
            stateLock.unlock()
            try send(EV.keepAirSessionAlive, ThriftWriter().string(1, "AwaitingResponse").i32(2, 20_000)
                .i32(3, Int32(next)).done())
        } else {
            stateLock.unlock()
        }
    }

    // MARK: answering

    func complete(interaction: String, text: String, transcript: String, followUp: Bool = false) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LinkError.unexpected("所选模型没有返回可发送的文字")
        }
        stateLock.lock()
        guard !stopped, let active = turn, active.requestID == interaction, active.supportsSpeech != false, !active.replying else {
            stateLock.unlock()
            throw LinkError.unexpected("眼镜的语音请求已结束")
        }
        turn?.replying = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            if turn?.requestID == interaction { forgetTurn() }
            stateLock.unlock()
        }

        guard let varm = Varm.build(interaction: interaction, transcript: transcript, text: text, onGlasses: true) else {
            throw LinkError.unexpected("缺少眼镜播报所需的语音模板")
        }
        let asks = Varm.asks.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        let completion = Varm.complete(interaction: interaction, text: text, expectsAnswer: followUp && asks,
                                       followUp: followUp)
        let speech = ThriftWriter().string(1, interaction).done()
        let transcription = ThriftWriter().string(1, transcript).i32(2, 0).string(4, "")
            .bool(7, false).string(8, interaction).done()
        let understanding = ThriftWriter().string(1, interaction).bool(2, false)
            .string(3, "IN:GET_WEATHER").bool(4, false).done()
        let preamble: [(Int, Data, Int32)] = [
            (EV.startOfUserSpeech, speech, MT.netEvent),
            (EV.finalTranscription, transcription, 0),
            (EV.onPhoneUnderstanding, understanding, 0)
        ]
        let response: [(Int, Data, Int32)] = [
            (EV.voiceAnswer, varm, MT.netEvent),
            (EV.voiceComplete, completion, MT.netEvent)
        ]
        let events = preamble + (active.simplified ? response : Array(response.reversed()))
        for (event, body, type) in events {
            guard isCurrentRequest(interaction) else { throw LinkError.unexpected("眼镜的语音请求已结束") }
            try send(event, body, type: type)
        }
        log("assistant: model response written to the glasses")
    }

    private func send(_ event: Int, _ body: Data, type: Int32 = MT.netEvent) throws {
        let payload = netEvent(event, body)
        guard payload.count <= Self.maxMessageBytes else { throw LinkError.badLength }
        eventWriteLock.lock()
        defer { eventWriteLock.unlock() }
        if payload.count <= Self.segmentBytes || protocolVersion == 0 {
            guard payload.count <= 4000 else { throw LinkError.badLength }
            try write(type, payload)
            return
        }
        let id = Data(UUID().uuidString.utf8)
        let header = PB.uint(1, UInt64(MT.netEvent)) + PB.uint(2, UInt64(payload.count)) + PB.bytes(3, id)
        try write(MT.segmentedHeader, header)
        for offset in stride(from: 0, to: payload.count, by: Self.segmentBytes) {
            let end = min(offset + Self.segmentBytes, payload.count)
            let piece = PB.bytes(1, payload.subdata(in: offset..<end)) + PB.bytes(2, id)
                + PB.uint(3, end == payload.count ? 1 : 0)
            try write(MT.segmentedBuffer, piece)
        }
    }

    private func write(_ type: Int32, _ payload: Data, on endpoint: Endpoint = .messages) throws {
        try checkRegistrationActive()
        try session.sendOnService(endpoint.rawValue, service: Int(Self.service), type: UInt16(type), payload: payload)
    }
}
