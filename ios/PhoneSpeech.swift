import AVFoundation
import NaturalLanguage
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

/// The words of one question as the recogniser reports them. Its text can start over after a pause in the
/// speech, and its last result can come back empty (both seen since iOS 18); neither may lose words.
struct SpokenWords {
    private var done = ""
    private var current = ""

    var text: String { Self.join(done, current) }

    mutating func take(_ heard: String) {
        let fresh = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fresh.isEmpty else { return }
        if Self.startsOver(fresh, after: current) { done = Self.join(done, current) }
        current = fresh
    }

    /// A revision keeps how the sentence began; a new start is much shorter and begins with other words.
    static func startsOver(_ fresh: String, after old: String) -> Bool {
        guard old.count >= 4, fresh.count * 2 < old.count else { return false }
        return !old.lowercased().hasPrefix(fresh.prefix(2).lowercased())
    }

    private static func join(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else { return first + second }
        // Words in Latin letters need a space between them; Chinese does not.
        let spaced = last.isASCII && !last.isWhitespace && next.isASCII && (next.isLetter || next.isNumber)
        return spaced ? first + " " + second : first + second
    }
}

/// "Hey Meta" as recognisers of Chinese and of English write it. The microphone stream begins with it.
enum WakeWord {
    private static let greeting = "(?:hey|hay|hei|hi|hello|ok|okay|嘿|嗨|黑|喂|诶|欸|哎)"
    private static let name = "(?:meta|mata|metta|matta|meda|mehta|mate|麦塔|麦它|麦他|麦达|美塔|美他|美达|梅塔|梅他|梅达|迈塔|迈他|妹塔|妹他)"
    private static let gap = "[\\s,，、.。]*"
    private static let tail = "[\\s,，、.。!！?？]*"
    private static let only = try! NSRegularExpression(pattern: "^\\s*\(greeting)?\(gap)\(name)\(tail)$",
                                                       options: [.caseInsensitive])
    private static let start = try! NSRegularExpression(pattern: "^\\s*\(greeting)\(gap)\(name)\(tail)",
                                                        options: [.caseInsensitive])

