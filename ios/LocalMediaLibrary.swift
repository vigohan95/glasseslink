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
        try data.write(to: root.appendingPathComponent(fileName), options: .atomic)
        return Item(capture: capture, fileName: fileName)
    }
}
