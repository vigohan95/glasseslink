import Foundation

/// `settings.tsv`: one row per setting — the svc31 field number, its kind, the firmware default,
/// the RLDrive namespace, and whether this firmware actually parses the svc31 field.
///
/// A setting with a field is written over svc31 (write-only, ack is always SUCCESS).
/// One without, or one this firmware drops, is written into RLDrive instead.
struct SettingSchema {
    let key: String
    let field: Int?
    let kind: String            // bool / int / str / float / other
    let defaultValue: String?
    let namespace: String
    let parsed: Bool

    /// svc31: no field, or one the firmware acks and drops.
    var viaDrive: Bool { field == nil || !parsed }
    var writable: Bool { ["bool", "int", "str", "float"].contains(kind) && key != "sg_disable_thermal_shutdown" }
}

enum SettingsSchemaTable {
    static let all: [String: SettingSchema] = {
        guard let url = Bundle.main.url(forResource: "settings", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }()

    static func parse(_ text: String) -> [String: SettingSchema] {
        var out: [String: SettingSchema] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 6, !c[0].isEmpty else { continue }
            out[c[0]] = SettingSchema(key: c[0],
                                      field: Int(c[1]),
                                      kind: c[2],
                                      defaultValue: c[4].isEmpty ? nil : c[3],
                                      namespace: c[4].isEmpty ? "individual_device_settings" : c[4],
                                      parsed: c[5] == "1")
        }
        return out
    }

    static func schema(_ key: String) -> SettingSchema? { all[key] }

    /// RLDrive keeps every value as text, so "1" and "true", or "90" and "90.0", are the same setting.
    static func same(kind: String?, _ have: String?, _ want: String) -> Bool {
        guard let have else { return false }
        let stored = have.trimmingCharacters(in: .whitespaces)
        let wanted = want.trimmingCharacters(in: .whitespaces)
        switch kind {
        case "bool":
            guard let a = boolValue(stored), let b = boolValue(wanted) else { return stored == wanted }
            return a == b
        case "int", "float":
            guard let a = Double(stored), let b = Double(wanted) else { return stored == wanted }
            return abs(a - b) < 1e-6
        default:
            return stored == wanted
        }
    }

    static func boolValue(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "on", "yes": return true
        case "false", "0", "off", "no": return false
        default: return nil
        }
    }
}