    /// The question without the wake word in front of it; empty when the wake word was all there was.
    static func strip(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        if only.firstMatch(in: text, range: whole) != nil { return "" }
        return start.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the phone made of one question.
struct Heard {
    /// The question, without the wake word; empty when nothing was recognised.
    let text: String
    /// Everything about the attempt, for the log.
    let report: String
    /// A sentence for the user when nothing was recognised and the phone's set-up is why.
    let problem: String?
}

/// One question's worth of microphone audio from the glasses, recognised on the phone.
final class GlassesEars: @unchecked Sendable {
    private static let keepFrames = 16_000 * 60

    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer?
    private var decoder = OpusCodec.Decoder()
    private var live: Recognition?
    private var kept: [AVAudioPCMBuffer] = []
    private var frames = 0
    private var peak: Float = 0
    private var crossings = 0
    private var wasPositive = false
    private var layout: OpusFraming.Layout?
    private var head = ""
    private var sealed = false
    private var packets = 0
    private var undecoded = 0
    let localeTag: String

    init(localeTag: String) {
        self.localeTag = localeTag
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeTag))
    }

    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Asks once, in the foreground; the answer arrives later and is read from `isAuthorized`.
    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { status in done(status == .authorized) }
        default: done(false)
        }
    }

    /// Starts listening for the question. The audio is kept as well, for a second try on the phone itself.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard live == nil, !sealed, Self.isAuthorized, let recognizer else { return }
        // Accuracy first: the server recogniser when there is a network.
        live = Recognition(recognizer: recognizer, onDevice: false)
    }

    /// One chunk of the glasses' microphone stream.
    func hear(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed, let decoder else { return }
        let parts = OpusFraming.split(chunk)
        if layout == nil {
            layout = parts.layout
            head = chunk.prefix(12).hex
        }
        for packet in parts.packets {
            packets += 1
            guard let pcm = decoder.decode(packet) else {
                undecoded += 1
                continue
            }
            measure(pcm)
            if frames <= Self.keepFrames { kept.append(pcm) }
            live?.append(pcm)
        }
    }

    /// Loudness and how often the signal changes sign: speech crosses zero a few times in a hundred
    /// samples, noise from a wrong decode about every other sample, silence has no peak.
    private func measure(_ pcm: AVAudioPCMBuffer) {
        guard let samples = pcm.floatChannelData?[0] else { return }
        let count = Int(pcm.frameLength)
        for index in 0 ..< count {
            let value = samples[index]
            let size = abs(value)
            if size.isFinite, size > peak { peak = size }
            let positive = value >= 0
            if positive != wasPositive { crossings += 1 }
            wasPositive = positive
        }
        frames += count
    }

    private struct Sealed {
        var live: Recognition?
        var pcm: [AVAudioPCMBuffer]
        var facts: String
        var seconds: Double
        var peak: Float
    }

    private func seal() -> Sealed {
        lock.lock()
        defer { lock.unlock() }
        sealed = true
        let seconds = Double(frames) / 16_000
        let rate = frames > 0 ? Double(crossings) / Double(frames) : 0
        var facts = String(format: "audio %.1f s, peak %.3f, sign changes %.2f, ", seconds, peak, rate)
        facts += "\(packets) packets (\(layout?.rawValue ?? "none")), \(undecoded) undecoded"
        if !head.isEmpty { facts += ", first chunk \(head)" }
        let result = Sealed(live: live, pcm: kept, facts: facts, seconds: seconds, peak: peak)
        live = nil
        kept = []
        return result
    }

    /// Ends the audio and returns what was recognised. When the first recogniser has no words, the same
    /// audio goes once to the one on the phone itself.
    func finish(timeout: TimeInterval = 5) async -> Heard {
        let state = seal()
        let authorized = Self.isAuthorized
        var text = ""
        var notes: [String] = []
        var failures: [String] = []
        if let first = state.live {
            let outcome = await first.end(timeout: timeout)
            text = outcome.text
            if let failure = outcome.failure { failures.append(failure) }
            notes.append("server: " + (outcome.failure ?? "\(outcome.text.count) characters"))
        } else if !authorized {
            notes.append("speech recognition is not authorised")
        } else if recognizer == nil {
            notes.append("no recogniser for \(localeTag)")
        }
        if text.isEmpty, !state.pcm.isEmpty, authorized, let recognizer, recognizer.supportsOnDeviceRecognition {
            let second = Recognition(recognizer: recognizer, onDevice: true)
            for pcm in state.pcm { second.append(pcm) }
            let outcome = await second.end(timeout: timeout)
            text = outcome.text
            if let failure = outcome.failure { failures.append(failure) }
            notes.append("on the phone: " + (outcome.failure ?? "\(outcome.text.count) characters"))
        }
        let question = WakeWord.strip(text)
        if question.isEmpty, !text.isEmpty { notes.append("only the wake word") }
        let report = "phone recogniser (\(localeTag)): \(question.count) characters; \(state.facts); "
            + notes.joined(separator: "; ")
        let problem = question.isEmpty && text.isEmpty
            ? Self.problem(authorized: authorized, hasRecognizer: recognizer != nil, seconds: state.seconds,
                           peak: state.peak, failures: failures)
            : nil
        return Heard(text: question, report: report, problem: problem)
    }

    /// Why the phone heard nothing, when that is something the user can put right. Nil for a question
    /// that simply was not asked.
    static func problem(authorized: Bool, hasRecognizer: Bool, seconds: Double, peak: Float,
                        failures: [String]) -> String? {
        if !authorized { return "语音识别还没有授权：到 iPhone「设置 › 隐私与安全性 › 语音识别」里打开 GlassesLink。" }
        if !hasRecognizer { return "这台 iPhone 不支持所选语言的语音识别，请在「眼镜设置」里换一种提问语言。" }
        guard seconds >= 0.3 else { return nil }
        let all = failures.joined(separator: " ")
        if all.contains("Dictation") || all.contains("kLSRErrorDomain 201") {
            return "iPhone 的听写没有打开：到「设置 › 通用 › 键盘」打开「启用听写」后再试。"
        }
        if peak < 0.004 { return "眼镜送来的录音没有声音，手机识别不出内容。" }
        // 1110 is "no speech detected": nobody spoke, which is no fault.
        guard let first = failures.first(where: { !$0.contains(" 1110") }) else { return nil }
        return "手机语音识别没有结果（\(first)）。"
    }
}

/// One run of the system recogniser over audio handed to it.
private final class Recognition: @unchecked Sendable {
    private let lock = NSLock()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var words = SpokenWords()
    private var failure: String?
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(recognizer: SFSpeechRecognizer, onDevice: Bool) {
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.took(result?.bestTranscription.formattedString, final: result?.isFinal == true, error: error)
        }
    }

    func append(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if !finished { request.append(pcm) }
    }

    private func took(_ text: String?, final: Bool, error: Error?) {
        lock.lock()
        if let text { words.take(text) }
        if let error, failure == nil {
            let known = error as NSError
            failure = "\(known.domain) \(known.code) \(known.localizedDescription)"
        }
        var waiting: CheckedContinuation<Void, Never>?
        if error != nil || final {
            finished = true
            waiting = waiter
            waiter = nil
        }
        lock.unlock()
        waiting?.resume()
    }

    /// Ends the audio and waits for the last result, `timeout` at most. Words that came before a failure
    /// still count.
    func end(timeout: TimeInterval) async -> (text: String, failure: String?) {
        if !closeAudio() {
            let limit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.giveUp(after: timeout)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !park(continuation) { continuation.resume() }
            }
            limit.cancel()
        }
        return outcome()
    }

    /// True when recognition is already over.
    private func closeAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        request.endAudio()
        return finished
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        waiter = continuation
        return true
    }

    private func giveUp(after timeout: TimeInterval) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if failure == nil { failure = "no result in \(Int(timeout)) s" }
        let waiting = waiter
        waiter = nil
        let running = task
        lock.unlock()
        running?.cancel()
        waiting?.resume()
    }

    private func outcome() -> (text: String, failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        let text = words.text
        return (text, text.isEmpty ? failure ?? "no words" : nil)
    }
}

