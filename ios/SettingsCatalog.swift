import Foundation

/// One row of `settings_ui.json`, the catalogue Visor ships: what each setting is called,
/// which group it sits in, and the control the glasses expect for it.
struct SettingInfo: Decodable, Identifiable {
    struct Option: Decodable, Identifiable {
        let value: String
        let label: String
        let labelZH: String?
        let hidden: Bool?
        let products: [Int]?
        let notProducts: [Int]?
        var id: String { value }
        var display: String { labelZH ?? label }
        var offeredOnGen2: Bool {
            hidden != true && SettingInfo.offered(products, notProducts, on: SettingInfo.rayBanMetaGen2)
        }

        enum CodingKeys: String, CodingKey {
            case value, label, hidden, products
            case labelZH = "label_zh"
            case notProducts = "not_products"
        }
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
    let products: [Int]?
    let notProducts: [Int]?

    /// The Meta app's product id for Ray-Ban Meta (Gen 2) (Visor's DeviceInfo.kt).
    static let rayBanMetaGen2 = 266

    static func offered(_ only: [Int]?, _ not: [Int]?, on product: Int) -> Bool {
        !(not ?? []).contains(product) && (only.map { $0.contains(product) } ?? true)
    }

    var offeredOnGen2: Bool {
        Self.offered(products, notProducts, on: Self.rayBanMetaGen2)
            && !SettingsCatalog.otherModelGroups.contains(group)
    }

    var id: String { key }
    var name: String { labelZH ?? label }
    var detail: String? { noteZH ?? note }
    var isWritable: Bool { ["toggle", "choice", "range", "text"].contains(control.type) }

    enum CodingKeys: String, CodingKey {
        case key, label, group, control, note, products
        case labelZH = "label_zh"
        case noteZH = "note_zh"
        case notProducts = "not_products"
    }
}

enum SettingsCatalog {
    /// Loaded once; an empty list means the bundle lost its resource.
    static let all: [SettingInfo] = {
        guard let url = Bundle.main.url(forResource: "settings_ui", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }()

    static func decode(_ data: Data) -> [SettingInfo] {
        (try? JSONDecoder().decode([SettingInfo].self, from: data)) ?? []
    }

    static let groups: [String] = {
        var seen: [String] = []
        for info in all where !seen.contains(info.group) { seen.append(info.group) }
        return seen
    }()

    static func inGroup(_ group: String) -> [SettingInfo] { all.filter { $0.group == group } }

    /// Groups the firmware keeps for glasses with a display or the wristband.
    static let otherModelGroups: Set<String> = ["Display", "Neural band gestures"]

    static let groupNamesZH: [String: String] = [
        "Glasses": "眼镜", "Sound": "声音", "Touch and gestures": "触控与手势", "Camera": "相机",
        "Video and live": "视频与直播", "Meta AI": "Meta AI", "Live AI and translation": "Live AI 与翻译",
        "Calls and messages": "通话与消息", "Notifications": "通知", "Music and media": "音乐与媒体",
        "Connectivity": "连接", "Health and fitness": "健康与运动", "Accessibility": "辅助功能",
        "Privacy and data": "隐私与数据", "Updates and system": "更新与系统", "Display": "显示屏",
        "Neural band gestures": "腕带手势", "Developer and tests": "开发与测试",
    ]

    static func groupName(_ group: String) -> String { groupNamesZH[group] ?? group }
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
