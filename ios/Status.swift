import Foundation

/// svc28, smartglasses_appmanager: the glasses push their own device state here.
/// One subscription and the opening snapshot carries battery, storage, volume, thermal and mount.
enum Status {
    static let service = 28
    static let mtInit: UInt16 = 1000
    static let mtInitAck = 1001
    static let mtDeviceStateStart = 2005
    static let subscriptionDeviceState: UInt64 = 1
    static let photoStarted = 1
    static let videoStarted = 2

    /// Types that carry a DeviceState (the snapshot 2005 and the per-field pushes after it).
    static func isStateType(_ type: Int) -> Bool { (2005 ... 2044).contains(type) && type != 2038 }

    static func cameraCode(_ payload: Data) -> Int? {
        guard let fields = try? PB.parse(payload) else { return nil }
        return fields[3]?.first as? Int
    }

    static func subscribePayload() -> Data {
        // Field 1 is written as a length-delimited blob holding the varint, which is what the glasses accept.
        PB.bytes(1, PB.varint(subscriptionDeviceState)) + PB.string(2, UUID().uuidString)
    }

    static func merge(_ payload: Data, into state: inout GlassesState) {
        guard let top = try? PB.parse(payload) else { return }
        func inner(_ field: Int) -> [Int: [Any]]? {
            guard let blob = top[field]?.first as? Data else { return nil }
            return try? PB.parse(blob)
        }
        func number(_ f: [Int: [Any]]?, _ field: Int) -> Int? { f?[field]?.first as? Int }

        if let battery = inner(1) {
            if let percent = number(battery, 3) {
                state.batteryPercent = (0 ... 100).contains(percent) ? percent : nil
            }
            if let charge = number(battery, 2) { state.charging = [1, 2, 3].contains(charge) }
            if let milli = number(battery, 4) { state.batteryTempC = Double(milli) / 1000 }
            if let milli = number(battery, 5) { state.volts = Double(milli) / 1000 }
        }
        if let value = number(top, 3) { state.camera = cameraName(value) }
        if let value = number(top, 6) { state.hinge = value == 1 ? "OPEN" : "CLOSED" }
        if let value = number(top, 9) { state.mount = value == 1 ? "DON" : "DOFF" }
        if let thermal = inner(13) {
            if let celsius = number(thermal, 2) { state.thermalC = celsius }
            if let throttling = number(thermal, 3) { state.throttling = throttling != 0 }
        }
        if let streaming = number(top, 17) { state.streaming = streaming != 0 }
        if let storage = inner(21) {
            if let free = number(storage, 1) { state.storageFreeMb = free >= 0 ? free : nil }
            if let total = number(storage, 2) { state.storageTotalMb = total > 0 ? total : nil }
            if let free = state.storageFreeMb, let total = state.storageTotalMb, free > total {
                state.storageFreeMb = nil
            }
        }
        if let volume = inner(25) {
            state.receivedVolume = true
            // The glasses may report UINT32_MAX for a volume that is unavailable.
            let percent = number(volume, 3)
            state.volumePercent = percent.flatMap { (0 ... 100).contains($0) ? $0 : nil }
            state.volumeLevel = number(volume, 1)
            state.volumeStream = number(volume, 2).map(streamName)
        }
    }

    static func cameraName(_ value: Int) -> String {
        switch value {
        case 0: return "空闲"
        case photoStarted: return "拍照中"
        case videoStarted: return "录像中"
        case 3: return "拍摄完成"
        case 4, 6: return "拍摄失败"
        case 5, 10: return "就绪"
        case 7 ... 9: return "取景中"
        default: return "STATE \(value)"
        }
    }

    static func streamName(_ value: Int) -> String {
        switch value {
        case 0: return "UNKNOWN"
        case 1: return "MEDIA"
        case 2: return "TELEPHONY"
        case 3: return "CURRENT"
        default: return "STREAM \(value)"
        }
    }
}

struct GlassesState {
    var batteryPercent: Int?
    var charging: Bool?
    var batteryTempC: Double?
    var volts: Double?
    var camera: String?
    var hinge: String?
    var mount: String?
    var thermalC: Int?
    var throttling: Bool?
    var streaming: Bool?
    var storageFreeMb: Int?
    var storageTotalMb: Int?
    var volumePercent: Int?
    var volumeLevel: Int?
    var volumeStream: String?
    var receivedVolume = false

    var hasReportedState: Bool {
        batteryPercent != nil || charging != nil || batteryTempC != nil || volts != nil
            || camera != nil || hinge != nil || mount != nil || thermalC != nil || throttling != nil
            || streaming != nil || storageFreeMb != nil || storageTotalMb != nil || receivedVolume
    }

    mutating func mergeReported(from update: GlassesState) {
        batteryPercent = update.batteryPercent ?? batteryPercent
        charging = update.charging ?? charging
        batteryTempC = update.batteryTempC ?? batteryTempC
        volts = update.volts ?? volts
        camera = update.camera ?? camera
        hinge = update.hinge ?? hinge
        mount = update.mount ?? mount
        thermalC = update.thermalC ?? thermalC
        throttling = update.throttling ?? throttling
        streaming = update.streaming ?? streaming
        storageFreeMb = update.storageFreeMb ?? storageFreeMb
        storageTotalMb = update.storageTotalMb ?? storageTotalMb
        if let free = storageFreeMb, let total = storageTotalMb, free > total {
            // Do not pair a fresh reading with an older, conflicting one.
            if update.storageTotalMb != nil { storageFreeMb = nil }
            else { storageTotalMb = nil }
        }
        if update.receivedVolume {
            volumePercent = update.volumePercent
            volumeLevel = update.volumeLevel
            volumeStream = update.volumeStream
            receivedVolume = true
        }
    }

    var lines: [String] {
        var out: [String] = []
        if let batteryPercent {
            let charge = charging == true ? "（充电中）" : ""
            out.append("电量 \(batteryPercent)%\(charge)")
        }
        if let volts { out.append(String(format: "电压 %.3f V", volts)) }
        if let batteryTempC { out.append(String(format: "电池温度 %.1f °C", batteryTempC)) }
        if let storageFreeMb, let storageTotalMb {
            out.append("空间 \(gb(storageFreeMb)) 可用 / \(gb(storageTotalMb))")
        }
        if let volumePercent {
            let level = volumeLevel.map { "（level \($0)）" } ?? ""
            let stream = volumeStream.map { " · \($0)" } ?? ""
            out.append("音量 \(volumePercent)%\(level)\(stream)")
        }
        if let thermalC {
            let note = throttling == true ? "（限速中）" : ""
            out.append("机内温度 \(thermalC) °C\(note)")
        }
        if let mount { out.append(mount == "DON" ? "已戴上" : "未戴上") }
        if let hinge { out.append("镜腿 \(hinge)") }
        if let camera { out.append("相机 \(camera)") }
        if streaming == true { out.append("正在串流") }
        return out
    }

    private func gb(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
