import Foundation
import Combine

/// The log used to live inside `Glasses`, which meant every line invalidated every view that
/// observed the model — with a BLE read thread writing dozens of lines per second, the whole
/// UI re-diffed four times a second and buttons felt sticky. Now the log is its own object:
/// only the diagnostics screen subscribes to it.
///
/// Delegate and transport threads append in memory. A batch writes on the file queue, and a
/// separate main-queue update coalesces changes for the diagnostics screen. Neither runs idle.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// Newest first — the UI reads top-down like a chat, which is what people expect.
    @Published private(set) var lines: [String] = []

    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "glasseslink.logs", qos: .utility)
    private var ring: [String] = []
    private var pending: [String] = []
    private var skipped = 0
    private var writeScheduled = false
    private var publishScheduled = false
    // Owned by fileQueue.
    private var fileURL: URL?
    private var handle: FileHandle?
    private let capacity = 400
    private let pendingCapacity = 1024
    private static let maxMessageBytes = 4096
    private static let batchDelay: DispatchTimeInterval = .milliseconds(250)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func ts() -> String { stamp.string(from: Date()) }

    func start(fileURL: URL) {
        fileQueue.async { [weak self] in
            guard let self, self.fileURL == nil else { return }
            self.fileURL = fileURL
            self.writePending()
        }
    }

    func append(_ message: String) {
        let text = message.utf8.count <= Self.maxMessageBytes ? message
            : String(decoding: message.utf8.prefix(Self.maxMessageBytes), as: UTF8.self) + " …"
        let line = "\(Self.ts()) \(text)"
        lock.lock()
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        pending.append(line)
        if pending.count > pendingCapacity {
            let excess = pending.count - pendingCapacity
            pending.removeFirst(excess)
            skipped += excess
        }
        let needsWrite = !writeScheduled
        let needsPublish = !publishScheduled
        writeScheduled = true
        publishScheduled = true
        lock.unlock()

        if needsWrite {
            fileQueue.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.writeScheduled = false
                self.lock.unlock()
                self.writePending()
            }
        }
        if needsPublish {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
                self?.publish()
            }
        }
    }

    /// A barrier for an explicit export or application lifecycle checkpoint.
    func flushToDisk() { fileQueue.sync { writePending() } }

    /// Oldest → newest, for diagnostic bundles.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    func clear() {
        lock.lock()
        ring.removeAll()
        lock.unlock()
        if Thread.isMainThread { publish(resetSchedule: false) }
        else { DispatchQueue.main.async { [weak self] in self?.publish(resetSchedule: false) } }
    }

    private func publish(resetSchedule: Bool = true) {
        lock.lock()
        if resetSchedule { publishScheduled = false }
        let copy = Array(ring.reversed())
        lock.unlock()
        if lines != copy { lines = copy }
    }

    private func writePending() {
        guard let output = fileHandle() else { return }
        lock.lock()
        var batch = pending
        let missed = skipped
        pending = []
        skipped = 0
        lock.unlock()
        let lineCount = batch.count
        if missed > 0 { batch.insert("\(Self.ts()) [log] \(missed) lines were not written", at: 0) }
        guard !batch.isEmpty else { return }
        do {
            try output.write(contentsOf: Data((batch.joined(separator: "\n") + "\n").utf8))
        } catch {
            // Keep the current in-memory snapshot and report the disk gap on the next successful batch.
            try? output.close()
            handle = nil
            lock.lock()
            skipped += missed + lineCount
            lock.unlock()
        }
    }

    /// Keeps the newest part once the file passes `limit`; it used to grow for ever (2.2 MB in a few days).
    static func trimIfLarge(_ url: URL, limit: Int = 2_000_000, keep: Int = 1_000_000) {
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue,
              size > limit, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(size - keep))) != nil,
              let read = try? handle.readToEnd() else { return }
        // Start at a whole line.
        var tail = Data(read)
        if let newline = tail.firstIndex(of: 0x0A) { tail = Data(tail[tail.index(after: newline)...]) }
        try? tail.write(to: url, options: .atomic)
    }

    private func fileHandle() -> FileHandle? {
        if let handle { return handle }
        guard let fileURL else { return nil }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        Self.trimIfLarge(fileURL)
        guard let output = try? FileHandle(forWritingTo: fileURL) else { return nil }
        do {
            try output.seekToEnd()
            handle = output
            return output
        } catch {
            try? output.close()
            return nil
        }
    }
}
