import Foundation
import Network
import NetworkExtension

protocol SessionTransport: AnyObject {
    func write(_ data: Data) throws
    func nextFrame(timeout: TimeInterval) throws -> Data
    func close()
}

enum MediaWiFiError: LocalizedError, CustomStringConvertible {
    case invalidHotspot
    case invalidEndpoint
    case automaticJoinUnavailable(systemCode: Int?)
    case hotspotUserDenied
    case hotspotBusy
    case hotspotRequiresForeground
    case hotspotTimeout
    case localNetworkDenied
    case connectionTimeout
    case connectionFailed

    var errorDescription: String? { description }

    var canOfferManualJoin: Bool {
        if case .automaticJoinUnavailable = self { return true }
        return false
    }

    var diagnosticDescription: String {
        if case let .automaticJoinUnavailable(code?) = self {
            return "\(description)（系统热点错误代码 \(code)）"
        }
        return description
    }

    var description: String {
        switch self {
        case .invalidHotspot: return "眼镜返回的 Wi-Fi 热点信息无效。"
        case .invalidEndpoint: return "眼镜返回的 Wi-Fi 地址或端口无效。"
        case .automaticJoinUnavailable: return "iOS 无法自动加入眼镜热点。请检查应用签名或在系统设置中手动加入。"
        case .hotspotUserDenied: return "你已取消加入眼镜热点。"
        case .hotspotBusy: return "iOS 正在处理另一个 Wi-Fi 加入请求。"
        case .hotspotRequiresForeground: return "请在应用前台加入眼镜热点。"
        case .hotspotTimeout: return "加入眼镜 Wi-Fi 热点超时。"
        case .localNetworkDenied: return "请在 iPhone 设置中允许 GlassesLink 访问本地网络。"
        case .connectionTimeout: return "连接眼镜 Wi-Fi 数据通道超时。"
        case .connectionFailed: return "无法连接眼镜 Wi-Fi 数据通道。"
        }
    }

    /// The boolean indicates whether the app owns a configuration to remove on disconnect.
    static func hotspotOutcome(_ error: Error?) -> Result<Bool, MediaWiFiError> {
        guard let error else { return .success(true) }
        let nsError = error as NSError
        guard nsError.domain == NEHotspotConfigurationErrorDomain else {
            return .failure(.automaticJoinUnavailable(systemCode: nil))
        }
        switch NEHotspotConfigurationError(rawValue: nsError.code) {
        case .alreadyAssociated: return .success(false)
        case .userDenied: return .failure(.hotspotUserDenied)
        case .applicationIsNotInForeground: return .failure(.hotspotRequiresForeground)
        case .pending: return .failure(.hotspotBusy)
        case .invalid, .invalidSSID, .invalidWPAPassphrase: return .failure(.invalidHotspot)
        default: return .failure(.automaticJoinUnavailable(systemCode: nsError.code))
        }
    }
}

