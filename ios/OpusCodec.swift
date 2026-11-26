import AVFoundation

/// How the glasses pack Opus packets into one chunk of the assistant's microphone stream (Visor's
/// GlassesEars.hear): big-endian length-prefixed packets, 16-byte records, grouped records, or one bare
/// packet. Whichever reads the chunk to its last byte is the one.
///
/// This firmware (greathammerhead, glasses log 35) sends none of Visor's three but the layout of Opus's
/// own test streams: `[u32 BE length][u32 BE final range][packet]`. Taken for a bare packet, its eight
/// header bytes were decoded as sound, and the recogniser heard noise.
enum OpusFraming {
    private static let groupHead = 9

    /// Which of the layouts a chunk turned out to have; `bare` is also what an unknown layout looks like.
    enum Layout: String {
        case lengths = "length-prefixed"
        case ranged = "length and range"
        case records
        case bare
    }

    static func packets(in chunk: Data) -> [Data] { split(chunk).packets }

    static func split(_ chunk: Data) -> (packets: [Data], layout: Layout) {
        let bytes = [UInt8](chunk)
        guard !bytes.isEmpty else { return ([], .bare) }
        // No little-endian lengths at the top level: a record starts with its own little-endian length,
        // which would pass for one packet holding the rest of the chunk.
        if let found = lengthPrefixed(bytes, bigEndian: true) { return (found, .lengths) }
        if let found = ranged(bytes) { return (found, .ranged) }
        if let found = records(bytes) { return (found, .records) }
        return ([chunk], .bare)
    }

    /// `[u32 BE length][u32 BE final range][packet]`, once or more. A length of zero is a frame the
    /// encoder left out (silence); it carries no packet.
    private static func ranged(_ b: [UInt8]) -> [Data]? {
        var at = 0
        var out: [Data] = []
        while at + 8 <= b.count {
            let n = u32(b, at, bigEndian: true)
            guard n <= b.count - at - 8 else { return nil }
            if n > 0 { out.append(Data(b[at + 8 ..< at + 8 + n])) }
            at += 8 + n
        }
        return at == b.count && at > 0 ? out : nil
    }

    private static func u32(_ b: [UInt8], _ at: Int, bigEndian: Bool) -> Int {
        let v = bigEndian
            ? UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
            : UInt32(b[at + 3]) << 24 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 1]) << 8 | UInt32(b[at])
        return Int(v)
    }

    private static func lengthPrefixed(_ b: [UInt8], bigEndian: Bool, from start: Int = 0, to end: Int? = nil) -> [Data]? {
        let end = end ?? b.count
        var at = start
        var out: [Data] = []
        while at + 5 <= end {
            let n = u32(b, at, bigEndian: bigEndian)
            guard n > 0, n <= end - at - 4 else { return nil }
            out.append(Data(b[at + 4 ..< at + 4 + n]))
            at += 4 + n
        }
        return at == end && !out.isEmpty ? out : nil
    }

    /// `[len LE][ms LE][opusLen BE][4 bytes]` then the packet; or a grouped record whose `len` bytes hold a
    /// 9-byte head and little-endian length-prefixed packets.
    private static func records(_ b: [UInt8]) -> [Data]? {
        var at = 0
        var out: [Data] = []
        while at + 16 <= b.count {
            let len = u32(b, at, bigEndian: false)
            let opusLen = u32(b, at + 8, bigEndian: true)
            if opusLen > 0, opusLen <= b.count - at - 16 {
                out.append(Data(b[at + 16 ..< at + 16 + opusLen]))
                at += 16 + opusLen
            } else if len >= groupHead + 5, at + 4 + len <= b.count,
                      let group = lengthPrefixed(b, bigEndian: false, from: at + 4 + groupHead, to: at + 4 + len) {
                out += group
                at += 4 + len
            } else {
                return nil
            }
        }
        return at == b.count && !out.isEmpty ? out : nil
    }

    /// Seconds of audio in one packet, from its TOC byte (RFC 6716 section 3.1).
    static func duration(of packet: Data) -> Double {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Double
        switch config {
        case 0 ..< 12: frame = [0.010, 0.020, 0.040, 0.060][config & 3]
        case 12 ..< 16: frame = [0.010, 0.020][config & 1]
        default: frame = [0.0025, 0.005, 0.010, 0.020][config & 3]
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 3: count = packet.count > 1 ? Int(packet[packet.index(after: packet.startIndex)] & 0x3F) : 0
        default: count = 2
        }
        return frame * Double(count)
    }
}

