import Foundation

/// One row in the "nearby devices" list. The glasses must stay distinguishable from the
/// dozens of car keys and printers that show up in a busy room.
struct ScanEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isGlasses: Bool

    /// Bluetooth devices without a local name arrive as an empty string, and iOS then shows us
    /// a bare UUID. Neither is something a person should have to read.
    var displayName: String {
        if isGlasses { return name.isEmpty ? "Meta 眼镜" : name }
        if name.isEmpty { return "未命名设备" }
        // A 36-character UUID is noise; keep the last four characters so rows stay distinguishable.
        if name.count >= 32, name.contains("-") { return "未命名设备 · " + String(name.suffix(4)) }
        return name
    }
}
