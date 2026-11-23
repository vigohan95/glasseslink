import Foundation

/// The answer struct the glasses accept as a real VARM (visitor-facing voice answer).
///
/// Visor ships a captured `varm_template.bin` and splices our strings into it instead of
/// re-encoding the struct, because re-encoding would change integer widths the glasses
/// care about (`core/assistant/.../Oxide.kt:174`). This is the same trick, in Swift:
/// walk the compact-encoded bytes, record the exact byte span of every binary field, and
/// replace only the ones whose value is a key of the mapping.
enum VarmSplice {
    struct Span {
        let lengthStart: Int
        let dataEnd: Int
        let value: Data
    }

    static func spans(_ b: Data) -> [Span] {
        var out: [Span] = []
        _ = scanStruct(b, 0, &out)
        return out
    }

    static func replace(_ raw: Data, _ mapping: [String: Data]) -> Data {
        var out = raw
        for span in spans(raw).sorted(by: { $0.lengthStart > $1.lengthStart }) {
            let key = String(data: span.value, encoding: .utf8) ?? ""
            guard let replacement = mapping[key] else { continue }
            let end = min(span.dataEnd, out.count)
            var next = Data()
            next.append(out[0..<span.lengthStart])
            next.append(Varint.encode(UInt64(replacement.count)))
            next.append(replacement)
            if end < out.count { next.append(out[end..<out.count]) }
            out = next
        }
        return out
    }

    /// Flip one top-level boolean field in place.
    static func setBool(_ raw: Data, _ fid: Int, _ value: Bool) -> Data {
        var at = 0
        var cur = 0
        while true {
            guard let head = fieldHead(raw, at, cur) else { return raw }
            cur = head.fid
            if cur == fid, head.type == TC.tTrue || head.type == TC.tFalse {
                let want = value ? TC.tTrue : TC.tFalse
                if head.type == want { return raw }
                var next = raw
                next[at] = (raw[at] & 0xF0) | want
                return next
            }
            guard let next = valueEnd(raw, head.offset, head.type) else { return raw }
            at = next
        }
    }

    // MARK: - compact protocol walk

    private struct Head { let fid: Int; let type: UInt8; let offset: Int }

    private static func fieldHead(_ b: Data, _ at: Int, _ lastFid: Int) -> Head? {
        guard at < b.count else { return nil }
        let h = Int(b[at])
        if h == Int(TC.stop) { return nil }
        let delta = h >> 4
        let type = UInt8(h & 0x0F)
        if delta != 0 { return Head(fid: lastFid + delta, type: type, offset: at + 1) }
        guard let v = try? Varint.decode(b, at + 1) else { return nil }
        let n = Int64(bitPattern: v.0)
        let fid = Int((n >> 1) ^ -(n & 1))
        return Head(fid: fid, type: type, offset: v.1)
    }

    private static func scanStruct(_ b: Data, _ start: Int, _ out: inout [Span]) -> Int {
        var i = start
        var fid = 0
        while true {
            guard let head = fieldHead(b, i, fid) else { return i < b.count ? i + 1 : i }
            fid = head.fid
            i = scanValue(b, head.offset, head.type, &out)
        }
    }

    private static func scanElement(_ b: Data, _ start: Int, _ t: UInt8, _ out: inout [Span]) -> Int {
        if t == TC.tTrue || t == TC.tFalse { return start + 1 }
        return scanValue(b, start, t, &out)
    }

    private static func scanValue(_ b: Data, _ start: Int, _ t: UInt8, _ out: inout [Span]) -> Int {
        var i = start
        switch t {
        case TC.tTrue, TC.tFalse:
            return i
        case TC.i8:
            return i + 1
        case TC.i16, TC.i32, TC.i64:
            guard let v = try? Varint.decode(b, i) else { return b.count }
            return v.1
        case TC.double:
            return i + 8
        case 13: // float, some producers emit it
            return i + 4
        case TC.bin:
            let lengthStart = i
            guard let v = try? Varint.decode(b, i) else { return b.count }
            i = v.1
            let remaining = max(0, b.count - i)
            let take = Int(min(v.0, UInt64(remaining)))
            let end = i + take
            out.append(Span(lengthStart: lengthStart, dataEnd: end, value: b.subdata(in: i..<end)))
            return end
        case TC.list, TC.set:
            guard i < b.count else { return b.count }
            var count = Int(b[i] >> 4)
            let etype = b[i] & 0x0F
            i += 1
            if count == 15 {
                guard let v = try? Varint.decode(b, i) else { return b.count }
                count = Int(v.0)
                i = v.1
            }
            for _ in 0..<max(0, count) { i = scanElement(b, i, etype, &out) }
            return i
        case TC.map:
            guard let v = try? Varint.decode(b, i) else { return b.count }
            let count = Int(v.0)
            i = v.1
            if count == 0 { return i }
            guard i < b.count else { return b.count }
            let kv = b[i]
            i += 1
            let ktype = kv >> 4
            let vtype = kv & 0x0F
            for _ in 0..<count {
                i = scanElement(b, i, ktype, &out)
                i = scanElement(b, i, vtype, &out)
            }
            return i
        case TC.structure:
            return scanStruct(b, i, &out)
        default:
            return b.count
        }
    }

