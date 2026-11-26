import CryptoKit
import Foundation

/// The names people see: in iPhone Photos, when sharing, and on the viewer. Stored originals keep their
/// hashed names, so the index of what was already imported does not change.
enum MediaNaming {
    static func captureDate(_ timestampNS: Int?) -> Date? {
        guard let ns = timestampNS, ns > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ns) / 1_000_000_000)
    }

    /// "眼镜照片_2026-11-26_15-57-02": sorts by time in any file list and says what it is.
    static func baseName(isPhoto: Bool, timestampNS: Int?, fallback: Date = Date(),
                         timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: captureDate(timestampNS) ?? fallback)
        return (isPhoto ? "眼镜照片_" : "眼镜视频_") + stamp
    }

    static func fileName(isPhoto: Bool, timestampNS: Int?, fileExtension: String,
                         timeZone: TimeZone = .current) -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let base = baseName(isPhoto: isPhoto, timestampNS: timestampNS, timeZone: timeZone)
        return ext.isEmpty ? base : base + "." + ext
    }

    /// The viewer's title: "照片 · 11月26日 15:57:02".
    static func title(isPhoto: Bool, timestampNS: Int?, timeZone: TimeZone = .current) -> String {
        let kind = isPhoto ? "照片" : "视频"
        guard let date = captureDate(timestampNS) else { return kind }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        formatter.dateFormat = sameYear ? "M月d日 HH:mm:ss" : "yyyy年M月d日 HH:mm:ss"
        return "\(kind) · \(formatter.string(from: date))"
    }

    /// A copy under the readable name for the share sheet; the stored original is left alone.
    static func shareableCopy(of original: URL, isPhoto: Bool, timestampNS: Int?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(isPhoto: isPhoto, timestampNS: timestampNS, fileExtension: original.pathExtension)
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }
}

enum LocalMediaLibrary {
    struct Item: Codable {
        let capture: Capture
        let fileName: String
    }

    private static var originals: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OriginalMedia", isDirectory: true)
    }

    static func load() -> [String: Item] {
        guard let data = UserDefaults.standard.data(forKey: "localMediaRecords"),
              let index = try? JSONDecoder().decode([String: Item].self, from: data) else { return [:] }
        return index.filter { url(for: $0.value) != nil }
    }

    static func saveIndex(_ index: [String: Item]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        UserDefaults.standard.set(data, forKey: "localMediaRecords")
    }

    static func url(for item: Item) -> URL? {
        guard let root = originals, item.fileName == URL(fileURLWithPath: item.fileName).lastPathComponent else { return nil }
        let path = root.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    static func store(_ data: Data, capture: Capture, originalName: String) throws -> Item {
        let destination = try destination(for: capture, originalName: originalName)
        try data.write(to: destination.url, options: .atomic)
        return destination.item
    }

    /// Publish a verified source file without allocating another in-memory copy. The caller
    /// retains the staged source until any separate Photos export has finished.
    static func storeFile(_ source: URL, capture: Capture, originalName: String) throws -> Item {
        let destination = try destination(for: capture, originalName: originalName)
        let files = FileManager.default
        let pending = destination.url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: pending) }
        try files.copyItem(at: source, to: pending)
        if files.fileExists(atPath: destination.url.path) {
            _ = try files.replaceItemAt(destination.url, withItemAt: pending)
        } else {
            try files.moveItem(at: pending, to: destination.url)
        }
        return destination.item
    }

    private static func destination(for capture: Capture, originalName: String) throws -> (item: Item, url: URL) {
        guard var root = originals else { throw LinkError.io("无法打开 App 的媒体目录。") }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var protection = URLResourceValues()
            protection.isExcludedFromBackup = true
            try? root.setResourceValues(protection)
        }
        let suffix = URL(fileURLWithPath: originalName).pathExtension.lowercased()
        let allowed = capture.isPhoto ? ["heic", "heif", "jpg", "jpeg", "png"] : ["mp4", "mov", "m4v"]
        let ext = allowed.contains(suffix) ? suffix : (capture.isPhoto ? "heic" : "mp4")
        let identity = SHA256.hash(data: Data(capture.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let fileName = identity + "." + ext
        return (Item(capture: capture, fileName: fileName), root.appendingPathComponent(fileName))
    }
}
