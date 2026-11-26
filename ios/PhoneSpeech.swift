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
        let value = UserDefaults.standard.string(forKey: key) ?? defaultTag
        return value == glasses ? nil : value
    }

    /// What a new user starts with: the iPhone's own language when it is offered here, else the glasses'
    /// own recognition. Nobody should have to find a setting before their language works.
    static var defaultTag: String { tag(forPreferred: Locale.preferredLanguages.first ?? "en") }

    static func tag(forPreferred language: String) -> String {
        if language.hasPrefix("yue") || language.hasPrefix("zh-HK") || language.hasPrefix("zh-Hant-HK")
            || language.hasPrefix("zh-Hant-MO") { return "zh-HK" }
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") { return "zh-TW" }
        if language.hasPrefix("zh") { return "zh-CN" }
        let code = String(language.prefix(2))
        return choices.first { $0.tag.hasPrefix(code + "-") }?.tag ?? glasses
    }

    struct Choice: Identifiable {
        let tag: String
        let name: String
        var id: String { tag }
    }

    static let choices = [
        Choice(tag: "zh-CN", name: "普通话"), Choice(tag: "zh-HK", name: "粤语"),
        Choice(tag: "zh-TW", name: "国语（台湾）"), Choice(tag: "ja-JP", name: "日本語"),
        Choice(tag: "ko-KR", name: "한국어"), Choice(tag: "es-ES", name: "Español"),
        Choice(tag: "fr-FR", name: "Français"), Choice(tag: "de-DE", name: "Deutsch"),
        Choice(tag: "it-IT", name: "Italiano"), Choice(tag: "pt-BR", name: "Português"),
        Choice(tag: glasses, name: "眼镜自带识别（English 等）"),
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
        if all.contains("Dictation") || all.contains("听写") || all.contains("kLSRErrorDomain 201") {
            return "iPhone 的听写没有打开：到「设置 › 通用 › 键盘」打开「启用听写」后再试。"
        }
        if peak < 0.004 { return "眼镜送来的录音没有声音，手机识别不出内容。" }
        // 1110 is "no speech detected": nobody spoke, which is no fault.
        guard let first = failures.first(where: { !$0.contains(" 1110") }) else { return nil }
        if first.hasPrefix("no result in") { return "手机语音识别一直没有给出结果，请检查 iPhone 的网络后再试。" }
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
        return (text, text.isEmpty ? failure : nil)
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
        // Chinese characters alone are Chinese, or Japanese when that is what the wearer speaks.
        if han > 0 { return preferred.hasPrefix("zh") || preferred.hasPrefix("ja") ? preferred : "zh-CN" }
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

    /// One installed voice, for the settings page.
    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    private static func chosenKey(_ localeTag: String) -> String { "answerVoice." + localeTag }

    /// The natural voices installed for the language, best first: a downloaded premium or enhanced one
    /// before a standard one, a woman's voice before a man's (the user asked for one), and the system's
    /// own voice for the language before the rest.
    static func candidates(for localeTag: String) -> [AVSpeechSynthesisVoice] {
        let standard = AVSpeechSynthesisVoice(language: localeTag)?.identifier
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            voice.quality.rawValue * 100 + (voice.gender == .female ? 10 : 0) + (voice.identifier == standard ? 1 : 0)
        }
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language == localeTag && isNatural($0) }
            .sorted { rank($0) > rank($1) }
    }

    /// Mandarin, which the bundled voice speaks; Cantonese it does not.
    static func mandarin(_ localeTag: String) -> Bool {
        localeTag == "zh" || localeTag.hasPrefix("zh-CN") || localeTag.hasPrefix("zh-TW") || localeTag.hasPrefix("zh-Hans")
    }

    static func choices(for localeTag: String) -> [Choice] {
        var list: [Choice] = []
        if mandarin(localeTag), NeuralVoice.isAvailable {
            list = NeuralVoice.offered.map { Choice(id: NeuralVoice.prefix + String($0), name: NeuralVoice.label($0)) }
        }
        return list + candidates(for: localeTag).map { Choice(id: $0.identifier, name: label($0)) }
    }

    /// What "自动" means for the language, for the picker.
    static func automaticLabel(for localeTag: String) -> String {
        mandarin(localeTag) && NeuralVoice.isAvailable ? "自动（内置 AI 女声）" : "自动（音质最好的女声）"
    }

    /// The voice the user picked for the language; empty for "the best there is", also once it is gone.
    static func chosenIdentifier(for localeTag: String) -> String {
        let stored = UserDefaults.standard.string(forKey: chosenKey(localeTag)) ?? ""
        if stored.hasPrefix(NeuralVoice.prefix) { return NeuralVoice.isAvailable ? stored : "" }
        return stored.isEmpty || AVSpeechSynthesisVoice(identifier: stored) == nil ? "" : stored
    }

    /// The bundled voice's speaker for answers in this language, or nil when the iPhone's voice reads them:
    /// another language than Mandarin, a build without the model, or a system voice picked by hand.
    static func neuralSpeaker(for localeTag: String) -> Int? {
        guard mandarin(localeTag), NeuralVoice.isAvailable else { return nil }
        let stored = chosenIdentifier(for: localeTag)
        if stored.isEmpty { return NeuralVoice.defaultSpeaker }
        guard stored.hasPrefix(NeuralVoice.prefix), let speaker = Int(stored.dropFirst(NeuralVoice.prefix.count)),
              NeuralVoice.speakers.indices.contains(speaker) else { return nil }
        return speaker
    }

    static func choose(_ identifier: String, for localeTag: String) {
        UserDefaults.standard.set(identifier, forKey: chosenKey(localeTag))
    }

    /// The voice answers in this language are read with: the user's pick, else the best installed.
    static func voice(for localeTag: String) -> AVSpeechSynthesisVoice? {
        let stored = chosenIdentifier(for: localeTag)
        if !stored.isEmpty, let picked = AVSpeechSynthesisVoice(identifier: stored) { return picked }
        return candidates(for: localeTag).first ?? AVSpeechSynthesisVoice(language: localeTag)
    }

    /// "婷婷（标准音质 · 女声）", for the log and the settings page.
    static func label(_ voice: AVSpeechSynthesisVoice?) -> String {
        guard let voice else { return "系统默认" }
        let quality: String
        switch voice.quality {
        case .premium: quality = "高音质"
        case .enhanced: quality = "优化音质"
        default: quality = "标准音质"
        }
        let gender = voice.gender == .female ? " · 女声" : (voice.gender == .male ? " · 男声" : "")
        return "\(voice.name)（\(quality)\(gender)）"
    }

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
        let language = languageTag(of: words, preferred: localeTag)
        if let speaker = neuralSpeaker(for: language), let made = await NeuralVoice.shared.speak(words, speaker: speaker),
           let samples = resample(made.samples, from: made.rate, to: target.sampleRate),
           let out = padded(samples, format: target) {
            return (out, NeuralVoice.label(speaker))
        }
        let chosen = voice(for: language)
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
        guard !spoken.isEmpty, let out = padded(spoken, format: target) else { return nil }
        return (out, label(chosen))
    }

    /// `spoken` with a moment of silence before and the closing silence after, as one buffer.
    static func padded(_ spoken: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !spoken.isEmpty else { return nil }
        let samples = [Float](repeating: 0, count: Int(leadingSilence * format.sampleRate)) + spoken
            + [Float](repeating: 0, count: Int(trailingSilence * format.sampleRate))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = out.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        out.frameLength = AVAudioFrameCount(samples.count)
        return out
    }

    /// Mono floats from one rate to another, in one pass that also flushes the converter's tail.
    static func resample(_ samples: [Float], from rate: Double, to target: Double) -> [Float]? {
        guard !samples.isEmpty, rate > 0, target > 0 else { return nil }
        if rate == target { return samples }
        guard let input = OpusCodec.pcmFormat(sampleRate: rate), let output = OpusCodec.pcmFormat(sampleRate: target),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { channel.update(from: base, count: samples.count) }
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        let capacity = AVAudioFrameCount(Double(samples.count) * target / rate) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if fed {
                state.pointee = .endOfStream
                return nil
            }
            fed = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, out.frameLength > 0, let result = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: result, count: Int(out.frameLength)))
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