/// The system's Opus codec through AVAudioConverter. The glasses send 16 kHz speech (SILK inside Opus);
/// answers go back as 48 kHz mono at 32 kbit/s in 20 ms packets, as Visor sends them.
enum OpusCodec {
    static func format(framesPerPacket: UInt32) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket,
                                                      mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
                                                      mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }

    static func pcmFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Decodes packets one by one to 16 kHz mono floats. Not thread-safe; one user at a time.
    final class Decoder {
        private var converter: AVAudioConverter?
        private var framesPerPacket: UInt32 = 0
        private let output: AVAudioFormat

        init?() {
            guard let output = OpusCodec.pcmFormat(sampleRate: 16_000) else { return nil }
            self.output = output
        }

        var outputFormat: AVAudioFormat { output }

        func decode(_ packet: Data) -> AVAudioPCMBuffer? {
            let frames = UInt32((OpusFraming.duration(of: packet) * 48_000).rounded())
            guard frames > 0, !packet.isEmpty else { return nil }
            if converter == nil || frames != framesPerPacket {
                guard let input = OpusCodec.format(framesPerPacket: frames),
                      let made = AVAudioConverter(from: input, to: output) else { return nil }
                converter = made
                framesPerPacket = frames
            }
            guard let converter else { return nil }
            let compressed = AVAudioCompressedBuffer(format: converter.inputFormat, packetCapacity: 1,
                                                     maximumPacketSize: packet.count)
            packet.withUnsafeBytes { source in
                if let base = source.baseAddress { compressed.data.copyMemory(from: base, byteCount: packet.count) }
            }
            compressed.byteLength = UInt32(packet.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                                  mDataByteSize: UInt32(packet.count))
            guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4_096) else { return nil }
            var fed = false
            var failure: NSError?
            let status = converter.convert(to: pcm, error: &failure) { _, state in
                if fed {
                    state.pointee = .noDataNow
                    return nil
                }
                fed = true
                state.pointee = .haveData
                return compressed
            }
            guard status != .error, pcm.frameLength > 0 else { return nil }
            return pcm
        }
    }

    /// 48 kHz mono floats to 20 ms packets at 32 kbit/s. Nil when this system has no Opus encoder.
    static func encode(_ pcm: AVAudioPCMBuffer) -> [Data]? {
        guard pcm.frameLength > 0, let output = format(framesPerPacket: 960),
              let converter = AVAudioConverter(from: pcm.format, to: output) else { return nil }
        converter.bitRate = 32_000
        var packets: [Data] = []
        var fed = false
        while true {
            let buffer = AVAudioCompressedBuffer(format: output, packetCapacity: 64,
                                                 maximumPacketSize: max(1_500, converter.maximumOutputPacketSize))
            var failure: NSError?
            let status = converter.convert(to: buffer, error: &failure) { _, state in
                if fed {
                    state.pointee = .endOfStream
                    return nil
                }
                fed = true
                state.pointee = .haveData
                return pcm
            }
            if status == .error { return packets.isEmpty ? nil : packets }
            if let descriptions = buffer.packetDescriptions {
                for index in 0 ..< Int(buffer.packetCount) {
                    let d = descriptions[index]
                    guard d.mDataByteSize > 0 else { continue }
                    packets.append(Data(bytes: buffer.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status == .endOfStream || buffer.packetCount == 0 { break }
        }
        return packets.isEmpty ? nil : packets
    }
}
