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
    let layer = AVSampleBufferDisplayLayer()

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var frames = 0
    private(set) var framesPerSecond = 0
    private(set) var kbitPerSecond = 0
    private(set) var decodedSize: CGSize?

    var onPhoto: ((LivePhoto) -> Void)?
    var onPhase: ((Phase) -> Void)?
    var log: (String) -> Void = { _ in }

    private var running = false
    private var thread: Thread?
    private var frameBuf = Data()
    private var photoBuf = Data()
    private var format: CMVideoFormatDescription?
    private var windowStart = Date()
    private var windowBytes = 0
    private var windowFrames = 0
    private var lastFrameAt = Date()

    init(session: Session) {
        self.session = session
        layer.videoGravity = .resizeAspect
    }

    // MARK: control

    func start(rung: LiveRung = .ble) {
        guard !running else { return }
        running = true
        setPhase(.starting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(rung: rung)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        try? session.sendOnService("stream", service: LiveStream.svcStream, type: StreamType.control,
                                    payload: Self.controlStream(nonce: Self.nonce(), action: 2))
        try? session.sendOnService("app", service: Status.service, type: 2002,
                                   payload: PB.uint(1, 3))   // stop the livestream app
        setPhase(.idle)
    }

    /// Asks the glasses for one still while the session runs; the answer arrives as HEIC.
    func requestPhoto() {
        guard running else { return }
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

    private func run(rung: LiveRung) {
        do {
            // 1. the glasses-side app that owns a live session (3 = livestream).
            log("starting livestream app")
            _ = try? session.askOnService("app", service: Status.service, type: 2000,
                                          payload: PB.uint(1, 3), answerType: 2001, timeout: 6)

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
            let answer = try? session.askOnService("stream", service: LiveStream.svcStream,
                                                   type: StreamType.configureVideo, payload: video,
                                                   answerType: StreamType.configureVideoAck, timeout: 8)
            log("configure video \(rung.words): \(Self.answerWords(answer))")

            // 4. audio: 48 kHz stereo AAC-LC, the format the glasses' microphones run at.
            let anonce = Self.nonce()
            let audio = PB.uint(1, UInt64(anonce))
                + PB.bytes(2, PB.string(1, "audio/mp4a-latm") + PB.uint(2, 48_000) + PB.uint(3, 96_000)
                           + PB.uint(4, 2) + PB.uint(5, 0))
                + PB.uint(3, 1)
            let ack = try? session.askOnService("stream", service: LiveStream.svcStream,
                                                type: StreamType.configureAudio, payload: audio,
                                                answerType: StreamType.configureAudioAck, timeout: 6)
            log("configure audio: \(Self.answerWords(ack))")

            // 5. go.
            let start = try session.askOnService("stream", service: LiveStream.svcStream,
                                                 type: StreamType.control,
                                                 payload: Self.controlStream(nonce: Self.nonce(), action: 1),
                                                 answerType: StreamType.controlAck, timeout: 8)
            log("start: \(Self.answerWords(start))")
        } catch {
            log("live start failed: \(error)")
            lastError = "\(error)"
            setPhase(.failed)
            running = false
            return
        }
        readLoop()
    }

    /// Owns the link while streaming: everything on the stream channel lands here.
    private func readLoop() {
        while running {
            let message: DataX.Message
            do {
                message = try session.nextMessage(timeout: 1.5)
            } catch {
                if running { lastError = "\(error)"; log("stream read: \(error)") }
                continue
            }
            guard message.service == LiveStream.svcStream || message.type == Int(StreamType.stopped) else { continue }
            guard let type = message.type else { continue }
            switch UInt16(truncatingIfNeeded: type) {
            case StreamType.codecConfig:
                takeCodecConfig(message.payload)
            case StreamType.videoBuffer:
                frameBuf.append(message.payload)
                meter(message.payload.count)
            case StreamType.videoEnd:
                frameBuf.append(message.payload)
                meter(message.payload.count)
                finishFrame()
            case StreamType.photoBuffer:
                photoBuf.append(message.payload)
            case StreamType.photoEnd:
                photoBuf.append(message.payload)
                finishPhoto()
            case StreamType.stopped:
                log("glasses stopped the stream (reason \(message.payload.count)B)")
                running = false
                setPhase(.failed)
                lastError = "stream stopped by the glasses"
            case StreamType.lifecycle:
                log("lifecycle event")
            default:
                break
            }
        }
    }

    // MARK: frames

    /// CODEC_CONFIGURATION_UPDATE_REQUEST: field 3 is the parameter sets, field 2 says which codec.
    private func takeCodecConfig(_ payload: Data) {
        guard let f = try? PB.parse(payload), let config = f[3]?.first as? Data else { return }
        let units = Self.annexBUnits(config)
        guard !units.isEmpty else { return }
        if let fmt = Self.hevcFormat(units) {
            format = fmt
            layer.flush()
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
        guard !units.isEmpty, let fmt = format else { return }
        lastFrameAt = Date()
        frames += 1
        windowFrames += 1
        if phase != .running { setPhase(.running) }
        guard let sample = Self.sampleBuffer(units: units, format: fmt, pts: CMTime(value: CMTimeValue(pts), timescale: 1_000_000)) else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        if let dims = CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions) {
            decodedSize = CGSize(width: Int(dims.width), height: Int(dims.height))
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
        onPhoto?(LivePhoto(data: data, isHeic: heic))
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
        let params = units.filter { u in
            guard let h = u.first else { return false }
            let t = (h >> 1) & 0x3F
            return t == 32 || t == 33 || t == 34     // VPS, SPS, PPS
        }
        guard !params.isEmpty else { return nil }
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

    /// Annex-B NAL units into one AVCC sample buffer the display layer takes.
    static func sampleBuffer(units: [Data], format: CMVideoFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        var avcc = Data()
        for u in units {
            var len = UInt32(u.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(u)
        }
        var block: CMBlockBuffer?
        let mem = UnsafeMutableRawPointer.allocate(byteCount: max(1, avcc.count), alignment: 1)
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: avcc.count,
            blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard created == kCMBlockBufferNoErr, let block else {
            mem.deallocate()
            return nil
        }
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        // The block buffer owns the memory now; the block allocator is null so free it with the buffer.
        guard status == noErr, let sample else { return nil }
        return sample
    }
}
