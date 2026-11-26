import Foundation

/// svc33, RLDrive: the replicated store the glasses keep their settings in.
///
/// One round trip is a SyncMessage: we say which writers and versions we already know, the glasses
/// answer with everything newer, and a write is us presenting a new version of an object as another
/// replica of the namespace would.
enum Drive {
    static let service = 33
    static let syncMessage: UInt16 = 1

    /// Our writer id, shaped like the glasses' own (a uuid). Reads claim it at version 0; writes count it up.
    static let localWriter = "5f1c0de0-7615-4a0e-9d1e-000000000001"

    static let kv = "kv"
    static let syncMetadata = "sync_metadata"
    static let media = "media"

    /// The settings namespace the tables name; on the glasses it is scoped by their device UUID.
    static let deviceSettings = "individual_device_settings"
    static let defaultTypes = [kv, syncMetadata, media]

    /// Visor's GlassesSettings reads these four. The first two live under "<device uuid>@", which is why
    /// reading the bare name found nothing (glasses log 31: "设置：读到 0 项").
    static let scopedSettingsNamespaces = ["individual_device_settings", "individual_device_sensitive_settings"]
    static let deviceSettingsNamespaces = ["local_device_settings", "shared_settings_namespace_1"]

    static func settingsNamespaces(deviceUUID: String?) -> [String] {
        guard let uuid = deviceUUID, !uuid.isEmpty else { return [deviceSettings] + deviceSettingsNamespaces }
        return scopedSettingsNamespaces.map { "\(uuid)@\($0)" } + deviceSettingsNamespaces
    }

    /// Where a write of a setting from `base` goes.
    static func settingsNamespace(_ base: String, deviceUUID: String?) -> String {
        guard let uuid = deviceUUID, !uuid.isEmpty, scopedSettingsNamespaces.contains(base) else { return base }
        return "\(uuid)@\(base)"
    }

    private static let typeSyncMessage: UInt64 = 1
    private static let typeChunked: UInt64 = 5
    private static let apiVersion: UInt64 = 1

    struct Object {
        var uri: String
        var type: String
        var data: String
        var deleted: Bool
        var raw: Data
    }

    struct Reply {
        var namespace: String
        var round: Int
        var terminated: Bool
        var requestID: String
        var types: [String: [String: Int]]
        var objects: [Object]
        var usecaseTag: String
    }

    /// type -> writer -> version, as last seen.
    typealias Versions = [String: [String: Int]]

    /// `round` 0 asks for everything; later rounds answer with what changed since `known`.
    static func build(namespace: String,
                      requestID: String,
                      round: Int,
                      known: Versions = [:],
                      types: [String] = defaultTypes,
                      objects: [Object] = [],
                      terminated: Bool = false,
                      usecaseTag: String = "") -> Data {
        var sync = Data()
        var allTypes = types
        for object in objects where !allTypes.contains(object.type) { allTypes.append(object.type) }
        for type in allTypes {
            let theirs = known[type] ?? [:]
            let base = theirs[localWriter] ?? 0
            let mine = round == 0 ? [] : objects.filter { $0.type == type }
            var writers = theirs
            writers[localWriter] = round == 0 ? 0 : base + mine.count
            var typeData = Data()
            for (writer, version) in writers.sorted(by: { $0.key < $1.key }) {
                typeData += PB.bytes(11, PB.string(1, writer) + PB.uint(2, UInt64(version)))
            }
            typeData += PB.string(12, type)
            for (index, object) in mine.enumerated() {
                var inner = PB.string(1, object.uri) + PB.string(2, object.type) + PB.bytes(3, Data(object.data.utf8))
                if object.deleted { inner += PB.uint(8, 1) }
                let version = PB.string(1, localWriter) + PB.uint(2, UInt64(base + index + 1))
                typeData += PB.bytes(13, PB.bytes(6, inner) + PB.bytes(7, version))
            }
            sync += PB.bytes(16, typeData)
        }
        sync += PB.uint(17, UInt64(round))
        sync += PB.string(18, requestID)
        sync += PB.uint(19, apiVersion)
        sync += PB.string(20, namespace)
        sync += PB.string(21, localWriter)
        if terminated { sync += PB.uint(22, 1) }
        if !usecaseTag.isEmpty { sync += PB.string(31, usecaseTag) }
        return PB.uint(1, typeSyncMessage) + PB.bytes(2, sync) + PB.string(6, namespace)
    }

    static func decode(_ payload: Data) -> Reply? {
        guard let outer = try? PB.parse(payload) else { return nil }
        guard let syncBlob = outer[2]?.first as? Data, let sync = try? PB.parse(syncBlob) else { return nil }
        func text(_ value: Any?) -> String {
            guard let data = value as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        func number(_ value: Any?) -> Int { (value as? Int) ?? 0 }
        var types: [String: [String: Int]] = [:]
        var objects: [Object] = []
        for blob in (sync[16] ?? []).compactMap({ $0 as? Data }) {
            guard let typeData = try? PB.parse(blob) else { continue }
            let type = text(typeData[12]?.first)
            var versions: [String: Int] = [:]
            for entry in (typeData[11] ?? []).compactMap({ $0 as? Data }) {
                guard let parsed = try? PB.parse(entry) else { continue }
                versions[text(parsed[1]?.first)] = number(parsed[2]?.first)
            }
            types[type] = versions
            for internalBlob in (typeData[13] ?? []).compactMap({ $0 as? Data }) {
                guard let wrapper = try? PB.parse(internalBlob),
                      let objectBlob = wrapper[6]?.first as? Data,
                      let object = try? PB.parse(objectBlob),
                      object[1]?.first != nil else { continue }
                objects.append(Object(uri: text(object[1]?.first),
                                      type: text(object[2]?.first),
                                      data: text(object[3]?.first),
                                      deleted: number(object[8]?.first) != 0,
                                      raw: internalBlob))
            }
        }
        return Reply(namespace: text(outer[6]?.first).isEmpty ? text(sync[20]?.first) : text(outer[6]?.first),
                     round: number(sync[17]?.first),
                     terminated: number(sync[22]?.first) != 0,
                     requestID: text(sync[18]?.first),
                     types: types,
                     objects: objects,
                     usecaseTag: text(sync[31]?.first))
    }

    /// A reply over about a kilobyte arrives as CHUNKED_SYNC_MESSAGE slices tied by field 5,
    /// counted in 7 and 8. Each whole message is handed back once its last slice lands.
    final class Assembler {
        private var parts: [String: [Int: Data]] = [:]

        func add(_ payload: Data) -> Data? {
            guard let fields = try? PB.parse(payload) else { return nil }
            let total = (fields[7]?.first as? Int) ?? 0
            guard (fields[1]?.first as? Int) == Int(typeChunked), total > 1 else { return payload }
            let id = String(data: (fields[5]?.first as? Data) ?? Data(), encoding: .utf8) ?? ""
            var chunks = parts[id] ?? [:]
            chunks[(fields[8]?.first as? Int) ?? 0] = (fields[2]?.first as? Data) ?? Data()
            if chunks.count < total {
                parts[id] = chunks
                return nil
            }
            parts[id] = nil
            let whole = chunks.keys.sorted().reduce(Data()) { $0 + (chunks[$1] ?? Data()) }
            return PB.uint(1, typeSyncMessage) + PB.bytes(2, whole) + PB.bytes(6, (fields[6]?.first as? Data) ?? Data())
        }
    }
}

extension PB {
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
}
