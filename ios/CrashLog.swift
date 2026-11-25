import Foundation
import Darwin

/// Writes a one-line reason plus a backtrace to `Documents/crash.log` before the process dies.
///
/// We cannot symbolicate on device, but `backtrace_symbols_fd` gives us the binary name and
/// offsets, which is enough to tell "it died inside AirShield.open" apart from "it died in
/// SwiftUI". The next launch folds the file into the normal log, so a single crash report
/// travels with the diagnostics bundle the user copies.
enum CrashLog {
    static let fileName = "crash.log"

    static var path: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(fileName).path
    }

    private static var fd: Int32 = -1
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }

        NSSetUncaughtExceptionHandler { ex in
            let what = "\(ex.name.rawValue): \(ex.reason ?? "-")"
            CrashLog.write("--- EXCEPTION \(what) ---\n")
            CrashLog.writeFrames()
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
            signal(sig) { s in
                CrashLog.write("--- CRASH signal \(s) ---\n")
                CrashLog.writeFrames()
                // Put the default handler back and re-raise so the system still produces its
                // own report (and so we do not spin here if the fault repeats).
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// The previous crash, if any, then clears the file so it is not reported twice.
    ///
    /// The report is stamped with the moment it was written and the build that wrote it: without
    /// that, a replay of an old crash looks exactly like a fresh one, and time gets spent on a
    /// bug that a newer build already fixed.
    static func takePrevious() -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let when = (attrs?[.modificationDate] as? Date) ?? Date()
        let stamp = ISO8601DateFormatter().string(from: when)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        try? FileManager.default.removeItem(atPath: path)
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return "recorded \(stamp) by build \(version) (\(build))\n" + trimmed
    }

    // MARK: - async-signal-safe-ish writing

    private static func write(_ s: String) {
        guard fd >= 0 else { return }
        s.withCString { p in
            _ = Darwin.write(fd, p, strlen(p))
        }
    }

    private static func writeFrames() {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, Int32(frames.count))
        if n > 0 {
            backtrace_symbols_fd(&frames, n, fd)
        }
        write("--- end ---\n")
    }
}