    /// Where the value that starts at `start` ends, without recording spans.
    private static func valueEnd(_ b: Data, _ start: Int, _ t: UInt8) -> Int? {
        var sink: [Span] = []
        let end = scanValue(b, start, t, &sink)
        return end > start ? end : nil
    }
}

/// Builds the ev53 `VoiceActionResponseMessage` payload from the captured template.
enum Varm {
    /// The template ships inside Visor (`core/assistant/src/main/resources/varm_template.bin`).
    private static let template: Data? = {
        let bundles = [Bundle.main, Bundle(for: VarmBundleToken.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "varm_template", withExtension: "bin"),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }()

    static var available: Bool { template != nil }

    /// - Parameters:
    ///   - onGlasses: true when the glasses should speak it themselves: fields 6
    ///     (`streamingBackTts`) and 14 (`isUsingPartialResponseStreaming`) go false, so no
    ///     audio has to follow and ev60 carries the words.
    ///   - voiceID: field 13 `speakRequestVoiceId`, e.g. `en_US.58`; nil keeps the captured one.
    static func build(interaction: String, transcript: String, text: String,
                      onGlasses: Bool = true, voiceID: String? = nil, card: Bool = false) -> Data? {
        guard let raw = template else { return nil }
        guard let old = try? ThriftCompact.loads(raw) else { return nil }
        guard let server = old[1] as? [Int: Any] else { return nil }

        var mapping: [String: Data] = [:]
        if let d = old[8] as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty {
            mapping[s] = Data(interaction.utf8)
        }
        if let req = server[2] as? [Int: Any],
           let d = req[1] as? Data,
           let s = String(data: d, encoding: .utf8), !s.isEmpty {
            mapping[s] = Data((transcript.isEmpty ? text : transcript).utf8)
        }
        if let answers = server[3] as? [Any],
           let first = answers.first as? [Int: Any],
           let inner = first[2] as? [Int: Any],
           let d = inner[1] as? Data,
           let s = String(data: d, encoding: .utf8), !s.isEmpty {
            mapping[s] = Data(text.utf8)
        }
        if onGlasses, let voiceID, !voiceID.isEmpty,
           let d = old[13] as? Data,
           let s = String(data: d, encoding: .utf8), !s.isEmpty {
            mapping[s] = Data(voiceID.utf8)
        }

        let spliced = VarmSplice.replace(raw, mapping)
        guard onGlasses else {
            return card ? VarmSplice.setBool(spliced, 24, true) : spliced
        }
        var quiet = spliced
        quiet = VarmSplice.setBool(quiet, 6, false)
        quiet = VarmSplice.setBool(quiet, 14, false)
        return card ? VarmSplice.setBool(quiet, 24, true) : quiet
    }

    /// ev60 body: `{1 interaction, 2 status 1000, 3 "", 4 {1 text, 2 type 1, 3 expectsAnswer,
    /// 4 false, 7 streamed, 8 streamed, 11 followUp}}`. With `streamed` false the glasses
    /// speak the text themselves.
    static func complete(interaction: String, text: String,
                         expectsAnswer: Bool = false, followUp: Bool = false,
                         streamed: Bool = false) -> Data {
        let result = ThriftWriter()
            .string(1, text)
            .i32(2, 1)
            .bool(3, expectsAnswer)
            .bool(4, false)
            .bool(7, streamed)
            .bool(8, streamed)
            .bool(11, followUp)
            .done()
        return ThriftWriter()
            .string(1, interaction)
            .i32(2, 1000)
            .string(3, "")
            .structField(4, result)
            .done()
    }

    /// Visor only asks the glasses to listen again when the answer reads like a question.
    static let asks = try! NSRegularExpression(pattern: "\\?|？|吗|呢|要不要|是不是", options: [])
}

/// Gives `Bundle(for:)` a type inside the app module, so `Varm` can find its template
/// in a unit-test host too.
final class VarmBundleToken {}