/// The iPhone's voice as Opus packets for the glasses to play.
enum PhoneVoice {
    /// Silence after the last word: whatever the glasses cut when they close the answer is then not speech.
    private static let trailingSilence = 0.45
    private static let leadingSilence = 0.06

    private static let regions = ["en": "en-US", "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT",
                                  "pt": "pt-BR", "ru": "ru-RU", "ja": "ja-JP", "ko": "ko-KR"]

    /// The language to read `text` in: the one it is written in, so an English answer is not read by a
    /// Chinese voice. `preferred` decides between the kinds of Chinese and stands in when nothing is clear.
    static func languageTag(of text: String, preferred: String) -> String {
        var han = 0, kana = 0, hangul = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF: han += 1
            case 0x3040 ... 0x30FF: kana += 1
            case 0xAC00 ... 0xD7AF: hangul += 1
            default: break
            }
        }
        if kana > 0 { return "ja-JP" }
        if hangul > 0 { return "ko-KR" }
        if han > 0 { return preferred.hasPrefix("zh") ? preferred : "zh-CN" }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return preferred }
        let code = String(language.rawValue.prefix { $0 != "-" })
        guard !code.isEmpty, code != "und" else { return preferred }
        if preferred.hasPrefix(code + "-") { return preferred }
        if let known = regions[code] { return known }
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(code + "-") }?.language ?? preferred
    }

    /// Formant and novelty voices are listed with the ordinary ones and sound like machines; the first
    /// version picked one of them by accident (glasses log 34: "很生硬").
    static func isNatural(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let id = voice.identifier.lowercased()
        return !id.contains("eloquence") && !id.contains("speech.synthesis")
            && !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
    }

    /// The most natural installed voice for the language: a downloaded premium or enhanced one, else the
    /// one the system itself uses for that language.
    static func voice(for localeTag: String) -> AVSpeechSynthesisVoice? {
        let natural = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == localeTag && isNatural($0) }
        let downloaded = natural.filter { $0.quality.rawValue > AVSpeechSynthesisVoiceQuality.default.rawValue }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        if let downloaded { return downloaded }
        if let standard = AVSpeechSynthesisVoice(language: localeTag), isNatural(standard) { return standard }
        return natural.first ?? AVSpeechSynthesisVoice(language: localeTag)
    }

    /// "婷婷（标准音质）", for the log and the settings page.
    static func label(_ voice: AVSpeechSynthesisVoice?) -> String {
        guard let voice else { return "系统默认" }
        let quality: String
        switch voice.quality {
        case .premium: quality = "高音质"
        case .enhanced: quality = "优化音质"
        default: quality = "标准音质"
        }
        return "\(voice.name)（\(quality)）"
    }

    /// The voice an answer in `localeTag` is read with right now, for the settings page.
    static func currentLabel(for localeTag: String) -> String { label(voice(for: localeTag)) }

    /// Marks that would be read aloud as symbols.
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: "[*#`]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` spoken, as 48 kHz mono floats, and the voice that spoke it. Nil when the synthesiser gives
    /// nothing within `timeout`.
    static func synthesize(_ text: String, localeTag: String,
                           timeout: TimeInterval = 15) async -> (pcm: AVAudioPCMBuffer, voice: String)? {
        let words = speakable(text)
        guard !words.isEmpty, let target = OpusCodec.pcmFormat(sampleRate: 48_000) else { return nil }
        let chosen = voice(for: languageTag(of: words, preferred: localeTag))
        let collector = Collector(target: target)
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = chosen
        let synthesizer = AVSpeechSynthesizer()
        let limit = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.finish()
        }
        defer { limit.cancel() }
        let spoken: [Float] = await withCheckedContinuation { continuation in
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
        guard !spoken.isEmpty else { return nil }
        let lead = Int(leadingSilence * target.sampleRate)
        let samples = [Float](repeating: 0, count: lead) + spoken
            + [Float](repeating: 0, count: Int(trailingSilence * target.sampleRate))
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = out.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        out.frameLength = AVAudioFrameCount(samples.count)
        return (out, label(chosen))
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
