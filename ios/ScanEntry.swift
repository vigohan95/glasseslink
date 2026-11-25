import Foundation

struct ScanEntry: Identifiable, Equatable {
    enum Source: Int {
        case systemConnected
        case previouslySelected
        case advertisement
    }

    let id: UUID
    let peripheralName: String?
    let verifiedName: String?
    let advertisementName: String?
    let rssi: Int
    let isGlasses: Bool
    let isVerified: Bool
    let source: Source

    init(id: UUID, peripheralName: String? = nil, verifiedName: String? = nil, advertisementName: String? = nil,
         rssi: Int, isGlasses: Bool, isVerified: Bool = false, source: Source = .advertisement) {
        self.id = id
        self.peripheralName = Self.usableName(peripheralName)
        self.verifiedName = isVerified ? Self.usableName(verifiedName) : nil
        self.advertisementName = Self.usableName(advertisementName)
        self.rssi = rssi
        self.isGlasses = isGlasses
        self.isVerified = isVerified
        self.source = source
    }

    static func usableName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?", UUID(uuidString: trimmed) == nil else { return nil }
        return trimmed
    }

    var isVisibleCandidate: Bool { isVerified || isGlasses || source != .advertisement }

    var name: String? { peripheralName ?? verifiedName ?? advertisementName }

    var displayName: String {
        if let name { return name }
        let title = isVerified ? "未命名眼镜" : "未命名设备"
        return "\(title) · \(id.uuidString.suffix(4))"
    }

    var nameSourceLabel: String? {
        if peripheralName != nil { return "蓝牙名称" }
        if verifiedName != nil { return "曾验证时的名称" }
        if advertisementName != nil { return "广播名称" }
        return nil
    }

    var sourceLabel: String {
        if isVerified { return "曾验证的眼镜" }
        switch source {
        case .systemConnected: return "iPhone 蓝牙已连接"
        case .previouslySelected: return "上次选择"
        case .advertisement: return "扫描到的蓝牙候选"
        }
    }

    var signalLabel: String? {
        guard source == .advertisement, (-127 ... -1).contains(rssi) else { return nil }
        if rssi >= -60 { return "信号较强" }
        if rssi >= -80 { return "信号中等" }
        return "信号较弱"
    }

    func isListedBefore(_ other: ScanEntry) -> Bool {
        if isVerified != other.isVerified { return isVerified }
        if source != other.source { return source.rawValue < other.source.rawValue }
        let nameOrder = displayName.localizedStandardCompare(other.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return id.uuidString < other.id.uuidString
    }
}
