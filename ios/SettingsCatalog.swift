import Foundation

/// One row of `settings_ui.json`, the catalogue Visor ships: what each setting is called,
/// which group it sits in, and the control the glasses expect for it.
struct SettingInfo: Decodable, Identifiable {
    struct Option: Decodable, Identifiable {
        let value: String
        let label: String
        let labelZH: String?
        var id: String { value }
        var display: String { labelZH ?? label }
    }

    struct Control: Decodable {
        let type: String
        let min: Double?
        let max: Double?
        let step: Double?
        let unit: String?
        let options: [Option]?
        /// `text` uses `max` as a length budget, not as a range.
        var maxLength: Int? { max.map { Int($0) } }
    }

    let key: String
    let label: String
    let labelZH: String?
    let noteZH: String?
    let note: String?
    let group: String
    let control: Control

    var id: String { key }
    var name: String { labelZH ?? label }
    var detail: String? { noteZH ?? note }
    var isWritable: Bool { ["toggle", "choice", "range", "text"].contains(control.type) }

    enum CodingKeys: String, CodingKey {
        case key, label, group, control, note
        case labelZH = "label_zh"
        case noteZH = "note_zh"
    }
}

enum SettingsCatalog {
    /// Loaded once; an empty list means the bundle lost its resource.
    static let all: [SettingInfo] = {
        guard let url = Bundle.main.url(forResource: "settings_ui", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SettingInfo].self, from: data) else { return [] }
        return list
    }()

    static let groups: [String] = {
        var seen: [String] = []
        for info in all where !seen.contains(info.group) { seen.append(info.group) }
        return seen
    }()

    static func inGroup(_ group: String) -> [SettingInfo] { all.filter { $0.group == group } }
    static func info(_ key: String) -> SettingInfo? { all.first { $0.key == key } }

    /// How an arbitrary stored string should be shown next to a setting.
    static func shown(_ info: SettingInfo, _ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        switch info.control.type {
        case "choice":
            return info.control.options?.first { $0.value == raw }?.display ?? raw
        case "toggle":
            return raw == "true" ? "开" : "关"
        default:
            return raw
        }
    }
}
