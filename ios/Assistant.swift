import Foundation

/// svc15, Oxide: the assistant channel. Registering here is what makes "Hey Meta" come to this app
/// instead of Meta: the glasses keep their own wake word, but every turn is answered by us.
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
        static let runningLocale: Int32 = 1026
        static let incomingNotificationResponse: Int32 = 1027
        static let numOfDevicesPaired: Int32 = 1029
        static let airResourcesUnavailable: Int32 = 1031
        static let airResourcesAvailable: Int32 = 1032
        static let ttsBufferConfig: Int32 = 1033
        static let mmaiEnabled: Int32 = 1036
        static let assistantReady: Int32 = 1037
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
        static let startOfUserSpeech = 71
        static let remoteImageCaptureRequest = 73
        static let remoteImageCaptureResponse = 74
        static let deviceVoiceState = 307
        static let sessionStateBroadcast = 333
        static let startRemoteInteraction = 337
        static let sessionStateUpdate = 339
        static let remoteInteractionComplete = 360
        static let ttsStartInfo = 388
        static let ttsEndInfo = 389
        static let keepAirSessionAlive = 392
    }

    private let session: Session
    private let clientId = UUID().uuidString
    private var streamId = UUID().uuidString
    private(set) var protocolVersion = 0
    private(set) var locale = ""
    private(set) var registered = false
    private var running = false
    private var thread: Thread?
    private var m0: UInt16?

    var log: (String) -> Void = { _ in }
    /// Called for every turn the glasses start; the app turns it into a model answer.
    var onTurn: ((String) -> Void)?
    var answer: ((String) -> String)?

    init(session: Session) {
        self.session = session
    }

    // MARK: registration

    func register(timeout: TimeInterval = 8) throws {
        let channel = try session.serviceChannel("assistant-m0", service: Int(Assistant.service))
        m0 = channel

        try session.sendOnService("assistant-m0", service: Int(Assistant.service),
                                  type: UInt16(MT.initMessageRequest), payload: registration("\(clientId)-m0"))
        log("assistant: registration sent")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try session.nextMessage(timeout: 2)
            guard let type = message.type else { continue }
            switch Int32(truncatingIfNeeded: type) {
            case MT.initMessageResponse:
                protocolVersion = message.payload.count > 4
                    ? Int((try? PB.parse(message.payload))?[1]?.first as? UInt64 ?? 0)
                    : 0
                log("assistant: protocol \(protocolVersion)")
                registered = true
            case MT.runningLocale:
                locale = String(describing: (try? PB.parse(message.payload))?[1]?.first ?? "")
                log("assistant: glasses locale \(locale)")
            default:
                continue
            }
            if registered { break }
        }
        guard registered else { throw LinkError.unexpected("assistant registration got no answer") }

        // The stream half: the glasses push audio here and expect it opened too.
        _ = try session.serviceChannel("assistant-s0", service: Int(Assistant.service))
        try session.sendOnService("assistant-s0", service: Int(Assistant.service),
                                  type: UInt16(MT.initStreamRequest), payload: registration("\(clientId)-s0"))
        log("assistant: stream registration sent")

        // Declare the resources an assistant backend has; without them the glasses take audio and say nothing.
        let resources: [(Int32, Data)] = [
            (MT.pairedDeviceAndroid, PB.string(1, "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)")),
            (MT.airResourcesUnavailable, idOnly()),
            (MT.liveModeUnavailable, idOnly()),
            (MT.deviceActive, Data()),
            (MT.numOfDevicesPaired, Data("1".utf8)),
            (MT.liveModeAvailable, idOnly()),
            (MT.airResourcesAvailable, idOnly()),
        ]
        for (type, payload) in resources {
            try? session.sendOnService("assistant-m0", service: Int(Assistant.service), type: UInt16(truncatingIfNeeded: type), payload: payload)
        }
        announce()
        log("assistant: registered, \"Hey Meta\" now routes here")
    }

    private func idOnly() -> Data { PB.string(1, UUID().uuidString) }

    private func registration(_ endpoint: String) -> Data {
        PB.string(1, streamId) + PB.string(2, clientId) + PB.string(3, endpoint) + PB.uint(4, 2)
    }

    /// Three events that tell the glasses a working backend sits behind this client.
    private func announce() {
        let sid = UUID().uuidString
        var events: [(Int, Data)] = [
            (265, ThriftWriter().string(1, sid).bool(2, true).bool(3, false)
                .string(4, UUID().uuidString.uppercased()).string(5, "prod.facebookvirtualassistant.com")
                .string(6, "ble").string(10, "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)")
                .bool(11, false).bool(13, true).bool(14, false).done()),
            (263, ThriftWriter().string(1, sid).bool(2, false).bool(3, false).i32(4, 1).bool(7, false).done()),
            (263, ThriftWriter().string(1, sid).bool(2, true).bool(3, false).i32(4, 2).done()),
        ]
        events.append((262, ThriftWriter().string(1, sid).i32(2, 1).i32(3, 0).done()))
        for (event, body) in events {
            try? session.sendOnService("assistant-m0", service: Int(Assistant.service),
                                       type: UInt16(MT.netEvent), payload: netEvent(event, body))
        }
        streamId = sid
    }

    /// NetEvent carrier: field 4 must be I64 or the glasses drop the whole event silently.
    func netEvent(_ eventId: Int, _ body: Data) -> Data {
        ThriftWriter().i32(1, Int32(eventId)).binary(2, body).bool(3, false)
            .i64(4, Int64(body.count)).bool(11, false).done()
    }

    // MARK: turn loop

    func startLoop() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "assistant"
        thread = t
        t.start()
    }

    func stop() {
        running = false
    }

    private func loop() {
        while running {
            let message: DataX.Message
            do {
                message = try session.nextMessage(timeout: 1.5)
            } catch {
                continue
            }
            guard let type = message.type else { continue }
            switch Int32(truncatingIfNeeded: type) {
            case MT.envelope:
                envelope(message.payload)
            case MT.netEvent:
                event(message.payload, source: "channel")
            case MT.runningLocale:
                let f = (try? PB.parse(message.payload)) ?? [:]
                if let first = f[1]?.first {
                    locale = String(describing: first)
                    log("assistant: locale \(locale)")
                }
            case MT.initStreamResponse, MT.ttsBufferConfig, MT.mmaiEnabled, MT.assistantReady,
                 MT.streamConsumed, MT.incomingNotificationResponse, MT.numOfDevicesPaired:
                break
            default:
                log("assistant: message \(type), \(message.payload.count)B")
            }
        }
    }

    private func envelope(_ payload: Data) {
        guard let f = try? PB.parse(payload) else { return }
        // The envelope is {1 id, 2 inner type, 3 inner payload}; unacked, the glasses resend it for minutes.
        let id = (f[1]?.first as? UInt64) ?? 0
        if id != 0 {
            try? session.sendOnService("assistant-m0", service: Int(Assistant.service),
                                       type: UInt16(MT.envelopeAck), payload: PB.uint(1, id))
        }
        let innerType = (f[2]?.first as? UInt64) ?? 0
        if innerType == UInt64(MT.netEvent), let inner = f[3]?.first as? Data {
            event(inner, source: "envelope")
        }
    }

    private func event(_ payload: Data, source: String) {
        guard let fields = try? ThriftCompact.loads(payload) else {
            log("assistant: unreadable net event (\(source), \(payload.count)B)")
            return
        }
        let id = fields.int(1) ?? -1
        let body = fields.bytes(2) ?? Data()
        guard let inner = try? ThriftCompact.loads(body) else {
            log("assistant: event \(id) with \(body.count)B (unreadable body)")
            return
        }
        switch id {
        case EV.startRemoteInteraction, EV.startOfUserSpeech:
            let interaction = inner.text(1)
            log("assistant: turn \(id) interaction=\(interaction)")
            onTurn?(interaction)
        case EV.finalTranscription:
            log("assistant: transcription \(inner.text(2))")
        case EV.remoteImageCaptureRequest:
            log("assistant: glasses want a photo")
        default:
            log("assistant: event \(id), \(body.count)B")
        }
    }

    // MARK: answering

    /// Ends a turn the way a server does: text in ev60, which the glasses speak themselves.
    func complete(interaction: String, text: String, followUp: Bool = false) {
        let result = ThriftWriter().string(1, text).i32(2, 1).bool(3, false).bool(4, false)
            .bool(7, false).bool(8, false).bool(11, followUp).done()
        let body = ThriftWriter().string(1, interaction).i32(2, 1000).string(3, "")
            .struct(4, result).done()
        try? session.sendOnService("assistant-m0", service: Int(Assistant.service),
                                   type: UInt16(MT.netEvent), payload: netEvent(360, body))
        log("assistant: answered \(interaction)")
    }
}
