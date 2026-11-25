import CryptoKit
import Foundation

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
