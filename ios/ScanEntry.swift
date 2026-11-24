import Foundation

/// One row in the "nearby devices" list. The glasses must stay distinguishable from the
/// dozens of car keys and printers that show up in a busy room.
struct ScanEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isGlasses: Bool
}
