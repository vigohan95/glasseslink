import CryptoKit
import Foundation
import Network

struct MediaWiFiEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    let address: String
    let port: UInt16
    let ssid: String
    let password: String

    var description: String { "MediaWiFiEndpoint" }
    var debugDescription: String { description }
}

enum MediaWiFiProtocol {
    static let service = 10
    static let channelName = "media-wifi-atc"
    static let create: UInt16 = 0x1000
    static let info: UInt16 = 0x1001
    static let destroy: UInt16 = 0x1002

    // Visor v3.1.0, core/media/Wifi.kt: ATC's SoftAP control messages and TCP listener.
    private static let listenerPort: UInt16 = 20203

    static func makeRequest(countryCode: String, id: UUID, ssid: String, password: String) throws -> Data {
        guard countryCode.utf8.count == 2,
              countryCode.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LinkError.unexpected("未能确定眼镜热点的 Wi-Fi 国家或地区")
        }
        var requestID = id.uuid
        let idBytes = withUnsafeBytes(of: &requestID) { Data($0) }
        let credentials = PB.string(1, ssid) + PB.string(2, password)
        return PB.uint(3, 1) + PB.uint(4, 6) + PB.string(6, countryCode.uppercased()) + PB.bytes(7, idBytes)
            + PB.bytes(8, credentials) + PB.uint(9, 1)
    }

    static func parseInfo(_ payload: Data, requestedSSID: String, requestedPassword: String) throws -> MediaWiFiEndpoint {
        let fields = try PB.parse(payload)
        guard let status = fields[1]?.first as? Int else {
            throw LinkError.unexpected("眼镜热点响应缺少状态")
        }
        guard status == 1 else {
            throw LinkError.unexpected("眼镜创建 Wi-Fi 热点失败（状态 \(status)）")
        }

        var address: String?
        for entry in fields[2] ?? [] {
            guard let body = entry as? Data,
                  let encoded = try PB.parse(body)[3]?.first as? Data,
                  let reported = String(data: encoded, encoding: .utf8) else { continue }
            let host = String(reported.prefix(while: { $0 != "/" }))
            if IPv4Address(host) != nil || IPv6Address(host) != nil {
                address = host
                break
            }
        }
        guard let address else {
            throw LinkError.unexpected("眼镜热点响应缺少可用的 IP 地址")
        }

        let port: UInt16
        if let value = fields[4]?.first {
            guard let reported = value as? Int, let numeric = UInt16(exactly: reported) else {
                throw LinkError.unexpected("眼镜热点响应的 TCP 端口无效")
            }
            port = numeric == 0 ? listenerPort : numeric
        } else {
            port = listenerPort
        }

        var credentials: [Int: [Any]] = [:]
        if let entry = fields[3]?.first {
            guard let body = entry as? Data else { throw LinkError.unexpected("眼镜热点响应的凭据无效") }
            credentials = try PB.parse(body)
        }
        let ssid = try credential(credentials[1]?.first, proposed: requestedSSID)
        let password = try credential(credentials[2]?.first, proposed: requestedPassword)
        guard (1...32).contains(ssid.utf8.count), !ssid.utf8.contains(0),
              (8...63).contains(password.utf8.count),
              password.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw LinkError.unexpected("眼镜热点响应的凭据无效")
        }
        return MediaWiFiEndpoint(address: address, port: port, ssid: ssid, password: password)
    }

    private static func credential(_ value: Any?, proposed: String) throws -> String {
        guard let value else { return proposed }
        guard let bytes = value as? Data, let text = String(data: bytes, encoding: .utf8) else {
            throw LinkError.unexpected("眼镜热点响应的凭据无效")
        }
        return text.isEmpty ? proposed : text
    }
}

extension Session {
    /// The caller owns the Bluetooth link while negotiating and until the TCP session takes over.
    func createMediaSoftAP(countryCode: String, timeout: TimeInterval = 30) throws -> MediaWiFiEndpoint {
        guard hasVerifiedOwner else { throw LinkError.unexpected("开启眼镜热点前需要验证眼镜主人身份") }
        let id = UUID()
        let ssid = "GlassesLink-\(id.uuidString.prefix(8))"
        let password = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0).hex }
        let payload = try MediaWiFiProtocol.makeRequest(countryCode: countryCode, id: id, ssid: ssid, password: password)
        let service = MediaWiFiProtocol.service
        let name = MediaWiFiProtocol.channelName
        let mirror = serviceChannel(name, service: service) ^ 0x8000
        try sendOnService(name, service: service, type: MediaWiFiProtocol.create, payload: payload, tracePayload: false)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LinkError.unexpected("眼镜未返回 Wi-Fi 热点信息") }
            let message = try nextMessage(timeout: remaining, tracePayload: false)
            guard message.channel == mirror, message.service == nil || message.service == service else { continue }
            if let error = message.error, error != Int(AirShield.stOK), error != Int(AirShield.stSuccess) {
                throw LinkError.serviceError("创建眼镜热点", UInt16(truncatingIfNeeded: error))
            }
            guard message.type == Int(MediaWiFiProtocol.info) else { continue }
            return try MediaWiFiProtocol.parseInfo(message.payload, requestedSSID: ssid, requestedPassword: password)
        }
    }

    func destroyMediaSoftAP() throws {
        guard hasVerifiedOwner else { throw LinkError.unexpected("关闭眼镜热点前需要验证眼镜主人身份") }
        try sendOnService(MediaWiFiProtocol.channelName, service: MediaWiFiProtocol.service,
                          type: MediaWiFiProtocol.destroy, tracePayload: false)
    }
}
