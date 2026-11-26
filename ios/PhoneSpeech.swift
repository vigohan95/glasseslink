import AVFoundation
import Speech

/// Hey Meta in a language the glasses do not recognise themselves. After the wake word the glasses stream
/// their microphone as Opus; here it is decoded and given to the iPhone's speech recogniser, and the answer
/// is spoken by the iPhone's voice and sent back as Opus for the glasses to play (Visor's GlassesEars and Voice).
enum HeyMetaLanguage {
    static let key = "heyMetaLanguage"
    /// The glasses' own recogniser and voice: English only on this firmware.
    static let glasses = "glasses"

    /// A BCP-47 tag for the phone's recogniser and voice, or nil to leave both to the glasses.
    static var phoneLocale: String? {
        let value = UserDefaults.standard.string(forKey: key) ?? "zh-CN"
        return value == glasses ? nil : value
    }

    struct Choice: Identifiable {
        let tag: String
        let name: String
        var id: String { tag }
    }

    static let choices = [
        Choice(tag: "zh-CN", name: "普通话"), Choice(tag: "zh-HK", name: "粤语"),
        Choice(tag: "zh-TW", name: "国语（台湾）"), Choice(tag: glasses, name: "English（眼镜自带识别）"),
    ]
}

/// The recogniser of the question being asked; the assistant's thread sets and reads it.
final class EarsBox: @unchecked Sendable {
    var current: GlassesEars?
}

/// One question's worth of microphone audio from the glasses, recognised on the phone.
final class GlassesEars: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer?
    private var decoder = OpusCodec.Decoder()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var best = ""
    private var finished = false
    private var waiter: CheckedContinuation<String, Never>?
    private(set) var packets = 0
    private(set) var undecoded = 0
    let localeTag: String

    init(localeTag: String) {
        self.localeTag = localeTag
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeTag))
    }

    /// Asks once, in the foreground; the answer arrives later and is read from `isAuthorized`.
    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { status in done(status == .authorized) }
        default: done(false)
        }
    }

    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && recognizer?.isAvailable == true
    }

    /// Starts listening for one question. Safe to call again for the next one.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        best = ""
        finished = false
        packets = 0
        undecoded = 0
        waiter?.resume(returning: "")
        waiter = nil
        guard isAvailable, let recognizer else {
            request = nil
            task = nil
            return
        }
        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        fresh.addsPunctuation = true
        // Accuracy first: the server recogniser when there is a network, the on-device one otherwise.
        fresh.requiresOnDeviceRecognition = false
        fresh.taskHint = .dictation
        request = fresh
        task = recognizer.recognitionTask(with: fresh) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result { self.best = result.bestTranscription.formattedString }
            let ended = error != nil || result?.isFinal == true
            let waiting = ended ? self.waiter : nil
            if ended {
                self.finished = true
                self.waiter = nil
            }
            let text = self.best
            self.lock.unlock()
            waiting?.resume(returning: text)
        }
    }

    /// One chunk of the glasses' microphone stream.
    func hear(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let request, let decoder else { return }
        for packet in OpusFraming.packets(in: chunk) {
            packets += 1
            if let pcm = decoder.decode(packet) {
                request.append(pcm)
            } else {
                undecoded += 1
            }
        }
    }

    /// Ends the audio and returns what was recognised; empty when nothing was, or after `timeout`.
    func finish(timeout: TimeInterval = 6) async -> String {
        if let already = endAudio() { return already }
        let limit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.giveUp()
        }
        defer { limit.cancel() }
        return await withCheckedContinuation { continuation in
            if let text = park(continuation) { continuation.resume(returning: text) }
        }
    }

    /// Closes the audio. The words when recognition is already over (or never began), else nil.
    private func endAudio() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let request else { return "" }
        request.endAudio()
        return finished ? best : nil
    }

    /// Keeps the continuation for the recogniser's last result; the words at once when it already came.
    private func park(_ continuation: CheckedContinuation<String, Never>) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return best }
        waiter = continuation
        return nil
    }

    private func giveUp() {
        lock.lock()
        let waiting = waiter
        waiter = nil
        finished = true
        let text = best
        lock.unlock()
        task?.cancel()
        waiting?.resume(returning: text)
    }
}

/// The iPhone's voice as Opus packets for the glasses to play.
enum PhoneVoice {
    /// The best installed voice for the language: premium, then enhanced, then the default.
    static func voice(for localeTag: String) -> AVSpeechSynthesisVoice? {
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == localeTag }
        return matching.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: localeTag)
    }

    /// `text` spoken, as 48 kHz mono floats. Nil when the synthesiser gives nothing within `timeout`.
    static func synthesize(_ text: String, localeTag: String, timeout: TimeInterval = 15) async -> AVAudioPCMBuffer? {
        guard let target = OpusCodec.pcmFormat(sampleRate: 48_000) else { return nil }
        let collector = Collector(target: target)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: localeTag)
        let synthesizer = AVSpeechSynthesizer()
        let limit = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.finish()
        }
        defer { limit.cancel() }
        let samples: [Float] = await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: $0) }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collector.finish()
                    return
                }
                collector.append(pcm)
            }
        }
        // The synthesiser has to outlive the wait above, or it stops mid-sentence.
        withExtendedLifetime(synthesizer) {}
        guard !samples.isEmpty, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = out.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        out.frameLength = AVAudioFrameCount(samples.count)
        return out
    }

    /// Gathers the synthesiser's buffers, resampled to the target format, and hands them over once.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let target: AVAudioFormat
        private var converter: AVAudioConverter?
        private var samples: [Float] = []
        private var done = false
        var onFinish: (([Float]) -> Void)?

        init(target: AVAudioFormat) { self.target = target }

        func append(_ pcm: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            if converter == nil || converter?.inputFormat != pcm.format {
                converter = AVAudioConverter(from: pcm.format, to: target)
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var failure: NSError?
            _ = converter.convert(to: out, error: &failure) { _, state in
                if fed {
                    state.pointee = .noDataNow
                    return nil
                }
                fed = true
                state.pointee = .haveData
                return pcm
            }
            if let channel = out.floatChannelData?[0], out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
        }

        func finish() {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            let result = samples
            let handler = onFinish
            onFinish = nil
            lock.unlock()
            handler?(result)
        }
    }
}