/// Questions about what the wearer is looking at, which need a picture from the glasses' camera.
enum VisualQuestion {
    private static let chinese = ["看看", "看一下", "看下", "帮我看", "你看", "看到", "看见", "这是什么", "这是啥", "这什么",
                                  "那是什么", "那是啥", "眼前", "面前", "手里", "手上", "读一下", "念一下", "读给我", "写的是",
                                  "写的什么", "写着", "什么字", "什么牌子", "什么颜色", "什么东西", "这道题", "识别"]
    private static let english = "look|looking|see|seeing|read this|read that|read the|describe|what is this|what's this|"
        + "what is that|what's that|in front of me|identify|what am i|which is this|how much is this|"
        + "translate this|picture|pictures|photo|photos"

    /// Visor's soundsVisual, with Chinese: whole words in English, so "seems" does not count.
    static func sounds(_ question: String) -> Bool {
        let text = question.lowercased()
        if chinese.contains(where: { text.contains($0) }) { return true }
        return text.range(of: "\\b(\(english))\\b", options: .regularExpression) != nil
    }

    /// What is said while the slow way to a picture runs, in the language of the question.
    static func holdOn(for question: String) -> String {
        let han = question.unicodeScalars.contains { (0x3400 ... 0x9FFF).contains($0.value) }
        return han ? "稍等，我拍一张看看。" : "One moment, let me take a picture."
    }