/// TCP carries the same SDUs as Bluetooth. The Session owns authentication and media transfer.
final class MediaWiFiTransport: SessionTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "glasses.media-wifi")
    private let ready = MediaWiFiAwaiter<Void>()
    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var ownedSSID: String?
    private var frames = SDUFrameBuffer()
    private var receiving = false
    private var wrote = false
    private var closed = false
    private var terminalFailure: LinkError?

    /// Invoked after the user requests a transfer and the authenticated Bluetooth peer offers a hotspot.
    static func connect(ssid: String, passphrase: String, host: String, port: UInt16,
                        joinTimeout: TimeInterval = 30, connectTimeout: TimeInterval = 15) async throws -> MediaWiFiTransport {
        let endpoint = try localEndpoint(host: host, port: port)
        guard (1...32).contains(ssid.utf8.count), (8...63).contains(passphrase.utf8.count) else {
            throw MediaWiFiError.invalidHotspot
        }
        try Task.checkCancellation()
        let manager = NEHotspotConfigurationManager.shared
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = true
        let joined = MediaWiFiAwaiter<Bool>()
        manager.apply(configuration) { error in
            let outcome = MediaWiFiError.hotspotOutcome(error)
            if !joined.resolve(outcome.mapError { $0 as Error }), case .success(true) = outcome {
                // The OS can grant consent after the waiting task has timed out or been cancelled.
                manager.removeConfiguration(forSSID: ssid)
            }
        }
        let ownsConfiguration = try await joined.value(timeout: joinTimeout) { MediaWiFiError.hotspotTimeout }
        return try await open(endpoint, ownedSSID: ownsConfiguration ? ssid : nil, timeout: connectTimeout)
    }

    /// For an explicit user-confirmed join in iOS Settings. The app owns no configuration to remove.
    static func connectManuallyJoined(host: String, port: UInt16,
                                      connectTimeout: TimeInterval = 15) async throws -> MediaWiFiTransport {
        let endpoint = try localEndpoint(host: host, port: port)
        return try await open(endpoint, ownedSSID: nil, timeout: connectTimeout)
    }

    private static func open(_ endpoint: Network.NWEndpoint, ownedSSID: String?,
                             timeout: TimeInterval) async throws -> MediaWiFiTransport {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var retries = 0
        do {
            while true {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw MediaWiFiError.connectionTimeout }
                let transport = MediaWiFiTransport(endpoint: endpoint)
                do {
                    try await transport.ready.value(timeout: remaining) { [weak transport] in
                        transport?.connectionFailure(timedOut: true) ?? MediaWiFiError.connectionTimeout
                    }
                    try Task.checkCancellation()
                    try transport.adoptConfiguration(ownedSSID)
                    return transport
                } catch MediaWiFiError.connectionFailed where retries < 3 {
                    // The system can report that the configuration was applied before TCP is available.
                    transport.close()
                    let pause = min(0.3 * pow(2, Double(retries)), max(0, deadline - ProcessInfo.processInfo.systemUptime))
                    retries += 1
                    try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                } catch {
                    transport.close()
                    throw error
                }
            }
        } catch {
            if let ownedSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ownedSSID) }
            throw error
        }
    }

    private static func localEndpoint(host: String, port: UInt16) throws -> Network.NWEndpoint {
        guard port != 0, let endpointPort = Network.NWEndpoint.Port(rawValue: port) else {
            throw MediaWiFiError.invalidEndpoint
        }
        if let address = IPv4Address(host) {
            let bytes = [UInt8](address.rawValue)
            if bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) {
                return .hostPort(host: .ipv4(address), port: endpointPort)
            }
        }
        if let address = IPv6Address(host) {
            let bytes = [UInt8](address.rawValue)
            if (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) {
                return .hostPort(host: .ipv6(address), port: endpointPort)
            }
        }
        throw MediaWiFiError.invalidEndpoint
    }

    private init(endpoint: Network.NWEndpoint) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.requiredInterfaceType = .wifi
        connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in self?.update(state) }
        connection.start(queue: queue)
    }

    deinit {
        close()
    }

    private func adoptConfiguration(_ ssid: String?) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { throw MediaWiFiError.connectionFailed }
        ownedSSID = ssid
    }

    private func connectionFailure(timedOut: Bool) -> MediaWiFiError {
        if let path = connection.currentPath, path.status == .unsatisfied,
           path.unsatisfiedReason == .localNetworkDenied {
            return .localNetworkDenied
        }
        return timedOut ? .connectionTimeout : .connectionFailed
    }

    private func update(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready.resolve(.success(()))
        case .failed:
            let error = connectionFailure(timedOut: false)
            ready.resolve(.failure(error))
            finish(.io(error.description))
        case .cancelled:
            finish(.io("眼镜 Wi-Fi 数据通道已关闭。"))
        default:
            break
        }
    }

    func nextFrame(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let frame = frames.popFirst() { return frame }
            if closed { throw terminalFailure ?? LinkError.io("眼镜 Wi-Fi 数据通道已关闭。") }
            guard Date() < deadline else {
                throw LinkError.unexpected("timeout waiting for a frame (Wi-Fi)")
            }
            if !receiving {
                // A single read per demand bounds the backlog to one TCP chunk plus a partial SDU.
                receiving = true
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
                    self?.received(data, ended: done || error != nil)
                }
            }
            _ = condition.wait(until: deadline)
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        if let data, !data.isEmpty { frames.append(data) }
        receiving = ended
        condition.broadcast()
        condition.unlock()
        if ended { finish(.io("眼镜结束了 Wi-Fi 数据连接。")) }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        let deadline = Date().addingTimeInterval(8)
        condition.lock()
        if closed {
            let failure = terminalFailure ?? LinkError.io("眼镜 Wi-Fi 数据通道已关闭。")
            condition.unlock()
            throw failure
        }
        wrote = false
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.finish(.io("无法向眼镜 Wi-Fi 数据通道写入。"))
            } else {
                self.condition.lock()
                self.wrote = true
                self.condition.broadcast()
                self.condition.unlock()
            }
        })
        while !wrote, !closed, Date() < deadline { _ = condition.wait(until: deadline) }
        let failure = closed ? terminalFailure ?? LinkError.io("眼镜 Wi-Fi 数据通道已关闭。") : nil
        let timedOut = !wrote && failure == nil
        condition.unlock()
        if let failure { throw failure }
        if timedOut {
            let error = LinkError.io("向眼镜写入 Wi-Fi 数据超时。")
            finish(error)
            throw error
        }
    }

    func close() {
        finish(nil)
    }

    private func finish(_ error: LinkError?) {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        terminalFailure = error
        if error == nil { frames = SDUFrameBuffer() }
        let ssid = ownedSSID
        ownedSSID = nil
        condition.broadcast()
        condition.unlock()
        ready.resolve(.failure(error ?? LinkError.io("眼镜 Wi-Fi 数据通道已关闭。")))
        connection.cancel()
        if let ssid { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
    }
}

/// A one-shot system callback whose completion can race the caller's deadline or cancellation.
private final class MediaWiFiAwaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    @discardableResult
    func resolve(_ value: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
        return true
    }

    func value(timeout: TimeInterval, timeoutError: @escaping () -> Error) async throws -> Value {
        let deadline = DispatchWorkItem { self.resolve(.failure(timeoutError())) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                lock.lock()
                if let result {
                    lock.unlock()
                    pending.resume(with: result)
                } else {
                    continuation = pending
                    lock.unlock()
                }
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }
}
