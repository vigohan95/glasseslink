import io

p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()

start = s.index("final class SDUStream")
end = s.index("final class Session")

new = '''final class SDUStream: NSObject, StreamDelegate {
    private let input: InputStream?
    private let output: OutputStream?

    private var buf: [UInt8] = []
    private var frames: [Data] = []
    private var closed = false
    private var lastError: Error?
    private let cond = NSCondition()

    private var writeHook: ((Data) throws -> Void)?
    private var reader: Thread?

    init(channel: CBL2CAPChannel) {
        input = channel.inputStream
        output = channel.outputStream
        super.init()
        startReader()
    }

    /// Test seam: a pair that never touches Bluetooth.
    private init(nullStreams: Void) {
        input = nil
        output = nil
        super.init()
    }

    private func startReader() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "sdu.reader"
        t.stackSize = 512 * 1024
        reader = t
        t.start()
    }

    /// One thread owns the input stream; it never pumps a run loop, so nothing the
    /// caller does can re-enter it. Frames are handed over through `frames`.
    private func readLoop() {
        guard let input else { return }
        input.open()
        output?.open()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = input.read(&chunk, maxLength: chunk.count)
            if n <= 0 { break }
            ingest(Array(chunk[0 ..< n]))
        }
        cond.lock()
        closed = true
        lastError = input.streamError
        cond.broadcast()
        cond.unlock()
    }

    private func ingest(_ bytes: [UInt8]) {
        cond.lock()
        buf.append(contentsOf: bytes)
        while let need = Self.frameLength(buf), need <= 8192, buf.count >= need {
            frames.append(Data(buf[0 ..< need]))
            buf.removeFirst(need)
        }
        if let need = Self.frameLength(buf), need > 8192 {
            print("[sdu] resync: header claimed \\(need)B, dropping a byte")
            if !buf.isEmpty { buf.removeFirst() }
        }
        cond.broadcast()
        cond.unlock()
    }

    static func loopbackPair() -> (a: SDUStream, b: SDUStream) {
        let a = SDUStream(nullStreams: ())
        let b = SDUStream(nullStreams: ())
        a.writeHook = { [weak b] data in b?.ingest([UInt8](data)) }
        b.writeHook = { [weak a] data in a?.ingest([UInt8](data)) }
        return (a, b)
    }

    /// Bytes pushed by a test (or by a hook) enter exactly the same path as the socket.
    func feed(_ data: Data) { ingest([UInt8](data)) }

    func write(_ data: Data) throws {
        if let hook = writeHook {
            cond.lock(); let dead = closed; cond.unlock()
            if dead { throw LinkError.io("stream closed") }
            try hook(data)
            return
        }
        guard let output else { throw LinkError.io("no output stream") }
        try data.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = output.write(base.advanced(by: sent), maxLength: data.count - sent)
                if n <= 0 { throw LinkError.io("write failed") }
                sent += n
            }
        }
    }

    static func frameLength(_ b: [UInt8]) -> Int? {
        guard b.count >= 1 else { return nil }
        let b0 = b[0]
        if b0 & 0xC0 == Direction.frameData {          // encrypted DATA frame
            guard b.count >= 10 else { return nil }
            return 10 + 16 * (Int(b[9]) + 1)
        }
        guard b.count >= 4 else { return nil }         // plaintext DataX
        let payloadLen = Int(b0 & 0x3F) << 8 | Int(b[1])
        return 4 + payloadLen
    }

    /// Convenience for tests and for callers that already hold a `Data`.
    static func frameLength(_ b: Data) -> Int? {
        frameLength([UInt8](b))
    }

    func nextFrame(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while frames.isEmpty {
            if closed {
                let why = lastError.map { ": \\($0)" } ?? ""
                throw LinkError.io("stream closed\\(why)")
            }
            if !cond.wait(until: deadline) {
                throw LinkError.unexpected("timeout waiting for a frame (folded? out of range?)")
            }
        }
        return frames.removeFirst()
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
        input?.close()
        output?.close()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode == .errorOccurred {
            cond.lock()
            closed = true
            lastError = aStream.streamError
            cond.broadcast()
            cond.unlock()
        }
    }

    /// Bytes still waiting to be framed, plus whole frames not yet consumed by tests.
    var debugBufferCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return buf.count + frames.reduce(0) { $0 + $1.count }
    }
}

'''

s = s[:start] + new + s[end:]
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("rewrote SDUStream:", end - start, "->", len(new))
