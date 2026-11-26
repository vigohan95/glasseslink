import Foundation
import SherpaOnnx

/// A natural Chinese voice that ships with the app: Kokoro v1.1-zh (int8) through sherpa-onnx, on the
/// phone, offline and free. The glasses have no Chinese voice of their own (Meta offers English and
/// Italian ones only), and the iPhone's standard Chinese voices sound mechanical; this is what every
/// user gets without downloading anything. The model lies in the app bundle under `kokoro/`; the build
/// fetches it (see .github/workflows/ios.yml), so a build without it simply has no such voice.
final class NeuralVoice: @unchecked Sendable {
    static let shared = NeuralVoice()

    /// The identifier a voice picker stores for one of these voices: "kokoro:<speaker>".
    static let prefix = "kokoro:"

    /// The model's speakers in the order of its voices.bin (Kokoro v1.1-zh: three English voices, then
    /// the Chinese women's and men's voices that exist, by number).
    static let speakers: [String] = {
        let women: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 21, 22, 23, 24, 26, 27, 28, 32, 36, 38, 39, 40, 42,
                            43, 44, 46, 47, 48, 49, 51, 59, 60, 67, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 83, 84,
                            85, 86, 87, 88, 90, 92, 93, 94, 99]
        let men: [Int] = [9, 10, 11, 12, 13, 14, 15, 16, 20, 25, 29, 30, 31, 33, 34, 35, 37, 41, 45, 50, 52, 53,
                          54, 55, 56, 57, 58, 61, 62, 63, 64, 65, 66, 68, 69, 80, 81, 82, 89, 91, 95, 96, 97, 98, 100]
        var names = ["af_maple", "af_sol", "bf_vale"]
        names += women.map { String(format: "zf_%03d", $0) }
        names += men.map { String(format: "zm_%03d", $0) }
        return names
    }()

    /// The women's voices offered in the settings, first is the default.
    static let offered: [Int] = Array(speakers.indices.filter { speakers[$0].hasPrefix("zf_") }.prefix(12))
    static var defaultSpeaker: Int { offered.first ?? 0 }

    static var directory: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("kokoro", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("model.int8.onnx").path) else {
            return nil
        }
        return url
    }

    static var isAvailable: Bool { directory != nil }

    /// "AI 女声 3（内置）".
    static func label(_ speaker: Int) -> String {
        if let index = offered.firstIndex(of: speaker) { return "AI 女声 \(index + 1)（内置）" }
        return speakers.indices.contains(speaker) ? "AI 声音 \(speakers[speaker])（内置）" : "AI 声音（内置）"
    }

    private let queue = DispatchQueue(label: "glasseslink.neural-voice", qos: .userInitiated)
    /// Only on `queue`.
    private var engine: SherpaOnnxOfflineTtsWrapper?
    private var failed = false

    /// `text` spoken by `speaker`, as mono floats at the model's rate (24 kHz). Nil when the model is not
    /// in this build, would not load, or gave nothing.
    func speak(_ text: String, speaker: Int, speed: Float = 1.0) async -> (samples: [Float], rate: Double)? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.generate(text, speaker: speaker, speed: speed))
            }
        }
    }

    /// Loads the model ahead of the first answer, which then does not wait for it.
    func warmUp() {
        queue.async { _ = self.load() }
    }

    private func generate(_ text: String, speaker: Int, speed: Float) -> (samples: [Float], rate: Double)? {
        guard !text.isEmpty, Self.speakers.indices.contains(speaker), let tts = load() else { return nil }
        let audio = tts.generate(text: text, sid: speaker, speed: speed)
        let samples = audio.samples
        let rate = Double(audio.sampleRate)
        guard !samples.isEmpty, rate > 0 else { return nil }
        return (samples, rate)
    }

    private func load() -> SherpaOnnxOfflineTtsWrapper? {
        if let engine { return engine }
        guard !failed, let directory = Self.directory else {
            failed = true
            return nil
        }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        // The C strings the configuration points at live until this pool drains, past the engine's
        // creation, which copies what it keeps.
        let made: SherpaOnnxOfflineTtsWrapper? = autoreleasepool {
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: path("model.int8.onnx"),
                voices: path("voices.bin"),
                tokens: path("tokens.txt"),
                dictDir: path("dict"),
                lexicon: path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt"))
            let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
            let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads, debug: 0)
            // Numbers, dates and phone numbers read the Chinese way.
            let rules = ["phone-zh.fst", "date-zh.fst", "number-zh.fst"].map(path)
                .filter { FileManager.default.fileExists(atPath: $0) }.joined(separator: ",")
            var config = sherpaOnnxOfflineTtsConfig(model: model, ruleFsts: rules, maxNumSentences: 1)
            let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
            return tts.tts == nil ? nil : tts
        }
        engine = made
        failed = made == nil
        return made
    }
}
