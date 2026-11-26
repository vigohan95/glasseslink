import Compression
import Foundation

/// The authenticated text assistant session on service 15.
/// Its mutable state is guarded by stateLock, eventWriteLock and pauseCondition; other threads only pause it.
final class Assistant: @unchecked Sendable {
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
        static let streamStatus: Int32 = 5005
        static let streamEnd: Int32 = 6000
        static let streamConsumed: Int32 = 6001
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
        static let remoteImageCaptureRequest = 73
        static let remoteImageCaptureResponse = 74
        static let sessionModeUpdateResponse = 289
        static let sessionStateBroadcast = 333
        static let sessionStateUpdate = 339
        static let onPhoneUnderstanding = 342
        static let remoteInteractionComplete = 360
        static let ttsStartInfo = 388
        static let ttsEndInfo = 389
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
    /// Other link work (a photo, an import, a status read) parks the reader instead of ending the
    /// registration; the session keeps this assistant's messages for it meanwhile.
    private let pauseCondition = NSCondition()
    private var pauseRequests = 0
    private var readerParked = false
    private var readerActive = false
    private weak var readerThread: Thread?

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
        /// Phone-side recognition: what the glasses made of the speech, what the phone made of it, and
        /// until when the other half is waited for.
        var glassesTranscript: String?
        var phoneText: String?
        var phoneDeadline = TimeInterval.infinity

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
    /// The glasses asked for an answer (interaction) but neither they nor the phone heard any words.
    var onUnheard: ((String) -> Void)?
    var onTurnEnded: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    /// True when the words come from the phone's recogniser (a language the glasses do not recognise).
    /// Then the glasses' request only names the turn, and the microphone stream is handed out below.
    var transcribesOnPhone: () -> Bool = { HeyMetaLanguage.phoneLocale != nil }
    /// A question the phone heard in a turn the glasses then closed without asking anything: they
    /// recognise English only, so Chinese ends this way. The glasses will not play an answer to it.
    /// (words, the turn's id).
    var onUnclaimedQuestion: ((String, String) -> Void)?
    /// Turns the glasses closed while the phone was still recognising, by wake id, and until when its
    /// words are still taken.
    private var unclaimed: [String: TimeInterval] = [:]
    /// The microphone stream of the turn with this wake id began / one chunk of it / it ended.
    var onMicrophoneBegan: ((String) -> Void)?
    var onMicrophoneAudio: ((Data) -> Void)?
    var onMicrophoneEnded: ((String) -> Void)?
    /// The stream the glasses allocated per interaction; an answer in the phone's voice must name it.
    private var streamIDs: [String: String] = [:]
    private var latestStream = ""
    private var lastEventLogged = 0
    /// The glasses' own voice (assistant_voice_id), named in every answer they read themselves; nil keeps
    /// the one in the captured template. A partner voice ("3p_") is never named: the glasses do not read
    /// text in it.
    private var glassesVoiceID: String?

    func useGlassesVoice(_ id: String?) {
        stateLock.lock()
        glassesVoiceID = id.flatMap { $0.isEmpty || $0.hasPrefix("3p_") ? nil : $0 }
        stateLock.unlock()
    }