    /// Whatever the glasses sent, as a JPEG a model takes: a bare JPEG or HEIC, or one packed behind the
    /// assistant's own data, which is then searched for where the image begins (Visor's toModelJpeg).
    static func modelPicture(_ bytes: Data) -> Data? {
        if let direct = ModelClient.modelImage(bytes) { return direct }
        if let jpeg = bytes.range(of: Data([0xFF, 0xD8, 0xFF])),
           let found = ModelClient.modelImage(Data(bytes[jpeg.lowerBound...])) { return found }
        if let box = bytes.range(of: Data("ftyp".utf8)), box.lowerBound - bytes.startIndex >= 4,
           let found = ModelClient.modelImage(Data(bytes[(box.lowerBound - 4)...])) { return found }
        return nil
    }
}

/// The iPhone speaking aloud through whatever its audio output is, which is the glasses when they are
/// paired for sound. For the answers the glasses will not play themselves.
@MainActor
final class PhoneSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    /// Bumped by every new sentence and by `stop`; a voice that finishes for an older one stays silent.
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` and returns the voice chosen for it.
    @discardableResult
    func say(_ text: String, preferred localeTag: String) -> String {
        let words = PhoneVoice.speakable(text)
        guard !words.isEmpty else { return "" }
        stop()
        let language = PhoneVoice.languageTag(of: words, preferred: localeTag)
        if let speaker = PhoneVoice.neuralSpeaker(for: language) {
            let turn = generation
            Task { [weak self] in
                let made = await NeuralVoice.shared.speak(words, speaker: speaker)
                guard let self, self.generation == turn else { return }
                if let made {
                    self.play(made.samples, rate: made.rate)
                } else {
                    _ = self.speakWithSystem(words, language: language)
                }
            }
            return NeuralVoice.label(speaker)
        }
        return speakWithSystem(words, language: language)
    }

    func stop() {
        generation += 1
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if attached { player.stop() }
        if engine.isRunning { engine.stop() }
    }

    private func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func speakWithSystem(_ words: String, language: String) -> String {
        activate()
        let voice = PhoneVoice.voice(for: language)
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = voice
        synthesizer.speak(utterance)
        return PhoneVoice.label(voice)
    }

    private func play(_ samples: [Float], rate: Double) {
        guard let format = OpusCodec.pcmFormat(sampleRate: rate),
              let buffer = PhoneVoice.padded(samples, format: format) else { return }
        activate()
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        let turn = generation
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == turn else { return }
                self.player.stop()
                self.engine.stop()
                self.release()
            }
        }
        player.play()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    /// Hands the audio output back, so music that was turned down comes up again.
    private func release() {
        guard !synthesizer.isSpeaking, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
