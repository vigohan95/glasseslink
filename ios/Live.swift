import AVFoundation
import Foundation
import UIKit

/// svc51350, media streaming control: the ids the glasses use while a live session runs.
enum StreamType {
    static let codecConfig: UInt16 = 1
    static let codecConfigAck: UInt16 = 2
    static let configureAudio: UInt16 = 3
    static let configureAudioAck: UInt16 = 4
    static let configureVideo: UInt16 = 5
    static let configureVideoAck: UInt16 = 6
    static let control: UInt16 = 7
    static let controlAck: UInt16 = 8
    static let audioBuffer: UInt16 = 9
    static let videoBuffer: UInt16 = 10
    static let audioEnd: UInt16 = 11
    static let videoEnd: UInt16 = 12
    static let stopped: UInt16 = 13
    static let lifecycle: UInt16 = 19
    static let userEvent: UInt16 = 23
    static let sessionSettings: UInt16 = 27
    static let photoBuffer: UInt16 = 34
    static let photoEnd: UInt16 = 35
}

/// One rung of the quality ladder: what to ask the glasses for.
struct LiveRung {
    let width: Int
    let height: Int
    let bitrate: Int
    let frameRate: Int

    /// 360p over Bluetooth: the link carries about 120–165 KB/s, so this is the honest ceiling.
    static let ble = LiveRung(width: 360, height: 640, bitrate: 400_000, frameRate: 15)
    static let ble24 = LiveRung(width: 360, height: 640, bitrate: 300_000, frameRate: 24)

    var words: String { "\(width)x\(height) \(bitrate / 1000) kbit/s \(frameRate) fps" }
}

/// A snapshot taken mid-stream: the glasses answer a photo request on the same session.
struct LivePhoto {
    let data: Data
    let isHeic: Bool
}

/// Drives one live session: start the glasses' livestream app, ask for a video stream, then
/// reassemble Annex-B frames into sample buffers for an `AVSampleBufferDisplayLayer`.
final class LiveStream {
    enum Phase: String { case idle, starting, running, failed }

    let session: Session
    let layer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var frames = 0
    private(set) var framesPerSecond = 0
    private(set) var kbitPerSecond = 0
    private(set) var decodedSize: CGSize?
    var previewReadyForDisplay: Bool? {
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return nil
    }

    var onPhoto: ((LivePhoto) -> Void)?
    var onPhase: ((Phase) -> Void)?
    var log: (String) -> Void = { _ in }

    private let runningLock = NSLock()
    private var running = false
    private var streamChannels: Set<UInt16> = []
    private var streamTypes: [UInt16: UInt16] = [:]
    private var frameBuf = Data()
    private var photoBuf = Data()
    private var format: CMVideoFormatDescription?
    private var codecConfig = Data()
    private var needsKeyframe = true
    private var lastRendererError: Int?
    private var nextVisibilityCheck = Date.distantPast
    private var reportedVisibleFrame = false  // Read and written on the main queue.
    private static let maximumEncodedFrameBytes = 8 * 1024 * 1024
    private var windowStart = Date()
    private var windowBytes = 0
    private var windowFrames = 0
    private var lastFrameAt = Date()

    init(session: Session) {
        self.session = session
        let layer = AVSampleBufferDisplayLayer()
        self.layer = layer
        renderer = layer.sampleBufferRenderer
        layer.videoGravity = .resizeAspect
    }

    // MARK: control

    func start(rung: LiveRung = .ble) {
        runningLock.lock()
        guard !running else { runningLock.unlock(); return }
        running = true
        runningLock.unlock()
        setPhase(.starting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(rung: rung)
        }
    }

    func stop() {
        guard finishRunning() else { return }
        if phase == .running {
            try? session.sendOnService("stream", service: Self.svcStream, type: StreamType.control,
                                       payload: Self.controlStream(nonce: Self.nonce(), action: 2))
        }
        try? session.sendOnService("status", service: Status.service, type: 2002, payload: PB.uint(1, 3))
        setPhase(.idle)
    }

    /// Asks the glasses for one still while the session runs; the answer arrives as HEIC.
    func requestPhoto() {
        guard isRunning, phase == .running else { return }
        do {
            try session.sendOnService("stream", service: LiveStream.svcStream, type: StreamType.userEvent,
                                      payload: PB.uint(2, 4))
            log("asked for a photo")
        } catch {
            log("photo request failed: \(error)")
        }
    }

    static let svcStream = 51350

    // MARK: the session