    private func currentGlassesVoice() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return glassesVoiceID
    }
    /// Sent this far ahead of when it plays, so a late Bluetooth packet does not leave the glasses with
    /// nothing to play; and how long after the last sound the closing events wait.
    private static let speechLead = 0.24
    private static let speechTail = 0.2

    var registered: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return registrationComplete && !stopped
    }

    init(session: Session) {
        self.session = session
        session.onAssistantPicture = { [weak self] bytes, source in self?.tookPicture(bytes, from: source) }
    }

    // MARK: the picture for a question about what the wearer sees

    /// What a request says about the camera (Visor's Visual): the glasses want a picture for it, have
    /// taken one already, or sent a small one inside the request.
    struct VisualHint {
        var wants = false
        var captured = false
        var inline: Data?
    }

    static func visualHint(_ fields: [Int: Any]) -> VisualHint {
        let understanding = fields.structField(2)
        let image = understanding.structField(4)
        let inline = [image.bytes(4), image.bytes(16)].compactMap { $0 }.first { $0.count > 100 }
        return VisualHint(wants: image.bool(20) || understanding.bool(5) || fields.structField(55).bool(8),
                          captured: inline != nil || !image.text(3).isEmpty || !image.text(8).isEmpty,
                          inline: inline)
    }

    private var visualHints: [String: VisualHint] = [:]
    private var recentPicture: (bytes: Data, at: TimeInterval)?
    private var pictureWaiter: CheckedContinuation<Data?, Never>?

    /// True when the glasses themselves marked the request as one about what the wearer sees.
    func wantsPicture(_ interaction: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let hint = visualHints[interaction]
        return hint?.wants == true || hint?.captured == true
    }

    private func tookPicture(_ bytes: Data, from source: String) {
        stateLock.lock()
        let waiting = pictureWaiter
        pictureWaiter = nil
        if waiting == nil { recentPicture = (bytes, ProcessInfo.processInfo.systemUptime) }
        stateLock.unlock()
        log("assistant: a picture from the glasses, \(bytes.count) B (\(source))")
        waiting?.resume(returning: bytes)
    }

    /// A picture that is here already: inside the request, or sent a moment before the question.
    private func readyPicture(_ interaction: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let inline = visualHints[interaction]?.inline { return inline }
        if let recent = recentPicture, ProcessInfo.processInfo.systemUptime - recent.at < 10 {
            recentPicture = nil
            return recent.bytes
        }
        return nil
    }

    private func glassesTookPicture(_ interaction: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visualHints[interaction]?.captured == true
    }

    private func parkPicture(_ continuation: CheckedContinuation<Data?, Never>) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let recent = recentPicture {
            recentPicture = nil
            return recent.bytes
        }
        pictureWaiter = continuation
        return nil
    }

    private func giveUpPicture() {
        stateLock.lock()
        let waiting = pictureWaiter
        pictureWaiter = nil
        stateLock.unlock()
        if waiting != nil { log("assistant: no picture came from the glasses") }
        waiting?.resume(returning: nil)
    }

    /// The glasses' picture for `interaction`, as they send it (HEIC or JPEG, possibly behind other
    /// data). If they have not taken one they are asked to with event 73, {1 false, 2 true, 3 false,
    /// 4 interaction}; they answer 74 and send the file. Nil when nothing came within `timeout`, plus the
    /// time a file that has begun to arrive needs.
    func picture(for interaction: String, timeout: TimeInterval = 8) async -> Data? {
        if let ready = readyPicture(interaction) { return ready }
        session.wantAssistantPicture(for: timeout)
        if !glassesTookPicture(interaction) {
            let request = ThriftWriter().bool(1, false).bool(2, true).bool(3, false).string(4, interaction).done()
            do {
                try send(EV.remoteImageCaptureRequest, request)
                log("assistant: asked the glasses for a picture (event 73)")
            } catch {
                log("assistant: could not ask the glasses for a picture: \(error)")
                return nil
            }
        }
        let limit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            var waited = 0
            while waited < 60, self?.session.assistantPictureArriving == true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            self?.giveUpPicture()
        }
        defer { limit.cancel() }
        return await withCheckedContinuation { continuation in
            if let ready = parkPicture(continuation) { continuation.resume(returning: ready) }
        }
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
            return try session.nextMessage(timeout: timeout, tracePayload: false, forAssistant: true)
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
        // Only the mirrors: 0x80NN is also how the glasses number their own channels, and after they
        // restart those start low again. A file offer on a number equal to m0 or s0 would be parked
        // here and never answered, which blocks their transfer queue.
        session.routeToAssistant([m0 ^ 0x8000, s0 ^ 0x8000], quiet: [s0 ^ 0x8000])
        pauseCondition.lock()
        readerActive = true
        pauseCondition.unlock()
        let worker = Thread { [weak self] in self?.loop() }
        readerThread = worker
        worker.name = "assistant"
        worker.start()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        stopped = true
        running = false
        turn = nil
        stateLock.unlock()
        if wasRunning { session.routeToAssistant([]) }
        pauseCondition.lock()
        pauseCondition.broadcast()
        // Whoever stops the assistant reads the link next (live view, a reconnect): wait for the reader
        // to leave its read so it cannot swallow the first reply.
        if Thread.current !== readerThread {
            let deadline = Date().addingTimeInterval(0.5)
            while readerActive, pauseCondition.wait(until: deadline) {}
        }
        pauseCondition.unlock()
    }

    /// Blocks until the reader is parked (or not running), so the caller can read the link alone.
    /// Every call must be balanced by `resumeReading()`. Returns false if the reader did not park in time.
    @discardableResult
    func pauseReading(timeout: TimeInterval = 3) -> Bool {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        pauseRequests += 1
        let deadline = Date().addingTimeInterval(timeout)
        while readerActive && !readerParked {
            if !pauseCondition.wait(until: deadline) { return readerParked || !readerActive }
        }
        return true
    }

    func resumeReading() {
        pauseCondition.lock()
        pauseRequests = max(0, pauseRequests - 1)
        pauseCondition.broadcast()
        pauseCondition.unlock()
    }

    /// True while another reader owns the link. The reader then stays off the link but keeps answering
    /// what that reader parks for it: glasses log 31 had Hey Meta (15:57:02, 15:58:04) during a
    /// five-minute Bluetooth import, and the glasses resent their unacknowledged envelope every second.
    private func pausedByOtherReader() -> Bool {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        guard pauseRequests > 0 else {
            readerParked = false
            return false
        }
        if !readerParked {
            readerParked = true
            pauseCondition.broadcast()
        }
        return true
    }

    private func waitWhilePaused() {
        pauseCondition.lock()
        if pauseRequests > 0 { _ = pauseCondition.wait(until: Date().addingTimeInterval(0.05)) }
        pauseCondition.unlock()
    }

    private func loop() {
        defer {
            pauseCondition.lock()
            readerActive = false
            readerParked = false
            pauseCondition.broadcast()
            pauseCondition.unlock()
        }
        do {
            while registered {
                if pausedByOtherReader() {
                    if let parked = session.takeParkedAssistantMessage() {
                        if registered { try handle(parked) }
                    } else {
                        waitWhilePaused()
                    }
                    try maintainTurn()
                    continue
                }
                guard registered else { return }
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

    /// Short so a pause request is honoured at once: with Hey Meta on, every link operation waits for
    /// the reader to leave its read, and half a second of that made the shutter feel late.
    private var receiveTimeout: TimeInterval { 0.15 }

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
                    var began: String?
                    stateLock.lock()
                    if let stream = (fields[1]?.first as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
                       stream.count > 8 {
                        if streamIDs.count > 16 { streamIDs.removeAll() }
                        streamIDs[interaction] = stream
                        latestStream = stream
                    }
                    if turn?.includes(interaction) == true, turn?.microphone == nil {
                        turn?.microphone = MicrophoneStream()
                        began = turn?.wakeID
                        // A request that came first now waits for this stream's words.
                        if turn?.requestID != nil, turn?.phoneText == nil {
                            turn?.phoneDeadline = ProcessInfo.processInfo.systemUptime + 12
                        }
                    }
                    stateLock.unlock()
                    if let began, transcribesOnPhone() { onMicrophoneBegan?(began) }
                }
            case Int(MT.streamAudio), 0:
                stateLock.lock()
                turn?.microphone?.noteAudio(bytes: message.payload.count)
                stateLock.unlock()
                if !message.payload.isEmpty, transcribesOnPhone() { onMicrophoneAudio?(message.payload) }
            case Int(MT.streamEnd):
                finishMicrophoneStream()
            case Int(MT.streamStatus):
                log(Self.playbackReport(message.payload))
            case Int(MT.streamConsumed):
                log("assistant: the glasses finished the answer stream")
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

    /// The language the glasses' own voice speaks, from their running locale ("en_US"); English when
    /// they have not said.
    var glassesLanguage: String {
        let code = locale.prefix(2).lowercased()
        return code.count == 2 ? code : "en"
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

    /// 5005: `<stream>_<interaction>_<pcm bytes>_<ms>`, what the glasses played of an answer stream; the
    /// PCM is counted at 96 bytes a millisecond.
    static func playbackReport(_ payload: Data) -> String {
        let parts = (String(data: payload, encoding: .utf8) ?? "").split(separator: "_")
        guard parts.count >= 4, let ms = Int(parts[parts.count - 1]), let pcm = Int(parts[parts.count - 2]) else {
            return "assistant: answer stream status, \(payload.count) bytes"
        }
        return "assistant: the glasses played \(pcm / 96) ms of \(ms) ms"
    }

    private func handleEvent(_ payload: Data) throws {
        guard payload.count <= Self.maxMessageBytes,
              let fields = try? ThriftCompact.loads(payload), let id = fields.int(1) else { return }
        // Which events a turn consists of is what a log is read for; repeats of one event are left out.
        if id != lastEventLogged {
            lastEventLogged = id
            log("assistant: event \(id)")
        }
        guard let body = Self.netEventBody(fields), let inner = try? ThriftCompact.loads(body) else {
            if id == EV.fulfillmentRequest || id == EV.sessionModeUpdateResponse {
                log("assistant: could not decode event \(id): \(Self.describeUndecodableEvent(fields))")
            }
            return
        }
        switch id {
        case EV.remoteImageCaptureResponse:
            log("assistant: the glasses took the picture (event 74)")
        case EV.fulfillmentRequest:
            let hint = Self.visualHint(inner)
            if hint.wants || hint.captured, !inner.text(1).isEmpty {
                stateLock.lock()
                if visualHints.count > 16 { visualHints.removeAll() }
                visualHints[inner.text(1)] = hint
                stateLock.unlock()
                log("assistant: the glasses mark this question as one about what the wearer sees "
                    + "(picture taken \(hint.captured), inside the request \(hint.inline?.count ?? 0) B)")
            }
            let named = inner.text(8)
            if named.count > 8, !inner.text(1).isEmpty {
                stateLock.lock()
                if streamIDs[inner.text(1)] == nil { streamIDs[inner.text(1)] = named }
                stateLock.unlock()
            }
            if transcribesOnPhone(), let request = Self.spokenRequest(inner, requireTranscript: false) {
                acceptRequest(request.interaction, glassesTranscript: request.transcript, simplified: request.simplified)
                return
            }
            guard let request = Self.spokenRequest(inner) else {
                // The wake itself arrives as a fulfillment request too (intent IN:WAKE_WORD), before the
                // one that carries the words: the 0.99 log has two event 57 for one wake. Closing the
                // turn here put its id on the done list, and the real question was then dropped unseen.
                log("assistant: fulfillment event without a question (wake or unsupported); waiting for the next · "
                    + Self.requestFacts(inner))
                return
            }
            acceptTranscript(request.transcript, interaction: request.interaction, simplified: request.simplified)
        case EV.sessionModeUpdateResponse:
            try acknowledgeSpeechStart(inner)
        case EV.interactionClosed:
            // {1 interaction, 2 audioLogData {3 transcription}}: with words, the glasses did it themselves.
            closeTurn(inner.text(1), glassesWords: inner.structField(2).text(3))
        case EV.remoteInteractionComplete:
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

    /// One log line that tells a decompression failure from a parse failure; 0.99 logged only
    /// "could not decode", which made a missing Thrift type look like a zlib problem.
    static func describeUndecodableEvent(_ fields: [Int: Any]) -> String {
        let raw = fields.bytes(2)
        var parts = ["body=\(raw?.count ?? 0)B", "compressed=\(fields.bool(3))"]
        guard let body = netEventBody(fields) else {
            parts.append(raw == nil ? "no body" : "inflate failed")
            if let raw { parts.append("head=\(raw.prefix(16).hex)") }
            return parts.joined(separator: " ")
        }
        parts.append("decoded=\(body.count)B")
        do {
            _ = try ThriftCompact.loads(body)
            parts.append("parsed")
        } catch {
            parts.append("thrift: \(error)")
        }
        parts.append("head=\(body.prefix(48).hex)")
        return parts.joined(separator: " ")
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

    /// What a request the app does not answer was about, without its words: the intent, and whether the
    /// glasses want or already took a picture for it (a question about what the wearer sees).
    static func requestFacts(_ fields: [Int: Any]) -> String {
        let understanding = fields.structField(2)
        let onDevice = fields.structField(55)
        let image = understanding.structField(4)
        let intent = fields.text(23).isEmpty ? onDevice.text(1) : fields.text(23)
        let wantsImage = image.bool(20) || understanding.bool(5) || onDevice.bool(8)
        let inline = max(image.bytes(4)?.count ?? 0, image.bytes(16)?.count ?? 0)
        let words = understanding.structField(1).text(1).count
        return "intent \(intent.isEmpty ? "none" : intent), wants a picture \(wantsImage), picture id "
            + "\(image.text(3).isEmpty ? "no" : "yes"), capture handle \(image.text(8).isEmpty ? "no" : "yes"), "
            + "inline \(inline) B, \(words) characters, invocation \(fields.int(11) ?? -1)"
    }

    static func spokenRequest(_ fields: [Int: Any], requireTranscript: Bool = true)
        -> (interaction: String, transcript: String, simplified: Bool)? {
        let understanding = fields.structField(2)
        let onDevice = fields.structField(55)
        let fallbackIntent = onDevice.text(1)
        let intent = fields.text(23).isEmpty ? fallbackIntent : fields.text(23)
        guard intent != "IN:WAKE_WORD", intent != "IN:START_LIVE_AI" else { return nil }

        // A request about what the wearer sees is a question like any other; `visualHint` says what it
        // tells about the camera.
        let interaction = fields.text(1)
        let transcript = understanding.structField(1).text(1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interaction.isEmpty, interaction.utf8.count <= 128,
              !requireTranscript || !transcript.isEmpty, transcript.utf8.count <= Self.maxMessageBytes else { return nil }
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

    /// Phone-side recognition: the glasses' request names the turn; the words are the phone's, and the
    /// glasses' own only stand in when the phone heard nothing or there was no microphone stream.
    private func acceptRequest(_ interaction: String, glassesTranscript: String, simplified: Bool) {
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
        turn?.glassesTranscript = glassesTranscript
        let heard = turn?.phoneText
        let hasMicrophone = turn?.microphone != nil
        let wake = turn?.wakeID ?? interaction
        // The phone's words get 12 s from here, or 4 s to show that a microphone stream is coming at all;
        // after that the glasses' own words stand in (maintainTurn).
        turn?.phoneDeadline = heard != nil ? .infinity : now + (hasMicrophone ? 12 : 4)
        stateLock.unlock()
        if newlyAwake { notifyWake(interaction) }
        log("assistant: glasses request received; the words come from the phone's recogniser")
        if let heard {
            deliver(Self.question(phone: heard, glasses: glassesTranscript), interaction: interaction, wakeID: wake)
        }
    }

    /// The phone listens in the language chosen in the app, the glasses in their own. What the phone
    /// wrote in the language it listens for is the wearer's question. Anything else it wrote was another
    /// language heard through the wrong recogniser, and then the glasses' own words are the better ones.
    static func question(phone: String, glasses: String,
                         phoneTag: String = HeyMetaLanguage.phoneLocale ?? "zh-CN") -> String {
        if phone.isEmpty { return glasses }
        if glasses.isEmpty { return phone }
        let written = PhoneVoice.languageTag(of: phone, preferred: phoneTag)
        return written.prefix(2) == phoneTag.prefix(2) ? phone : glasses
    }

    /// What the phone recognised in the microphone stream of the turn `wakeID` woke.
    func submitPhoneTranscript(_ text: String, wakeID: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        if let until = unclaimed.removeValue(forKey: wakeID) {
            // The glasses closed this turn while the phone was still at it.
            stateLock.unlock()
            if !stopped, !words.isEmpty, now < until { handOver(words, turn: wakeID) }
            return
        }
        guard !stopped, let active = turn, active.includes(wakeID), !active.replying, active.phoneText == nil else {
            stateLock.unlock()
            return
        }
        turn?.phoneText = words
        if let request = active.requestID {
            turn?.phoneDeadline = .infinity
            stateLock.unlock()
            deliver(Self.question(phone: words, glasses: active.glassesTranscript ?? ""), interaction: request,
                    wakeID: active.wakeID)
        } else {
            // The request, or the glasses closing the turn, usually comes within a second of the stream ending.
            turn?.phoneDeadline = now + 2
            stateLock.unlock()
        }
    }

    private func handOver(_ words: String, turn id: String) {
        log("assistant: the glasses asked nothing in this turn; the phone heard \(words.count) characters and answers itself")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registered else { return }
            self.onUnclaimedQuestion?(words, id)
        }
    }

    private func deliver(_ words: String, interaction: String, wakeID: String) {
        guard !words.isEmpty else {
            log("assistant: neither the phone nor the glasses recognised any words")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.registered else { return }
                self.onAudioWithoutTranscript?()
                if self.isCurrentRequest(interaction) { self.onUnheard?(interaction) }
            }
            return
        }
        log("assistant: question ready, \(words.count) characters")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRequest(interaction) else { return }
            self.onTranscript?(words, interaction)
        }
    }

    /// `glassesWords`: what the glasses heard in a turn they are ending, when they say. A turn they
    /// understood they have dealt with ("take a photo"); one they did not, and never asked about, was
    /// perhaps Chinese, and then the phone's words for it are a question nobody has answered.
    private func closeTurn(_ interaction: String, glassesWords: String = "") {
        guard !interaction.isEmpty else { return }
        let understood = !glassesWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        if understood { unclaimed.removeValue(forKey: interaction) }
        guard let active = turn, active.includes(interaction) else {
            stateLock.unlock()
            return
        }
        var question: String?
        if transcribesOnPhone(), !understood, active.requestID == nil, active.microphone != nil {
            if let words = active.phoneText {
                if !words.isEmpty { question = words }
            } else {
                unclaimed = unclaimed.filter { $0.value > now }
                unclaimed[active.wakeID] = now + 12
                if let related = active.relatedWakeID { unclaimed[related] = now + 12 }
            }
        }
        forgetTurn()
        stateLock.unlock()
        notifyTurnEnded(active.requestID ?? active.wakeID)
        if let question { handOver(question, turn: active.wakeID) }
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
        let wake = turn?.wakeID
        stateLock.unlock()
        if let finished {
            log("assistant: glasses microphone stream ended, \(finished.frames) audio frames, \(finished.bytes) audio bytes")
            if let wake, transcribesOnPhone() { onMicrophoneEnded?(wake) }
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
        } else if transcribesOnPhone(), now >= active.phoneDeadline {
            // The other half never came: answer with what there is.
            turn?.phoneDeadline = .infinity
            if let request = active.requestID {
                stateLock.unlock()
                deliver(active.glassesTranscript ?? "", interaction: request, wakeID: active.wakeID)
            } else if let words = active.phoneText, !words.isEmpty {
                // Words but no request from the glasses, and no word that they closed the turn either:
                // they are not waiting for an answer, so it cannot be played through them.
                forgetTurn()
                stateLock.unlock()
                notifyTurnEnded(active.wakeID)
                handOver(words, turn: active.wakeID)
            } else {
                stateLock.unlock()
                notifyMissingTranscript(active.wakeID)
            }
        } else if !transcribesOnPhone(), active.requestID == nil, active.supportsSpeech != false,
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

        guard let varm = Varm.build(interaction: interaction, transcript: transcript, text: text, onGlasses: true,
                                    voiceID: currentGlassesVoice()) else {
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

    /// The answer in the phone's voice (Visor's stream()): the usual preamble, a stream header naming the
    /// stream the glasses allocated, the Opus packets two to a frame at the pace they play, the VARM, and
    /// ev60 marked as streamed so the glasses do not speak the text themselves.
    func complete(interaction: String, text: String, transcript: String, speech packets: [Data]) async throws {
        guard !packets.isEmpty else {
            try complete(interaction: interaction, text: text, transcript: transcript)
            return
        }
        let (active, streamID) = try beginSpokenReply(interaction)
        defer { endSpokenReply(interaction) }
        guard let varm = Varm.build(interaction: interaction, transcript: transcript, text: text, onGlasses: false) else {
            throw LinkError.unexpected("缺少眼镜播报所需的语音模板")
        }
        if streamID.isEmpty { log("assistant: no stream id from the glasses for this answer; it may not play") }
        let speechStart = ThriftWriter().string(1, interaction).done()
        let transcription = ThriftWriter().string(1, transcript.isEmpty ? text : transcript).i32(2, 0).string(4, "")
            .bool(7, false).string(8, interaction).done()
        let understanding = ThriftWriter().string(1, interaction).bool(2, false)
            .string(3, "IN:GET_WEATHER").bool(4, false).done()
        try send(EV.startOfUserSpeech, speechStart)
        try send(EV.finalTranscription, transcription, type: 0)
        try send(EV.onPhoneUnderstanding, understanding, type: 0)

        let mono = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        func wall() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
        try send(EV.ttsStartInfo, ThriftWriter().i64(1, wall()).i64(2, mono).string(3, interaction).done())
        try await Task.sleep(nanoseconds: 20_000_000)

        // Field 1 is the stream the glasses allocated; without it they drop the audio silently.
        let header = (streamID.isEmpty ? Data() : PB.string(1, streamID)) + PB.string(2, interaction)
            + PB.uint(4, 1) + PB.uint(7, 1) + PB.uint(19, 1)
        try write(MT.streamHeader, header, on: .stream)
        let started = ProcessInfo.processInfo.systemUptime
        var due = 0.0
        var index = 0
        while index < packets.count {
            guard isCurrentRequest(interaction) else { throw LinkError.unexpected("眼镜的语音请求已结束") }
            let pair = packets[index ..< min(index + 2, packets.count)]
            var frame = Data()
            for packet in pair {
                let n = UInt32(packet.count)
                frame.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)])
                frame.append(packet)
                due += OpusFraming.duration(of: packet)
            }
            if index == 0 {
                try write(MT.streamAudio, frame, on: .stream)
                if active.simplified { try send(EV.voiceAnswer, varm) }
            } else {
                // Tagged with a type, only the first 40 ms would ever play.
                try session.sendContinuation(Endpoint.stream.rawValue, service: Int(Self.service), payload: frame)
            }
            index += 2
            let wait = due - Self.speechLead - (ProcessInfo.processInfo.systemUptime - started)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        try write(MT.streamEnd, Data(), on: .stream)
        // The glasses are still playing what was sent ahead. The events below end the answer and reopen
        // the microphone; sent at once they cut off its last words (glasses log 34).
        let rest = due + Self.speechTail - (ProcessInfo.processInfo.systemUptime - started)
        if rest > 0 { try await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
        if !active.simplified { try send(EV.voiceAnswer, varm) }
        // Without it the glasses stay in their answering state with the microphone on.
        try send(EV.voiceComplete, Varm.complete(interaction: interaction, text: text, streamed: true))
        try send(EV.ttsEndInfo, ThriftWriter().i64(1, wall()).i64(2, mono).i64(3, 7000).string(4, interaction).done())
        try await Task.sleep(nanoseconds: 20_000_000)
        try send(EV.keepAirSessionAlive, ThriftWriter().string(1, "VoiceActionResponseMessage")
            .i32(2, Int32(truncatingIfNeeded: mono & 0xFFFF)).i32(3, 1).done())
        log("assistant: answer streamed in the phone's voice, \(packets.count) packets, \(String(format: "%.1f", due)) s")
    }

    /// Marks the turn as being answered and names the stream the glasses allocated for it.
    private func beginSpokenReply(_ interaction: String) throws -> (Turn, String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped, let active = turn, active.requestID == interaction, active.supportsSpeech != false,
              !active.replying else {
            throw LinkError.unexpected("眼镜的语音请求已结束")
        }
        turn?.replying = true
        let streamID = streamIDs[interaction] ?? streamIDs[active.wakeID]
            ?? active.relatedWakeID.flatMap { streamIDs[$0] } ?? latestStream
        return (active, streamID)
    }

    private func endSpokenReply(_ interaction: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if turn?.requestID == interaction { forgetTurn() }
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
