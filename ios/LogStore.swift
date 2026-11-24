import Foundation
import Combine

/// The log used to live inside `Glasses`, which meant every line invalidated every view that
/// observed the model — with a BLE read thread writing dozens of lines per second, the whole
/// UI re-diffed four times a second and buttons felt sticky. Now the log is its own object:
/// only the diagnostics screen subscribes to it.
///
/// Writers are not all on the main thread (BLE callbacks, session read loop), so `append` takes
/// a lock and only the 4 Hz flush touches the published array.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// Newest first — the UI reads top-down like a chat, which is what people expect.
    @Published private(set) var lines: [String] = []

    private let lock = NSLock()
    private var ring: [String] = []
    private var pending: [String] = []
    private var timer: Timer?
    private var handle: FileHandle?
    private let capacity = 400

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func ts() -> String { stamp.string(from: Date()) }

    func start(fileURL: URL) {
        lock.lock()
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
        }
        lock.unlock()
        guard timer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func append(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)"
        lock.lock()
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        pending.append(line)
        if let d = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: d) }
        lock.unlock()
        print(line)
    }

    /// Oldest → newest, for diagnostic bundles.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    func clear() {
        lock.lock()
        ring.removeAll()
        pending.removeAll()
        lock.unlock()
        lines = []
    }

    private func flush() {
        lock.lock()
        let fresh = !pending.isEmpty
        pending.removeAll(keepingCapacity: true)
        let copy = Array(ring.reversed())
        lock.unlock()
        guard fresh else { return }
        lines = copy
    }
}