    private var isRunning: Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return running
    }

    private func finishRunning() -> Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        let wasRunning = running
        running = false
        return wasRunning
    }

    private func waitForAnswer(_ serviceName: String, service: Int, type: UInt16,
                               payload: Data, answerType: UInt16, nonce: UInt16? = nil,
                               timeout: TimeInterval) throws -> Data? {
        guard isRunning else { throw CancellationError() }
        let mirror = session.serviceChannel(serviceName, service: service) ^ 0x8000
        if service == Self.svcStream { streamChannels.insert(mirror) }
        try session.sendOnService(serviceName, service: service, type: type, payload: payload)
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, deadline.timeIntervalSinceNow > 0 {
            let message: DataX.Message
            do {
                message = try session.nextMessage(timeout: min(0.5, deadline.timeIntervalSinceNow))
            } catch LinkError.unexpected(_) {
                continue
            }
            if message.channel == mirror {
                if let code = message.error, code != Int(AirShield.stOK), code != Int(AirShield.stSuccess) {
                    if service == Self.svcStream, code == 0xC001 {
                        throw LinkError.unexpected("眼镜未在当前蓝牙连接上提供取景服务（0xC001）")
                    }
                    throw LinkError.serviceError("取景请求", UInt16(truncatingIfNeeded: code))
                }
                if message.type == Int(answerType) {
                    if let nonce {
                        let fields = try PB.parse(message.payload)
                        guard (fields[1]?.first as? Int) == Int(nonce) else { continue }
                    }
                    return message.payload
                }
            }
            try consumeStreamMessage(message)
        }
        guard isRunning else { throw CancellationError() }
        return nil
    }

    private func run(rung: LiveRung) {
        do {
            // 1. the glasses-side app that owns a live session (3 = livestream).
            log("starting livestream app")
            guard let started = try waitForAnswer("status", service: Status.service, type: 2000,
                                                  payload: PB.uint(1, 3), answerType: 2001, timeout: 6) else {
                throw LinkError.unexpected("眼镜未确认可以开始实时取景")
            }
            let code = (try PB.parse(started))[1]?.first as? Int
            guard code == 1 || code == 12 else {
                throw LinkError.unexpected("眼镜无法启动取景（结果 \(code ?? 0)）")
            }
            guard isRunning else { return }

            // 2. session settings: timers, application type 3 (demo), and the overrides the Meta app sends.
            let settings = PB.bytes(3, PB.uint(1, 30) + PB.uint(2, 600))
                + PB.uint(4, 3)
                + PB.bytes(5, PB.uint(1, 1) + PB.uint(2, 0) + PB.uint(3, 1) + PB.uint(4, 0))
            try session.sendOnService("stream", service: LiveStream.svcStream,
                                      type: StreamType.sessionSettings, payload: settings)
            log("session settings sent")

            // 3. video: HEVC, the rung's size and rate. iFrame every second.
            let nonce = Self.nonce()
            let video = PB.uint(1, UInt64(nonce))
                + PB.bytes(2, PB.string(1, "video/hevc") + PB.uint(2, UInt64(rung.width))
                           + PB.uint(3, UInt64(rung.height)) + PB.uint(4, UInt64(rung.bitrate))
                           + PB.uint(5, UInt64(rung.frameRate)) + PB.uint(6, 1)
                           + PB.uint(7, 1) + PB.uint(8, UInt64(rung.frameRate)))
                + PB.uint(3, 1)
            let answer = try waitForAnswer("stream", service: Self.svcStream,
                                           type: StreamType.configureVideo, payload: video,
                                           answerType: StreamType.configureVideoAck, nonce: nonce, timeout: 8)
            log("configure video \(rung.words): \(Self.answerWords(answer))")

            // 4. audio: 48 kHz stereo AAC-LC, the format the glasses' microphones run at.
            let anonce = Self.nonce()
            let audio = PB.uint(1, UInt64(anonce))
                + PB.bytes(2, PB.string(1, "audio/mp4a-latm") + PB.uint(2, 48_000) + PB.uint(3, 96_000)
                           + PB.uint(4, 2) + PB.uint(5, 0))
                + PB.uint(3, 1)
            let ack = try waitForAnswer("stream", service: Self.svcStream,
                                        type: StreamType.configureAudio, payload: audio,
                                        answerType: StreamType.configureAudioAck, nonce: anonce, timeout: 6)
            log("configure audio: \(Self.answerWords(ack))")

            // 5. go.
            let startNonce = Self.nonce()
            let start = try waitForAnswer("stream", service: Self.svcStream, type: StreamType.control,
                                          payload: Self.controlStream(nonce: startNonce, action: 1),
                                          answerType: StreamType.controlAck, nonce: startNonce, timeout: 8)
            log("start: \(Self.answerWords(start))")
            if let start, Self.answerWords(start) != "ok" {
                throw LinkError.unexpected("眼镜拒绝取景（\(Self.answerWords(start))）")
            }
            try readLoop()
        } catch {
            guard finishRunning() else { return }
            log("live failed: \(error)")
            if case LinkError.unexpected(let reason) = error {
                lastError = reason
            } else {
                lastError = "\(error)"
            }
            setPhase(.failed)
        }
    }

    /// Owns the link while streaming: everything on the stream channel lands here.
    private func readLoop() throws {
        lastFrameAt = Date()
        while isRunning {
            if Date().timeIntervalSince(lastFrameAt) > 12 {
                throw LinkError.unexpected("眼镜没有返回取景画面")
            }
            let message: DataX.Message
            do {
                message = try session.nextMessage(timeout: 1.5)
            } catch LinkError.unexpected(_) {
                continue
            }
            try consumeStreamMessage(message)
        }
    }

    private func consumeStreamMessage(_ message: DataX.Message) throws {
        guard isRunning, message.error == nil else { return }
        if let service = message.service {
            guard service == Self.svcStream else { return }
            streamChannels.insert(message.channel)
        }
        guard streamChannels.contains(message.channel) else { return }
        if let type = message.type { streamTypes[message.channel] = UInt16(truncatingIfNeeded: type) }
        guard let type = streamTypes[message.channel] else { return }
        switch type {
        case StreamType.codecConfig:
            takeCodecConfig(message.payload)
        case StreamType.videoBuffer, StreamType.videoEnd:
            guard message.payload.count <= Self.maximumEncodedFrameBytes - frameBuf.count else {
                throw LinkError.unexpected("取景视频帧超出可处理大小")
            }
            frameBuf.append(message.payload)
            meter(message.payload.count)
            if type == StreamType.videoEnd { finishFrame() }
        case StreamType.photoBuffer:
            photoBuf.append(message.payload)
        case StreamType.photoEnd:
            photoBuf.append(message.payload)
            finishPhoto()
        case StreamType.stopped:
            throw LinkError.unexpected("眼镜停止了取景")
        case StreamType.lifecycle:
            log("lifecycle event")
        default:
            break
        }
    }

    // MARK: frames

    /// CODEC_CONFIGURATION_UPDATE_REQUEST: field 3 is the parameter sets, field 2 says which codec.
    private func takeCodecConfig(_ payload: Data) {
        guard let f = try? PB.parse(payload), let config = f[3]?.first as? Data, config != codecConfig else { return }
        let units = Self.annexBUnits(config)
        if let fmt = Self.hevcFormat(units) {
            codecConfig = config
            format = fmt
            renderer.flush()
            needsKeyframe = true
            log("codec config: HEVC, \(units.count) parameter sets")
        }
    }

    private func finishFrame() {
        let whole = frameBuf
        frameBuf = Data()
        guard whole.count > 8 else { return }
        // Eight bytes of little-endian presentation time, then Annex-B.
        var pts: UInt64 = 0
        withUnsafeMutableBytes(of: &pts) { dst in
            whole.copyBytes(to: dst, from: 0..<8)
        }
        let annex = whole.subdata(in: 8..<whole.count)
        let units = Self.annexBUnits(annex)
        let types = units.compactMap(Self.hevcNALType)
        guard let time = CMTimeValue(exactly: UInt64(littleEndian: pts)), let fmt = format,
              types.contains(where: { $0 <= 31 }) else { return }
        let now = Date()
        lastFrameAt = now
        let isSync = types.contains(where: { (16...21).contains($0) })
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let code = (renderer.error as NSError?)?.code ?? 0
            if lastRendererError != code { log("video renderer needs reset (\(code))") }
            lastRendererError = code
            renderer.flush()
            needsKeyframe = true
        }
        if !needsKeyframe, !renderer.isReadyForMoreMediaData {
            // Dropping compressed video can remove references for later frames. Resume at a keyframe.
            renderer.flush()
            needsKeyframe = true
        }
        guard !needsKeyframe || isSync,
              let sample = Self.sampleBuffer(units: units, format: fmt,
                                             pts: CMTime(value: time, timescale: 1_000_000), isSync: isSync) else { return }
        renderer.enqueue(sample)
        needsKeyframe = false
        frames += 1
        windowFrames += 1
        if phase != .running { setPhase(.running) }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        decodedSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        if now >= nextVisibilityCheck {
            nextVisibilityCheck = now.addingTimeInterval(1)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reportedVisibleFrame, self.isRunning, self.previewReadyForDisplay == true else { return }
                self.reportedVisibleFrame = true
                self.log("first preview frame ready for display")
            }
        }
    }

    private func finishPhoto() {
        let whole = photoBuf
        photoBuf = Data()
        guard whole.count > 12 else { return }
        // A bare HEIC has ftyp at byte 4; anything else carries the same 8-byte pts in front.
        let bare = String(data: whole.subdata(in: 4..<8), encoding: .ascii) == "ftyp"
        let data = bare ? whole : whole.subdata(in: 8..<whole.count)
        let heic = String(data: data.prefix(12), encoding: .ascii)?.contains("ftyp") ?? false
        log("photo: \(data.count)B \(heic ? "HEIC" : "")")
        DispatchQueue.main.async { self.onPhoto?(LivePhoto(data: data, isHeic: heic)) }
    }

    // MARK: stats

    private func meter(_ bytes: Int) {
        windowBytes += bytes
        let now = Date()
        let dt = now.timeIntervalSince(windowStart)
        if dt >= 1 {
            kbitPerSecond = Int(Double(windowBytes) * 8 / dt / 1000)
            framesPerSecond = Int(Double(windowFrames) / dt)
            windowBytes = 0
            windowFrames = 0
            windowStart = now
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        DispatchQueue.main.async { self.onPhase?(p) }
    }

    // MARK: encoding helpers

    private static func nonce() -> UInt16 { UInt16.random(in: 1...60_000) }

    private static func controlStream(nonce: UInt16, action: UInt64) -> Data {
        PB.uint(1, UInt64(nonce)) + PB.uint(2, action)
    }

    /// A configure/control answer: field 1 nonce, field 2 Error{1 code, 2 reason}. No error means success.
    private static func answerWords(_ payload: Data?) -> String {
        guard let payload, !payload.isEmpty, let f = try? PB.parse(payload) else { return "no answer" }
        guard let err = f[2]?.first as? Data, let e = try? PB.parse(err) else { return "ok" }
        let code = (e[1]?.first as? Int) ?? 0
        let reason = (e[2]?.first as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return code == 0 ? "ok" : "error \(code) \(reason)"
    }

    /// Splits Annex-B into NAL units, start codes dropped.
    static func annexBUnits(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return [] }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1] - 3 : b.count
            while end > s, b[end - 1] == 0 { end -= 1 }
            if end > s { out.append(Data(b[s..<end])) }
        }
        return out
    }

    /// Builds the format description from VPS/SPS/PPS; HEVC wants 4-byte NAL lengths.
    static func hevcFormat(_ units: [Data]) -> CMVideoFormatDescription? {
        let params = units.filter { unit in
            Self.hevcNALType(unit).map { (32...34).contains($0) } ?? false
        }
        guard Set(params.compactMap(Self.hevcNALType)).count == 3 else { return nil }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var kept: [UnsafeMutablePointer<UInt8>] = []
        for p in params {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, p.count))
            p.copyBytes(to: buf, count: p.count)
            kept.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(p.count)
        }
        defer {
            for p in kept { p.deallocate() }
        }
        var fmt: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrs in
            sizes.withUnsafeBufferPointer { lens in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: params.count,
                    parameterSetPointers: ptrs.baseAddress!,
                    parameterSetSizes: lens.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr else { return nil }
        return fmt
    }

    static func hevcNALType(_ unit: Data) -> UInt8? {
        guard unit.count >= 2, let header = unit.first else { return nil }
        return (header >> 1) & 0x3F
    }

    /// Puts length-prefixed NALs in memory owned by Core Media for the renderer's asynchronous use.
    static func sampleBuffer(units: [Data], format: CMVideoFormatDescription, pts: CMTime,
                             isSync: Bool) -> CMSampleBuffer? {
        var sampleBytes = Data()
        for unit in units {
            guard unit.count >= 2, let count = UInt32(exactly: unit.count) else { return nil }
            var length = count.bigEndian
            withUnsafeBytes(of: &length) { sampleBytes.append(contentsOf: $0) }
            sampleBytes.append(unit)
        }
        guard !sampleBytes.isEmpty else { return nil }
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sampleBytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: sampleBytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard created == kCMBlockBufferNoErr, let block else { return nil }
        let copied = sampleBytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sampleSize = sampleBytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) == 1,
              let first = CFArrayGetValueAtIndex(attachments, 0) else { return nil }
        let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(first).takeUnretainedValue()
        // The glasses' PTS does not run on the phone's display clock.
        let display = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(dictionary, display, value)
        if !isSync {
            let notSync = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            CFDictionarySetValue(dictionary, notSync, value)
        }
        return sample
    }
}
