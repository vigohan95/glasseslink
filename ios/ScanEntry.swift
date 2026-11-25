import Foundation

struct ScanEntry: Identifiable, Equatable {
    enum Source: Int {
        case systemConnected
        case previouslySelected
        case advertisement
    }

    let id: UUID
    let name: String
    let rssi: Int
    let isGlasses: Bool
    let source: Source

    init(id: UUID, name: String, rssi: Int, isGlasses: Bool, source: Source = .advertisement) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.isGlasses = isGlasses
        self.source = source
    }

    var isVisibleCandidate: Bool { isGlasses || source != .advertisement }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "?", UUID(uuidString: trimmed) == nil { return trimmed }
        let title = isGlasses ? "未命名眼镜" : "未命名设备"
        return "\(title) · \(id.uuidString.suffix(4))"
    }

    var sourceLabel: String {
        switch source {
        case .systemConnected: return "iPhone 蓝牙已连接"
        case .previouslySelected: return "上次选择"
        case .advertisement: return "扫描到的眼镜候选"
        }
    }

    var signalLabel: String? {
        guard source == .advertisement, (-127 ... -1).contains(rssi) else { return nil }
        if rssi >= -60 { return "信号较强" }
        if rssi >= -80 { return "信号中等" }
        return "信号较弱"
    }

    func isListedBefore(_ other: ScanEntry) -> Bool {
        if source != other.source { return source.rawValue < other.source.rawValue }
        let nameOrder = displayName.localizedStandardCompare(other.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return id.uuidString < other.id.uuidString
    }
}
