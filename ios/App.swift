// App.swift — the iPhone talks to the glasses by itself.
//
//   scan → connect → L2CAP(PSM 128) → AirShield handshake
//        → (once) become owner via svc36 + Meta   → afterwards: trust
//        → capture list → pull newest photo over the encrypted link
//        → ask your own model about it (any OpenAI-compatible endpoint)

import SwiftUI
import AVFoundation
import Combine
import CoreBluetooth
import CryptoKit
import Photos
import UIKit
import UniformTypeIdentifiers

@main
struct GlassesApp: App {
    init() { CrashLog.install() }
    var body: some Scene { WindowGroup { RootView() } }
}

// MARK: - share sheet plumbing

struct ShareBox: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

enum MediaImportRoute: String, CaseIterable, Identifiable {
    case automatic, manualWiFi, bluetooth

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "Wi-Fi 优先"
        case .manualWiFi: return "手动加入眼镜 Wi-Fi"
        case .bluetooth: return "仅蓝牙"
        }
    }
}

struct ManualMediaWiFiJoin: Identifiable {
    let id: UUID
    let ssid: String
    let password: String
}

// MARK: - link controller

@MainActor
final class Glasses: NSObject, ObservableObject {
    /// Where the one-time setup flow is, kept at the root so nothing can tear it down.
    enum Route: String, Identifiable {
        case ownerSetup, importOwner, becomeOwner, login
        var id: String { rawValue }
    }
    @Published var route: Route?


    /// Whether the glasses accepted the key we hold. This is the single question a user has
    /// ("am I the owner or not?"), so it gets its own state instead of hiding in a log line.
    enum OwnerState: Equatable {
        case unknown
        case unverified          // handshake ran with a temporary key
        case verified            // trust ok (0x1000)
        case rejected(UInt16)    // the glasses said no, with the code they gave
    }
    @Published var ownerState: OwnerState = .unknown

    /// One visible state for "what is happening right now". The user tapped, saw nothing, and
    /// could not tell whether the tap registered — a spinner that disappears after 200 ms and a
    /// silent log are both useless feedback. Everything the UI shows about progress reads this.
    enum Phase: Equatable {
        case idle
        case connecting      // CoreBluetooth connect + L2CAP open
        case reconnecting(Int)
        case handshaking     // ECDH, keys, trust
        case connected
        case failed(String)
    }
    @Published var phase: Phase = .idle

    var phaseText: String {
        switch phase {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .reconnecting(let attempt): return "自动重连中（\(attempt)/\(Self.reconnectDelays.count)）"
        case .handshaking: return "握手中…"
        case .connected: return "已连接"
        case .failed(let why): return "失败：\(why)"
        }
    }

    var phaseBusy: Bool {
        switch phase {
        case .connecting, .reconnecting, .handshaking: return true
        default: return false
        }
    }

    @Published var devices: [ScanEntry] = []
    /// Which row is currently being connected, so the list can show a spinner instead of a button.
    @Published var connectingID: UUID?
    @Published var scanning = false
    @Published private(set) var discoveryMessage: String?

    var primaryDevices: [ScanEntry] {
        devices.filter(\.isVisibleCandidate)
    }
    private var scanTimer: Timer?
    private var ignoredAdvertisers: Set<UUID> = []
    private var sawGlassesAdvertisement = false
    private var scanRound = 0
    private let scanRounds = 6
    @Published var connected = false
    private var connecting = false
    private var connectionAttempt: UUID?
    private var connectionStartedAt: Date?
    private var retriedL2CAP = false
    private var openingL2CAP = false
    @Published var busy = false
    @Published private(set) var mediaMessage: String?
    private let glassesQueue = DispatchQueue(label: "glasseslink.session.operations", qos: .userInitiated)
    @Published var ownerLine = "owner key: 未知"
    /// Human-readable result of the last ownership proof, e.g. "已通过" or a code with a fix.
    @Published var trustLine = "未验证"
    /// Per-capture transfer fraction, filled from the glasses' own byte counts.
    @Published var progress: [String: Double] = [:]
    @Published private(set) var transferDetail: String?
    @Published var importRoute: MediaImportRoute = .automatic
    @Published private(set) var manualMediaWiFi: ManualMediaWiFiJoin?
    @Published private(set) var mediaImportInProgress = false
    @Published private(set) var queuedGlassesActionText: String?
    private var mediaImportID: UUID?
    private var mediaWiFiTransport: MediaWiFiTransport?
    private var mediaWiFiConnectTask: Task<MediaWiFiTransport, Error>?
    private var mediaWiFiSwitching = false
    private struct MediaHotspotCleanup {
        let job: UUID
        let peripheralID: UUID
        let peerKey: Data
        var deadline = ContinuousClock.now.advanced(by: .seconds(120))
    }
    private var pendingMediaHotspot: MediaHotspotCleanup?
    private var manualMediaDecision: CheckedContinuation<Bool, Never>?
    private var manualMediaTimeout: Task<Void, Never>?
    private var albumTransferBatch = false
    private var batchWiFiUnavailable = false
    private enum QueuedCameraAction { case photo, startVideo, stopVideo }
    private var queuedCamera: (action: QueuedCameraAction, peripheralID: UUID)?
    @Published var glassesLine = "未连接"
    @Published var lastPhoto: Data?
    @Published var answer = ""
    @Published var share: ShareBox?

    @Published var modelBaseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? "http://192.168.3.90:11434/v1"
    @Published var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "gemma3:4b"
    @Published private(set) var askingModel = false
    @Published var testingModel = false
    @Published var modelTestLine = ""
    @Published var modelTestOK = false
    @Published var settings: [String: String] = [:]
    @Published var settingsLoading = false
    @Published var status = GlassesState()
    @Published private(set) var statusRefreshing = false
    @Published private(set) var statusMessage: String?
    private var statusRefreshPending = false
    private var loadCatalogAfterStatus = false
    @Published private(set) var audioRouteName = "未检测到媒体输出"
    @Published private(set) var audioRouteUsesBluetooth = false
    @Published private(set) var audioMediaProfile: String?
    private var audioRouteObserver: AnyCancellable?
    @Published var captures: [Capture] = []
    @Published private(set) var importedCaptures: [String: Capture] = {
        guard let data = UserDefaults.standard.data(forKey: "importedCaptureRecords") else { return [:] }
        return (try? JSONDecoder().decode([String: Capture].self, from: data)) ?? [:]
    }()
    @Published private var localMediaIndex = LocalMediaLibrary.load()
    var localCaptures: [Capture] { localMediaIndex.values.map(\.capture) }
    @Published var thumbs: [String: UIImage] = [:]
    @Published var recording = false
    @Published private(set) var lastVideoURL: URL?
    @Published var live: LiveStream?
    @Published var liveLine = "—"
    @Published var selfTestLines: [SelfTest.Line] = []
    @Published var selfTestBad = 0
    @Published var showSelfTest = false
    private var liveTicker: Timer?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var reconnectAfterDisconnect: (id: UUID, forRegistration: Bool)?
    private static let reconnectDelays: [UInt64] = [350_000_000, 2_000_000_000, 5_000_000_000]
    private var recoveryTask: Task<Void, Never>?
    private var recoveringID: UUID?
    private var recoveryAttempts = 0
    private var useQuickHandshake = false
    private var verifiedAt: ContinuousClock.Instant?
    private var autoReconnectSuppressed = false
    private var connectingForRegistration = false
    private var channel: CBL2CAPChannel?
    private var stream: SDUStream?
    private var session: Session?
    private var owner: OwnerMaterial?
    private(set) var ownerRegistrationCompleted = false
    @Published private(set) var registrationMessage: String?

    /// Ray-Ban Meta Gen 2 exposes its link on L2CAP PSM 0x80.
    let psm: CBL2CAPPSM = 0x80

    /// Meta's BLE service. Asking the system for this service is the most reliable way to have
    /// iOS report a peripheral that only advertises service UUIDs (no local name).
    nonisolated static let metaService = "0000FD5F-0000-1000-8000-00805F9B34FB"
    /// Meta's Bluetooth SIG company identifier, little-endian in the advertisement payload.
    static let metaVendorID: UInt16 = 0x01AB

    var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("glasses.log")
    }

    override init() {
        super.init()
        ModelCredentials.migrateLegacyKey(for: modelBaseURL)
        readAudioOutput()
        audioRouteObserver = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.readAudioOutput() } }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "dev.local.glasseslink.central"])
        if let k = OwnerMaterial.loadFromKeychain() {
            owner = k
            ownerLine = "owner key: 已载入 \(k.publicKeyXy.hexShort)"
        } else if let (k, b) = try? OwnerMaterial.load(from: OwnerMaterial.defaultURL) {
            owner = k
            ownerLine = "owner key: 从文件导入 \(b.serial)"
        } else {
            ownerLine = "owner key: 没有——先点「成为主人」"
        }
        // The version banner is load-bearing: without it a pasted log cannot be matched
        // to the build that produced it, and hours get spent re-diagnosing old crashes.
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        LogStore.shared.start(fileURL: logURL)
        note("GlassesLink \(short) (\(build)) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        note("启动。owner=\(owner == nil ? "无" : "有")")
        switch UserDefaults.standard.string(forKey: "ownerState") ?? "" {
        case "verified": ownerState = .verified
        case "unverified": ownerState = .unverified
        case let s where s.hasPrefix("rejected:"):
            ownerState = .rejected(UInt16(s.dropFirst("rejected:".count)) ?? 0)
        default: ownerState = owner == nil ? .unknown : .unverified
        }
        if let prev = CrashLog.takePrevious() {
            note("—— 上次崩溃现场 ——")
            for line in prev.split(separator: "\n").prefix(40) { note("  \(line)") }
        }
        loadThumbs()
    }

    /// Runs the checks that only this phone can answer (key import, both signing paths,
    /// ECDH) and pushes every line into the log so it can be shared after a failed connect.
    func runSelfTest() {
        let lines = SelfTest.run()
        note("—— 自检开始 ——")
        for l in lines { note("\(l.ok ? "✓" : "✗") \(l.text)") }
        let bad = lines.filter { !$0.ok }.count
        note("—— 自检结束：\(lines.count) 项，失败 \(bad) ——")
        // Also show it as a sheet: the log area is easy to miss on first run.
        selfTestLines = lines
        selfTestBad = bad
        showSelfTest = true
    }

    // MARK: logging (kept on disk so it can be shared from the phone)

    /// Everything goes through here. Two rules learned the hard way:
    ///  * never touch @Published off the main thread (crash), and
    ///  * never touch @Published once per line either (the UI freezes: dozens of frames a
    ///    second, each one re-diffing a 500-row array). So lines land in a lock-protected
    ///    buffer and a 4 Hz timer publishes them in one go.
    func note(_ s: String) {
        LogStore.shared.append(s)
    }

    /// Kept for the diagnostics screen; newest first.
    var log: [String] { LogStore.shared.lines }

    static func ts() -> String { LogStore.ts() }

    // MARK: scan / connect

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    private var verifiedPeripheralNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "verifiedPeripheralNames") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "verifiedPeripheralNames") }
    }

    private func rememberVerifiedPeripheral(_ p: CBPeripheral) {
        let key = p.identifier.uuidString
        let name = ScanEntry.usableName(p.name)
        var saved = verifiedPeripheralNames
        if let peerKey = session?.verifiedPeerKey {
            let fingerprint = Data(SHA256.hash(data: peerKey)).hex
            var peers = UserDefaults.standard.dictionary(forKey: "verifiedPeripheralPeers") as? [String: String] ?? [:]
            let aliases = peers.filter { $0.key != key && $0.value == fingerprint }.keys.sorted()
            let priorName = aliases.compactMap { ScanEntry.usableName(saved[$0]) }.first
            saved[key] = name ?? ScanEntry.usableName(saved[key]) ?? priorName ?? ""
            for alias in aliases { saved.removeValue(forKey: alias) }
            let obsoleteIDs = Set(aliases.compactMap(UUID.init(uuidString:)))
            devices.removeAll { obsoleteIDs.contains($0.id) }
            peers[key] = fingerprint
            UserDefaults.standard.set(peers, forKey: "verifiedPeripheralPeers")
        } else {
            saved[key] = name ?? saved[key] ?? ""
        }
        verifiedPeripheralNames = saved
        UserDefaults.standard.set(key, forKey: "lastPeripheral")
        discoveredPeripherals[p.identifier] = p

        let index = devices.firstIndex { $0.id == p.identifier }
        let old = index.map { devices[$0] }
        let entry = ScanEntry(id: p.identifier, peripheralName: name ?? old?.peripheralName,
                              verifiedName: saved[key], advertisementName: old?.advertisementName,
                              rssi: old?.rssi ?? 0, isGlasses: true, isVerified: true,
                              source: old?.source ?? .previouslySelected)
        if let index {
            if entry != devices[index] { devices[index] = entry }
        } else {
            devices.append(entry)
        }
    }

    /// Scanning in rounds instead of once: getting the glasses into pairing mode and starting
    /// the scan are never in sync, and the glasses only announce themselves for a moment.
    func startScan() {
        guard central.state == .poweredOn else {
            discoveryMessage = bluetoothUnavailableMessage
            return
        }
        stopScan()
        devices.removeAll()
        discoveredPeripherals.removeAll()
        loadSystemPaired()
        discoveryMessage = nil
        ignoredAdvertisers.removeAll()
        sawGlassesAdvertisement = false
        scanRound = 0
        scanning = true
        beginScanRound()
    }

    func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        if central.state == .poweredOn { central.stopScan() }
        if scanning, !ignoredAdvertisers.isEmpty {
            note("附近还有 \(ignoredAdvertisers.count) 个未列出的蓝牙信号")
        }
        scanning = false
    }

    private var bluetoothUnavailableMessage: String {
        switch central.state {
        case .poweredOff: return "请在系统设置中打开蓝牙。"
        case .unauthorized: return "请允许 GlassesLink 使用蓝牙。"
        case .unsupported: return "这台设备不支持所需的蓝牙功能。"
        default: return "蓝牙暂不可用，请稍后再试。"
        }
    }

    private func beginScanRound() {
        scanRound += 1
        note("第 \(scanRound)/\(scanRounds) 轮扫描（每轮 15 秒）…眼镜折叠后长按拍摄键 5 秒到指示灯闪蓝")
        // Duplicates must stay ON: the glasses announce themselves in a short burst and
        // then go quiet, so a scan started a second too early would otherwise never see them.
        // Every other round filters on Meta's own service UUID: a peripheral that advertises
        // its services is only reliably reported when you ask for that service.
        let filtered = (scanRound % 2 == 0)
        let services: [CBUUID]? = filtered ? [CBUUID(string: Self.metaService)] : nil
        if filtered { note("这一轮按 Meta 服务 UUID 过滤") }
        central.scanForPeripherals(withServices: services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { timer in
            Task { @MainActor in
                guard self.scanTimer === timer else { return }
                self.central.stopScan()
                if !self.sawGlassesAdvertisement, self.scanRound < self.scanRounds {
                    self.beginScanRound()
                    return
                }
                self.stopScan()
                if self.primaryDevices.isEmpty {
                    self.discoveryMessage = "没找到可连接的眼镜。看到眼镜指示灯闪蓝后，再扫描一次。"
                    self.note("扫描结束，未发现兼容的眼镜")
                }
            }
        }
    }

    /// The system's connected service matches and the last explicitly selected peripheral.
    func loadSystemPaired() {
        guard central.state == .poweredOn else { note("蓝牙不可用：\(central.state.rawValue)"); return }
        let service = CBUUID(string: Self.metaService)
        let connected = central.retrieveConnectedPeripherals(withServices: [service])
        var known: [(CBPeripheral, ScanEntry.Source)] = connected.map { ($0, .systemConnected) }
        if let id = savedGlassesID, !connected.contains(where: { $0.identifier == id }),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            known.append((p, .previouslySelected))
        }
        let verified = verifiedPeripheralNames
        var added = 0
        for (p, source) in known {
            let id = p.identifier
            discoveredPeripherals[id] = p
            let index = devices.firstIndex { $0.id == id }
            let old = index.map { devices[$0] }
            let name = ScanEntry.usableName(p.name) ?? old?.peripheralName
            let trustedName = verified[id.uuidString]
            let entry = ScanEntry(id: id, peripheralName: name, verifiedName: trustedName,
                                  advertisementName: old?.advertisementName, rssi: old?.rssi ?? 0,
                                  isGlasses: source == .systemConnected || ScanEntry.matchesRayBanMetaName(name),
                                  isVerified: trustedName != nil, source: source)
            if let index {
                if entry != devices[index] { devices[index] = entry }
            } else {
                devices.insert(entry, at: 0)
                added += 1
            }
        }
        note("找到 \(connected.count) 台系统已连接的兼容设备，新增 \(added) 条记录")
    }

    func connect(_ id: UUID, forRegistration: Bool = false) {
        guard mediaImportID == nil, !phaseBusy, channel == nil else { return }
        resetRecovery()
        autoReconnectSuppressed = false
        beginConnection(id, forRegistration: forRegistration)
    }

    private func beginConnection(_ id: UUID, forRegistration: Bool = false) {
        guard central.state == .poweredOn else {
            discoveryMessage = bluetoothUnavailableMessage
            return
        }
        if channel != nil {
            note("链路已经打开了，不用再点；要重来先「断开」")
            return
        }
        // Tapping the row repeatedly used to start a fresh connect storm: several
        // openL2CAPChannel() calls in a row all fail with "PSM already connected" and the
        // daemon then holds the channel until the app dies. One attempt at a time only.
        if connecting {
            note("上一次连接还没结束，等 2 秒；一直卡就点「断开」再试")
            return
        }
        connecting = true
        connectingID = id
        if recoveringID != id {
            phase = .connecting
            glassesLine = "正在打开蓝牙连接"
        }
        let knownPeripheral = peripheral?.identifier == id ? peripheral : discoveredPeripherals[id]
        guard let p = knownPeripheral ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            clearLink()
            let reason = "找不到上次的眼镜，正在搜索附近设备。"
            finishRecoveryOrShowFailure(id, reason: reason)
            // Visor issue #114: after the glasses reboot, the cached identifier can go stale and
            // every connect attempt says "Out of reach" while Bluetooth audio stays fine. Rescan
            // instead of making the user guess.
            note("找不到这台设备（可能刚重启过），自动重新扫描…")
            if recoveryTask == nil { startScan() }
            return
        }
        stopScan()
        connectingForRegistration = forRegistration
        useQuickHandshake = !forRegistration && owner != nil && recoveryAttempts <= 1
            && savedGlassesID == id && UserDefaults.standard.bool(forKey: "isOwner")
        discoveryMessage = nil
        peripheral = p
        p.delegate = self
        let name = ScanEntry.usableName(p.name) ?? ScanEntry.usableName(verifiedPeripheralNames[id.uuidString])
        note("连接 \(name ?? devices.first(where: { $0.id == id })?.displayName ?? "未命名设备") …")
        let attempt = UUID()
        connectionAttempt = attempt
        connectionStartedAt = Date()
        let automatic = recoveringID == id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: automatic ? 9_000_000_000 : 15_000_000_000)
            guard let self, self.connectionAttempt == attempt else { return }
            let reason = p.state == .connected ? "打开眼镜蓝牙通道超时" : "蓝牙连接眼镜超时"
            self.failConnection(reason, peripheral: p)
        }
        let bridgeAudio = !forRegistration && verifiedPeripheralNames[id.uuidString] != nil
            && UserDefaults.standard.bool(forKey: "requestedGlassesAudioBridging")
        let options: [String: Any]? = bridgeAudio ? [CBConnectPeripheralOptionEnableTransportBridgingKey: true] : nil
        if p.state == .connected {
            if let options { central.connect(p, options: options) }
            openLink(p)
        } else if p.state == .disconnecting {
            reconnectAfterDisconnect = (id, forRegistration)
        } else {
            central.connect(p, options: options)
        }
    }

    /// The glasses stay paired at the iOS level, so a cold launch can go straight back to
    /// the same peripheral without scanning — that is what makes "打开就能用" work.
    func autoReconnect() {
        guard mediaImportID == nil, !connected, !phaseBusy, central.state == .poweredOn,
              !autoReconnectSuppressed else { return }
        if case .rejected = ownerState { return }
        if UserDefaults.standard.bool(forKey: "linkInFlight") {
            // Last launch died inside the handshake. Reconnecting automatically would replay
            // the same crash, so this launch waits for an explicit tap.
            UserDefaults.standard.set(false, forKey: "linkInFlight")
            note("上次是在握手途中退出的，这次不自动重连——请手动点一次眼镜，日志里会有崩溃现场")
            return
        }
        guard let id = savedGlassesID else { return }
        note("自动连接上次的眼镜 …")
        connect(id)
    }

    private var savedGlassesID: UUID? {
        UserDefaults.standard.string(forKey: "lastPeripheral").flatMap(UUID.init(uuidString:))
    }

    var hasSavedGlasses: Bool { savedGlassesID != nil }

    func reconnectLastGlasses() {
        guard let id = savedGlassesID else { startScan(); return }
        connect(id)
    }

    var canUseGlasses: Bool { connected && ownerState == .verified && session != nil }
    var connectedGlassesName: String? {
        guard canUseGlasses, let peripheral else { return nil }
        return ScanEntry.usableName(peripheral.name)
            ?? ScanEntry.usableName(verifiedPeripheralNames[peripheral.identifier.uuidString])
    }

    // MARK: link bring-up

    private func bringUp(trust: Bool) async {
        guard let ch = channel else { note("没有 L2CAP 通道"); return }
        let s = SDUStream(channel: ch)
        s.onLog = { [weak self] in self?.note($0) }
        stream = s
        s.setFailureHandler { [weak self, weak s] error in
            Task { @MainActor in
                guard let self, let s, self.stream === s, let p = self.peripheral else { return }
                self.failConnection("眼镜蓝牙数据通道已中断。", peripheral: p, underlying: error)
            }
        }
        // No key yet is not a dead end: the setup link only needs *a* key pair so the
        // handshake can run, and provisioning replaces it with the real one afterwards.
        if owner == nil {
            note("还没有 owner key：先用临时密钥把链路打通（成为主人时会换成正式那把）")
        }
        let own = owner ?? OwnerMaterial.generate()
        let sess = Session(stream: s, owner: own, log: { [weak self] in self?.note($0) })
        let quickStart = trust && useQuickHandshake
        sess.blockOTA = Glasses.blockOTA
        session = sess
        // A crash inside handshake() would otherwise be repeated by auto-reconnect on every
        // launch, which is exactly the "闪退十几次" loop. We mark the attempt in flight and
        // clear it on the way out, so a leftover flag at next launch means "it died here".
        UserDefaults.standard.set(true, forKey: "linkInFlight")
        defer {
            if session === sess { UserDefaults.standard.set(false, forKey: "linkInFlight") }
        }
        do {
            // handshake() blocks on NSCondition while it waits for the glasses (up to 12 s).
            // Calling it straight from a @MainActor method froze the whole UI for the whole
            // wait — that is the "tapping anything takes seconds" report. Run it off-main.
            try await Task.detached(priority: .userInitiated) {
                try sess.handshake(trust: trust, quickStart: quickStart)
            }.value
            guard session === sess else { return }
            connected = true
            connectingID = nil
            phase = .connected
            if trust {
                verifiedAt = ContinuousClock.now
                UserDefaults.standard.set(true, forKey: "isOwner")
                trustLine = "已验证（这台 iPhone 是主人）"
                ownerState = .verified
                if let peripheral { rememberVerifiedPeripheral(peripheral) }
            } else {
                trustLine = "未验证（用的是临时密钥）"
                ownerState = .unverified
            }
            glassesLine = "已连上 · serial \(sess.peerSerial)"
            mediaMessage = nil
            let elapsed = connectionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            note("✅ 握手完成 · \(elapsed.map(String.init) ?? "未知") ms（quirks=\(sess.quirks)）")
            connectionStartedAt = nil
            UserDefaults.standard.set(trust ? "verified" : "unverified", forKey: "ownerState")
            UserDefaults.standard.set(Self.ts(), forKey: "ownerStateAt")
            if trust, mediaImportID == nil {
                if let pending = pendingMediaHotspot, peripheral?.identifier == pending.peripheralID {
                    busy = true
                    await closeMediaHotspot(using: sess, job: pending.job)
                    guard session === sess else { return }
                    busy = false
                }
                loadCatalogAfterStatus = true
                refreshStatus()
            }
        } catch {
            guard session === sess else { return }
            trustLine = Glasses.explain(error)
            note("❌ 握手中断：\(error)")
            if quickStart, case LinkError.unexpected(let reason) = error,
               reason == Session.missingPeerEncryptionRequest,
               let id = peripheral?.identifier {
                recoveringID = id
                recoveryAttempts = max(1, recoveryAttempts)
                note("眼镜未回应快速握手，改用完整等待窗口")
            }
            if case LinkError.trustRejected(let code) = error {
                resetRecovery()
                ownerState = .rejected(code)
                UserDefaults.standard.set("rejected:\(code)", forKey: "ownerState")
                UserDefaults.standard.set(Self.ts(), forKey: "ownerStateAt")
            }
            // Release the link on failure: otherwise the next tap only reports
            // "链路已经打开了" and the user is stuck until the app is killed.
            if let p = peripheral {
                failConnection("握手失败 · \(Glasses.explain(error))", peripheral: p)
            }
        }
    }

    /// Turns the glasses' status codes into something actionable, because a bare hex code
    /// tells the user nothing and the fix is different for each one.
    static func explain(_ error: Error) -> String {
        if let e = error as? LinkError {
            switch e {
            case .trustRejected(let code):
                switch code {
                case 0x1010: return "眼镜不认识这把钥匙（0x1010）——导入 Visor 导出的 owner-export.json"
                case 0x1044: return "签名不被接受（0x1044）——钥匙或签名方式与眼镜记的不一致"
                case 0x1042: return "眼镜属于另一个 Meta 账号（0x1042）——要用当初注册它的账号"
                case 0x1040: return "receipt 无效（0x1040）——重新注册一次"
                case 0x1045: return "时间戳超范围（0x1045）——手机时间不准"
                default: return "信任被拒：\(AirShield.statusName(code))（0x\(String(code, radix: 16))）"
                }
            case .serviceError(let step, let code):
                return "「\(step)」被拒：\(AirShield.statusName(code))（0x\(String(code, radix: 16))）"
            case .unexpected(let s): return "链路数据异常：\(s)"
            case .badMAC: return "一帧没通过校验（bad MAC）——密钥或计数不同步"
            default: return e.description
            }
        }
        return "\(error)"
    }

    func connectSetup() {
        registrationMessage = nil
        reconnect(forRegistration: true)
    }


    /// Refuse every svc29 (firmware update) request. Default on: the phone is the only
    /// thing that can feed an update, so saying no is the real "do not update" switch.
    static var blockOTA: Bool {
        get {
            if UserDefaults.standard.object(forKey: "blockOTA") == nil { return true }
            return UserDefaults.standard.bool(forKey: "blockOTA")
        }
        set { UserDefaults.standard.set(newValue, forKey: "blockOTA") }
    }

    private func clearLink() {
        if session != nil { UserDefaults.standard.set(false, forKey: "linkInFlight") }
        session = nil
        stream?.close()
        stream = nil
        channel = nil
        connected = false
        verifiedAt = nil
        connecting = false
        connectingID = nil
        connectingForRegistration = false
        useQuickHandshake = false
        connectionAttempt = nil
        connectionStartedAt = nil
        retriedL2CAP = false
        openingL2CAP = false
        ownerRegistrationCompleted = false
        busy = mediaImportID != nil
        settingsLoading = false
        loadCatalogAfterStatus = false
        statusRefreshPending = false
        statusRefreshing = false
        statusMessage = nil
        settings = [:]
        status = GlassesState()
        recording = false
        recordingCatalogBaseline = nil
        recordDeadline = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        liveTicker?.invalidate()
        liveTicker = nil
        live = nil
        assistantRef?.stop()
        assistantRef = nil
        assistantOn = false
        assistantRegistering = false
        assistantMessage = nil
        assistantAnswer = ""
        resetVoiceTurn()
    }

    private func failConnection(_ reason: String, peripheral p: CBPeripheral, underlying: Error? = nil) {
        if mediaWiFiSwitching, mediaImportID != nil {
            releaseBluetoothForMediaWiFi()
            note("切换到眼镜 Wi-Fi 期间蓝牙控制通道关闭")
            return
        }
        allowRecoveryForUnexpectedLoss(of: p.identifier)
        reconnectAfterDisconnect = nil
        clearLink()
        if p.state != .disconnected { central.cancelPeripheralConnection(p) }
        if let underlying { note("蓝牙通道错误：\(underlying)") }
        finishRecoveryOrShowFailure(p.identifier, reason: reason)
        if recoveryTask == nil, mediaImportID == nil, !autoReconnectSuppressed,
           savedGlassesID == p.identifier, reason == "蓝牙连接眼镜超时", central.state == .poweredOn {
            startScan()
        }
    }

    private func allowRecoveryForUnexpectedLoss(of id: UUID) {
        guard let verifiedAt, canUseGlasses, savedGlassesID == id else { return }
        if verifiedAt.duration(to: ContinuousClock.now) >= .seconds(30) { recoveryAttempts = 0 }
        recoveringID = id
    }

    private func finishRecoveryOrShowFailure(_ id: UUID, reason: String) {
        note(reason)
        guard let attempt = scheduleRecovery(id) else {
            phase = .failed(reason)
            glassesLine = reason
            mediaMessage = reason + " 可在设备页重新连接。"
            runQueuedCameraIfReady()
            return
        }
        phase = .reconnecting(attempt)
        connectingID = id
        glassesLine = reason
        mediaMessage = "连接中断，正在自动重连。请在连接恢复后重新发起操作。"
    }

    private func scheduleRecovery(_ id: UUID) -> Int? {
        guard recoveringID == id, !autoReconnectSuppressed, central.state == .poweredOn,
              recoveryAttempts < Self.reconnectDelays.count else { return nil }
        let delay = Self.reconnectDelays[recoveryAttempts]
        recoveryAttempts += 1
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.recoveringID == id else { return }
            self.recoveryTask = nil
            self.beginConnection(id)
        }
        return recoveryAttempts
    }

    private func resetRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveringID = nil
        recoveryAttempts = 0
    }

    func disconnect() {
        mediaImportID = nil
        mediaWiFiSwitching = false
        mediaImportInProgress = false
        mediaWiFiConnectTask?.cancel()
        mediaWiFiConnectTask = nil
        mediaWiFiTransport?.close()
        mediaWiFiTransport = nil
        resolveManualMediaWiFi(false)
        progress.removeAll()
        transferDetail = nil
        cancelQueuedGlassesAction()
        autoReconnectSuppressed = true
        resetRecovery()
        reconnectAfterDisconnect = nil
        clearLink()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        phase = .idle
        glassesLine = "未连接"
        mediaMessage = nil
        note("已断开，可以重新点了")
    }

    func reconnectForOwnerVerification() { reconnect(forRegistration: false) }

    private func reconnect(forRegistration: Bool) {
        guard !phaseBusy else { return }
        guard let p = peripheral else { startScan(); return }
        resetRecovery()
        clearLink()
        if p.state == .disconnected {
            connect(p.identifier, forRegistration: forRegistration)
            return
        }
        reconnectAfterDisconnect = (p.identifier, forRegistration)
        connecting = true
        connectingID = p.identifier
        phase = .connecting
        glassesLine = "正在重新连接眼镜"
        central.cancelPeripheralConnection(p)
    }

    // MARK: capture

    private func onGlassesQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            glassesQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func reportOperationError(_ error: Error, session active: Session) {
        guard session === active else { return }
        mediaMessage = Glasses.explain(error)
        note("设备操作失败：\(error)")
        if case LinkError.badMAC = error, let p = peripheral {
            failConnection("连接数据校验失败，请重新连接眼镜。", peripheral: p)
        }
    }

    private func withGlassesOperation<T>(_ action: @MainActor (Session) async throws -> T) async -> T? {
        guard canUseGlasses, let active = session else {
            mediaMessage = "请先连接眼镜并验证主人身份。"
            return nil
        }
        guard !busy, !settingsLoading, live == nil, assistantRef == nil else {
            mediaMessage = "眼镜正在处理其他操作，请稍后再试。"
            return nil
        }
        busy = true
        mediaMessage = nil
        defer {
            if session === active {
                busy = false
                startPendingStatusRefresh()
                runQueuedCameraIfReady()
            }
        }
        do {
            return try await action(active)
        } catch {
            reportOperationError(error, session: active)
            return nil
        }
    }

    private func checkActive(_ active: Session) throws {
        guard session === active else { throw LinkError.io("眼镜连接已结束") }
    }

    private func updateCaptures(_ list: [Capture]) {
        captures = list.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
        note("相册清单 \(list.count) 条")
    }

    func loadCaptures() {
        Task {
            _ = await withGlassesOperation { active in
                mediaMessage = "正在读取眼镜相册…"
                let list = try await onGlassesQueue { try active.captureList() }
                try checkActive(active)
                updateCaptures(list)
                mediaMessage = list.isEmpty ? "眼镜相册为空。" : nil
            }
        }
    }

    func fetch(_ captureItem: Capture, saveToLibrary: Bool) {
        Task {
            _ = await withGlassesOperation { active in
                try await downloadCapture(captureItem, from: active, save: saveToLibrary || !captureItem.isPhoto)
            }
        }
    }

    func importCapture(_ capture: Capture) async -> Bool {
        await withGlassesOperation { active in
            try await downloadCapture(capture, from: active, save: true)
        } ?? false
    }

    func localMediaURL(for capture: Capture) -> URL? {
        localMediaIndex[capture.id].flatMap(LocalMediaLibrary.url(for:))
    }

    func beginAlbumTransferBatch() {
        albumTransferBatch = true
        batchWiFiUnavailable = false
    }

    func endAlbumTransferBatch() {
        albumTransferBatch = false
        runQueuedCameraIfReady()
        startPendingStatusRefresh()
    }

    func resolveManualMediaWiFi(_ useWiFi: Bool) {
        let decision = manualMediaDecision
        manualMediaDecision = nil
        manualMediaTimeout?.cancel()
        manualMediaTimeout = nil
        manualMediaWiFi = nil
        decision?.resume(returning: useWiFi)
    }

    private func askToJoinMediaWiFi(_ endpoint: MediaWiFiEndpoint, id: UUID) async -> Bool {
        await withCheckedContinuation { decision in
            guard mediaImportID == id else { decision.resume(returning: false); return }
            manualMediaDecision = decision
            manualMediaWiFi = ManualMediaWiFiJoin(id: id, ssid: endpoint.ssid, password: endpoint.password)
            manualMediaTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 75_000_000_000) } catch { return }
                guard let self, self.mediaImportID == id else { return }
                self.resolveManualMediaWiFi(false)
            }
        }
    }

    func cacheOriginal(_ capture: Capture) async -> Bool {
        await withGlassesOperation { active in
            try await downloadCapture(capture, from: active, save: false)
        } ?? false
    }

    var canDeleteGlassesCaptures: Bool {
        canUseGlasses && !busy && !settingsLoading && live == nil && assistantRef == nil
    }

    /// Called only after the user confirms the exact selection in the glasses album.
    func deleteGlassesCaptures(_ selection: [Capture]) async -> Set<String> {
        let selected = Dictionary(grouping: selection, by: \.handle).mapValues { Set($0.map(\.id)) }
        guard !selected.isEmpty, selected.values.allSatisfy({ $0.count == 1 }) else { return [] }
        let deleted: Set<String>? = await withGlassesOperation { active in
            var seen = Set<String>()
            let targets = captures.filter {
                importedCaptures[$0.id] == nil && selected[$0.handle]?.contains($0.id) == true
                    && seen.insert($0.handle).inserted
            }
            guard targets.count == selected.count else {
                mediaMessage = "眼镜相册已变化，请刷新后重新选择。"
                return []
            }
            mediaMessage = "正在删除眼镜内的 \(targets.count) 项原件…"
            let result = try await onGlassesQueue {
                var acknowledged = Set<String>()
                var failure: Error?
                for target in targets {
                    do {
                        try active.requestCaptureDeletion(handle: target.handle)
                        acknowledged.insert(target.handle)
                    } catch {
                        if failure == nil { failure = error }
                        // A status rejection is a reply from a live link. A timeout or
                        // transport error leaves this request uncertain, so stop the batch.
                        if case LinkError.serviceError = error { continue }
                        if case LinkError.badMAC = error { throw error }
                        if case LinkError.io = error { throw error }
                        break
                    }
                }
                let updated = Result { try active.captureList(timeout: 8) }
                return (acknowledged, failure, updated)
            }
            try checkActive(active)
            switch result.2 {
            case .success(let updated):
                updateCaptures(updated)
                let stillOnGlasses = Set(updated.map(\.handle))
                let removed = Set(targets.compactMap { target in
                    result.0.contains(target.handle) && !stillOnGlasses.contains(target.handle) ? target.id : nil
                })
                let outstanding = targets.count - removed.count
                mediaMessage = outstanding == 0
                    ? "已确认删除 \(removed.count) 项眼镜原件。"
                    : "已确认删除 \(removed.count) 项。另有 \(outstanding) 项结果未确认。"
                if let error = result.1 { note("删除眼镜原件的部分请求未确认：\(error)") }
                if !removed.isEmpty { refreshStatus() }
                return removed
            case .failure(let error):
                note("删除后读取眼镜清单失败：\(error)")
                if case LinkError.badMAC = error { throw error }
                mediaMessage = "眼镜清单暂时无法确认删除结果，请稍后刷新。"
                return []
            }
        }
        return deleted ?? []
    }

    private func downloadCapture(_ capture: Capture, from active: Session, save: Bool) async throws -> Bool {
        let id = capture.id
        if save, importedCaptures[id] != nil { return true }
        if let existing = localMediaURL(for: capture) {
            if save { try await saveImportedCapture(capture, file: existing, transfer: nil, session: active) }
            return true
        }
        guard !recording else { throw LinkError.unexpected("请先结束眼镜录像，再导入原件。") }
        let candidates = capture.isPhoto ? capture.stills : capture.assets.filter { $0.type == 1 }
        let asset = candidates.max { $0.size < $1.size }
        guard let asset else {
            throw LinkError.unexpected("这条记录没有可导入的原文件")
        }
        let job = UUID()
        mediaImportID = job
        mediaImportInProgress = true
        progress[id] = 0
        mediaMessage = "正在从眼镜导入…"
        defer {
            if mediaImportID == job {
                progress.removeValue(forKey: id)
                mediaImportID = nil
                mediaImportInProgress = false
                transferDetail = nil
                if session !== active {
                    busy = false
                    if !connected, !autoReconnectSuppressed { autoReconnect() }
                    startPendingStatusRefresh()
                    runQueuedCameraIfReady()
                }
            }
        }
        let started = Date()
        let (transfer, route): (Session.Transfer, String)
        do {
            (transfer, route) = try await receiveCapture(capture, asset: asset, control: active, job: job)
        } catch {
            if mediaImportID == job, session == nil { mediaMessage = Glasses.explain(error) }
            throw error
        }
        guard mediaImportID == job else { throw CancellationError() }
        let elapsed = Date().timeIntervalSince(started)
        note("\(route) 导入 \(transfer.size)B · \(String(format: "%.1f", elapsed)) 秒")
        transferDetail = nil
        let file: URL?
        do {
            let item = try await onGlassesQueue {
                try LocalMediaLibrary.store(transfer.data, capture: capture, originalName: transfer.name)
            }
            localMediaIndex[id] = item
            LocalMediaLibrary.saveIndex(localMediaIndex)
            file = LocalMediaLibrary.url(for: item)
        } catch {
            guard save else { throw error }
            note("App 原件缓存失败：\(error.localizedDescription)")
            file = nil
        }
        guard mediaImportID == job else { throw CancellationError() }
        if capture.isPhoto {
            lastPhoto = transfer.data
            rememberThumb(id, transfer.data)
        } else if let file {
            lastVideoURL = file
            rememberVideoThumb(id, file)
        }
        guard save else {
            if mediaImportID == job { mediaMessage = "原件已保存到 App，可直接打开。" }
            return true
        }
        let savingOn = session
        do {
            try await saveImportedCapture(capture, file: file, transfer: transfer.data, session: savingOn ?? active)
        } catch {
            if mediaImportID == job, session === savingOn { mediaMessage = Glasses.explain(error) }
            throw error
        }
        if mediaImportID == job, !connected { mediaMessage = "文件已存入 iPhone 相册。蓝牙控制正在恢复。" }
        return true
    }

    private func receiveCapture(_ capture: Capture, asset: CaptureAsset, control: Session, job: UUID)
        async throws -> (Session.Transfer, String) {
        var bluetooth: Session? = control
        let route = importRoute
        if route != .bluetooth, !batchWiFiUnavailable {
            let attempt = await receiveThroughMediaWiFi(capture, asset: asset, control: control, job: job,
                                                        manual: route == .manualWiFi)
            bluetooth = attempt.bluetooth
            guard mediaImportID == job else { throw CancellationError() }
            switch attempt.result {
            case .success(let file): return (file, "Wi-Fi")
            case .failure(let reason):
                if albumTransferBatch { batchWiFiUnavailable = true }
                let message = Glasses.explain(reason)
                note("眼镜 Wi-Fi 导入未完成，回退蓝牙：\(message)")
                mediaMessage = "Wi-Fi 未完成，改用蓝牙。"
                if bluetooth == nil { throw LinkError.io("Wi-Fi 未完成，蓝牙也尚未恢复。请重连眼镜后重试。") }
            }
        }
        guard let bluetooth, session === bluetooth, stream != nil else {
            throw LinkError.io("眼镜蓝牙控制链路尚未恢复。")
        }
        progress[capture.id] = 0
        transferDetail = "蓝牙 · 等待文件"
        do {
            return (try await readCaptureFile(from: bluetooth, capture: capture, asset: asset, job: job, wifi: false), "蓝牙")
        } catch {
            if mediaImportID == job, bluetooth !== control { reportOperationError(error, session: bluetooth) }
            throw error
        }
    }

    private func receiveThroughMediaWiFi(_ capture: Capture, asset: CaptureAsset, control: Session, job: UUID,
                                          manual: Bool) async -> (result: Result<Session.Transfer, Error>, bluetooth: Session?) {
        var wifi: Session?
        let result: Result<Session.Transfer, Error>
        do {
            guard let expectedKey = control.verifiedPeerKey, let peripheralID = peripheral?.identifier,
                  let country = Locale.current.region?.identifier else {
                throw LinkError.unexpected("眼镜身份或 iPhone 地区尚未读取。")
            }
            transferDetail = "Wi-Fi · 正在启动眼镜热点"
            pendingMediaHotspot = MediaHotspotCleanup(job: job, peripheralID: peripheralID, peerKey: expectedKey)
            let endpoint = try await onGlassesQueue {
                try control.createMediaSoftAP(countryCode: country, timeout: 12)
            }
            try checkActive(control)
            guard mediaImportID == job else { throw CancellationError() }
            try await onGlassesQueue {
                try control.queueAssetForMediaWiFi(handle: capture.handle, assetID: asset.uuid, delivered: asset.delivered)
            }
            guard mediaImportID == job else { throw CancellationError() }
            mediaWiFiSwitching = true
            transferDetail = manual ? "Wi-Fi · 等待手动加入热点" : "Wi-Fi · 正在加入眼镜热点"
            guard mediaImportID == job else { throw CancellationError() }
            let connectTask = Task {
                if !manual {
                    do {
                        return try await MediaWiFiTransport.connect(ssid: endpoint.ssid, passphrase: endpoint.password,
                                                                    host: endpoint.address, port: endpoint.port)
                    } catch let error as MediaWiFiError where error.canOfferManualJoin {
                        guard self.mediaImportID == job, !Task.isCancelled else { throw CancellationError() }
                        self.note("眼镜热点已创建，iOS 自动加入失败：\(error.diagnosticDescription)")
                        self.transferDetail = "Wi-Fi · 等待手动加入同一热点"
                    }
                }
                guard await self.askToJoinMediaWiFi(endpoint, id: job) else { throw MediaWiFiError.hotspotUserDenied }
                try Task.checkCancellation()
                return try await MediaWiFiTransport.connectManuallyJoined(host: endpoint.address, port: endpoint.port)
            }
            mediaWiFiConnectTask = connectTask
            let transport = try await connectTask.value
            guard mediaImportID == job else { transport.close(); throw CancellationError() }
            mediaWiFiTransport = transport
            releaseBluetoothForMediaWiFi()
            let connection = Session(stream: transport, owner: control.owner)
            connection.blockOTA = true
            wifi = connection
            transferDetail = "Wi-Fi · 正在验证同一副眼镜"
            try await onGlassesQueue {
                try connection.handshake(timeout: 10, trust: true, quickStart: true, expectedPeerKey: expectedKey)
            }
            guard mediaImportID == job else { throw CancellationError() }
            transferDetail = "Wi-Fi · 等待文件"
            result = .success(try await readCaptureFile(from: connection, capture: capture, asset: asset,
                                                        job: job, wifi: true))
        } catch {
            result = .failure(error)
        }
        if pendingMediaHotspot?.job == job {
            pendingMediaHotspot?.deadline = ContinuousClock.now.advanced(by: .seconds(120))
        }
        if let wifi { await closeMediaHotspot(using: wifi, job: job) }
        wifi?.close()
        if mediaImportID == job {
            mediaWiFiConnectTask = nil
            mediaWiFiTransport?.close()
            mediaWiFiTransport = nil
            mediaWiFiSwitching = false
        }
        let bluetooth = await restoreMediaBluetooth(control: control, job: job)
        if let bluetooth, mediaImportID == job {
            await closeMediaHotspot(using: bluetooth, job: job)
        }
        return (result, bluetooth)
    }

    private func closeMediaHotspot(using link: Session, job: UUID) async {
        guard let pending = pendingMediaHotspot, pending.job == job else { return }
        guard ContinuousClock.now < pending.deadline else { pendingMediaHotspot = nil; return }
        guard peripheral?.identifier == pending.peripheralID, link.verifiedPeerKey == pending.peerKey else { return }
        if (try? await onGlassesQueue { try link.destroyMediaSoftAP() }) != nil,
           pendingMediaHotspot?.job == job { pendingMediaHotspot = nil }
    }

    private func releaseBluetoothForMediaWiFi() {
        let oldStream = stream
        stream = nil
        channel = nil
        oldStream?.close()
        glassesLine = "导入切换到眼镜 Wi-Fi，蓝牙控制暂时让出"
    }

    private func restoreMediaBluetooth(control: Session, job: UUID) async -> Session? {
        guard mediaImportID == job else { return nil }
        if canUseGlasses, stream != nil, let current = session { return current }
        guard let id = peripheral?.identifier, central.state == .poweredOn else { return nil }
        if !phaseBusy || session === control {
            resetRecovery()
            session = nil
            connected = false
            verifiedAt = nil
            glassesLine = "正在恢复蓝牙控制连接"
            transferDetail = "正在恢复蓝牙控制连接"
            beginConnection(id)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline, mediaImportID == job, !Task.isCancelled {
            if canUseGlasses, stream != nil, let active = session { return active }
            if case .failed = phase { break }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return nil
    }

    private func readCaptureFile(from link: Session, capture: Capture, asset: CaptureAsset, job: UUID,
                                 wifi: Bool) async throws -> Session.Transfer {
        let route = wifi ? "Wi-Fi" : "蓝牙"
        let id = capture.id
        let file = try await onGlassesQueue { [weak self] in
            if !wifi { try link.requestAsset(handle: capture.handle, assetID: asset.uuid) }
            var lastUpdate = ContinuousClock.now
            var sampleStart = Date()
            let maximumDuration = max(300, Double(asset.size) / 8_192)
            return try link.receiveFile(timeout: wifi ? 12 : 45, maximumDuration: maximumDuration,
                                        expectedAssetID: wifi ? asset.uuid : nil) { got, total in
                let now = ContinuousClock.now
                if got == 0 { sampleStart = Date() }
                guard got == total || lastUpdate.duration(to: now) >= .milliseconds(250) else { return }
                lastUpdate = now
                let seconds = Date().timeIntervalSince(sampleStart)
                let bytesPerSecond = seconds >= 1 && got > 0 ? Double(got) / seconds : 0
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.mediaImportID == job, self.progress[id] != nil, total > 0 else { return }
                    self.progress[id] = Double(got) / Double(total)
                    if bytesPerSecond > 0 {
                        let rate = String(format: "%.0f KB/s", bytesPerSecond / 1_000)
                        let remaining = Int(min(86_400, ceil(Double(max(0, total - got)) / bytesPerSecond)))
                        let eta = remaining < 60 ? "\(remaining) 秒" : "\((remaining + 59) / 60) 分钟"
                        self.transferDetail = "\(route) · \(rate) · 约 \(eta)"
                    } else {
                        self.transferDetail = "\(route) · 正在接收"
                    }
                }
            }
        }
        guard let file else { throw LinkError.unexpected("眼镜没有发送文件。") }
        return file
    }

    private func saveImportedCapture(_ capture: Capture, file: URL?, transfer: Data?, session active: Session) async throws {
        if session === active { mediaMessage = "正在存入 iPhone 相册…" }
        try await persistCapture(transfer, isPhoto: capture.isPhoto, original: file)
        importedCaptures[capture.id] = capture
        if let data = try? JSONEncoder().encode(importedCaptures) {
            UserDefaults.standard.set(data, forKey: "importedCaptureRecords")
        }
        if session === active {
            mediaMessage = file == nil ? "已存入 iPhone 相册，App 本机原件未保存。" : "已存入 iPhone 相册，也可在 App 内打开。"
        }
    }

    func snap() {
        if queueCameraDuringImport(.photo) { return }
        Task {
            _ = await withGlassesOperation { active in
                mediaMessage = "正在拍照…"
                let baseline = try await catalogBeforeCapture(on: active)
                let cameraState = try await onGlassesQueue { try active.shutterPhoto() }
                try checkActive(active)
                if let cameraState { status.camera = cameraState.camera }
                note(cameraState == nil ? "拍照：未收到相机状态，改查新照片" : "拍照：眼镜确认开始")
                await verifyNewCapture(on: active, baseline: baseline, photo: true, acknowledged: cameraState != nil)
            }
        }
    }

    func toggleRecording() {
        if queueCameraDuringImport(recording ? .stopVideo : .startVideo) { return }
        Task {
            _ = await withGlassesOperation { active in
                let stopping = recording
                mediaMessage = stopping ? "正在等待眼镜确认停止录像…" : "正在等待眼镜确认开始录像…"
                var baseline = recordingCatalogBaseline
                if !stopping { baseline = try await catalogBeforeCapture(on: active) }
                let cameraState = try await onGlassesQueue {
                    try (stopping ? active.stopVideo() : active.startVideo())
                }
                try checkActive(active)
                status.camera = cameraState.camera
                recording = !stopping
                if stopping {
                    autoStopTask?.cancel()
                    autoStopTask = nil
                    recordDeadline = nil
                    mediaMessage = "眼镜已确认停止录像，正在查询新视频…"
                    note("眼镜确认停止录像")
                    recordingCatalogBaseline = nil
                    await verifyNewCapture(on: active, baseline: baseline, photo: false, acknowledged: true)
                } else {
                    recordingCatalogBaseline = baseline
                    scheduleAutoStop()
                    mediaMessage = nil
                    note("眼镜确认开始录像")
                }
            }
        }
    }

    private func queueCameraDuringImport(_ action: QueuedCameraAction) -> Bool {
        guard mediaImportInProgress || albumTransferBatch else { return false }
        guard queuedCamera == nil, let id = peripheral?.identifier else { return true }
        queuedCamera = (action, id)
        switch action {
        case .photo: queuedGlassesActionText = "拍照已排队，导入后执行"
        case .startVideo: queuedGlassesActionText = "开始录像已排队，导入后执行"
        case .stopVideo: queuedGlassesActionText = "停止录像已排队，导入后执行"
        }
        return true
    }

    func cancelQueuedGlassesAction() {
        queuedCamera = nil
        queuedGlassesActionText = nil
    }

    private func runQueuedCameraIfReady() {
        guard !albumTransferBatch, !mediaImportInProgress, !busy, !settingsLoading, let queued = queuedCamera else { return }
        if phaseBusy, peripheral?.identifier == queued.peripheralID { return }
        cancelQueuedGlassesAction()
        guard UIApplication.shared.applicationState == .active, canUseGlasses,
              peripheral?.identifier == queued.peripheralID, assistantRef == nil, live == nil else {
            mediaMessage = "排队的拍摄已取消，请重新操作。"
            return
        }
        switch queued.action {
        case .photo: if !recording { snap() }
        case .startVideo: if !recording { toggleRecording() }
        case .stopVideo: if recording { toggleRecording() }
        }
    }

    /// 0 means "until I stop it". The glasses themselves cap a clip, so this only decides when
    /// *we* send the stop; it is enforced on our side so the length is predictable.
    @Published var maxRecordSeconds: Int = UserDefaults.standard.integer(forKey: "maxRecordSeconds") {
        didSet {
            UserDefaults.standard.set(maxRecordSeconds, forKey: "maxRecordSeconds")
            recordDeadline = nil
            if recording { scheduleAutoStop() }
        }
    }
    @Published var recordDeadline: Date?
    private var recordingCatalogBaseline: [Capture]?

    private var autoStopTask: Task<Void, Never>?

    private func catalogBeforeCapture(on active: Session) async throws -> [Capture]? {
        do {
            let catalog = try await onGlassesQueue { try active.captureList(timeout: 2) }
            try checkActive(active)
            return catalog
        } catch LinkError.unexpected(_) {
            try checkActive(active)
            note("拍摄：拍摄前相册未完成刷新")
            return nil
        }
    }

    private func verifyNewCapture(on active: Session, baseline: [Capture]?, photo: Bool, acknowledged: Bool) async {
        let kind = photo ? "照片" : "视频"
        mediaMessage = "正在检查眼镜相册里的新\(kind)…"
        for delay in [350, 850, 1_500] {
            do {
                try await Task.sleep(for: .milliseconds(delay))
                try checkActive(active)
                let catalog = try await onGlassesQueue { try active.captureList(timeout: 2) }
                try checkActive(active)
                updateCaptures(catalog)
                guard let baseline else {
                    mediaMessage = "已刷新眼镜相册。本次\(kind)暂无法确认。"
                    return
                }
                if Shutter.hasNewOriginal(in: catalog, comparedTo: baseline, photo: photo) {
                    mediaMessage = "眼镜相册已出现新\(kind)，可以打开相册导入。"
                    note("拍摄验证：已发现包含原件的新\(kind)")
                    return
                }
            } catch LinkError.unexpected(_) {
                continue
            } catch {
                reportOperationError(error, session: active)
                return
            }
        }
        guard session === active else { return }
        let state = acknowledged ? (photo ? "眼镜已响应快门。" : "眼镜已停止录像。") : "眼镜没有确认拍照。"
        mediaMessage = "\(state)相册暂未找到新\(kind)。"
        note("拍摄验证：暂未找到新\(kind)原件")
    }

    /// Stops the take when the chosen limit is reached, and shows the countdown in the UI.
    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard maxRecordSeconds > 0, recording else { recordDeadline = nil; return }
        let seconds = maxRecordSeconds
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        recordDeadline = deadline
        note("到 \(seconds) 秒会自动停止")
        autoStopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if !Task.isCancelled, Date() >= deadline, !self.busy, !self.settingsLoading {
                    self.recordDeadline = nil
                    if self.recording {
                        self.note("到时限，自动停止录像")
                        self.toggleRecording()
                    }
                    return
                }
            }
        }
    }

    func capture() {
        Task {
            _ = await withGlassesOperation { active in
                let list = try await onGlassesQueue { try active.captureList() }
                try checkActive(active)
                updateCaptures(list)
                guard let newest = captures.first(where: { $0.isPhoto && !$0.stills.isEmpty }) else {
                    throw LinkError.unexpected("眼镜相册里没有照片")
                }
                return try await downloadCapture(newest, from: active, save: true)
            }
        }
    }

    func refreshStatus() {
        guard canUseGlasses, !statusRefreshing else { return }
        statusRefreshPending = true
        statusMessage = "将在当前眼镜操作结束后读取。"
        startPendingStatusRefresh()
    }

    func refreshVisibleDeviceStatus() {
        guard UIApplication.shared.applicationState == .active, canUseGlasses,
              !busy, !settingsLoading, live == nil, assistantRef == nil else { return }
        refreshStatus()
    }

    private func startPendingStatusRefresh() {
        guard statusRefreshPending, canUseGlasses, let active = session, !busy, !settingsLoading, !albumTransferBatch,
              live == nil, assistantRef == nil else { return }
        statusRefreshPending = false
        statusRefreshing = true
        statusMessage = nil
        busy = true
        note("读取眼镜设备状态")
        Task {
            defer {
                if session === active {
                    statusRefreshing = false
                    busy = false
                    if loadCatalogAfterStatus {
                        loadCatalogAfterStatus = false
                        loadCaptures()
                    } else {
                        runQueuedCameraIfReady()
                    }
                }
            }
            do {
                let current = try await onGlassesQueue { try active.subscribeStatus() }
                try checkActive(active)
                status.mergeReported(from: current)
                if let camera = current.camera {
                    recording = camera == Status.cameraName(Status.videoStarted)
                    if !recording {
                        recordingCatalogBaseline = nil
                        recordDeadline = nil
                        autoStopTask?.cancel()
                        autoStopTask = nil
                    }
                }
            } catch {
                guard session === active else { return }
                statusMessage = Glasses.explain(error)
                note("读取设备状态失败：\(error)")
                if case LinkError.badMAC = error, let p = peripheral {
                    failConnection("设备状态校验失败，正在恢复连接。", peripheral: p)
                }
            }
        }
    }

    // MARK: assistant takeover

    @Published private(set) var assistantOn = false
    @Published private(set) var assistantRegistering = false
    @Published private(set) var assistantMessage: String?
    @Published private(set) var assistantAnswer = ""
    @Published private(set) var assistantTranscriptMissing = false
    private var assistantRef: Assistant?
    private var voiceTurn: String?
    private var submittedVoiceTurn: String?
    private var voiceWait: Task<Void, Never>?
    private var voiceAnswer: Task<Void, Never>?

    var canStartAssistant: Bool {
        canUseGlasses && !busy && !settingsLoading && !recording && live == nil && assistantRef == nil
    }

    private func resetVoiceTurn() {
        voiceWait?.cancel()
        voiceWait = nil
        voiceAnswer?.cancel()
        voiceAnswer = nil
        voiceTurn = nil
        submittedVoiceTurn = nil
        assistantTranscriptMissing = false
    }

    /// svc15 registration: after this the glasses' own wake word routes to this app.
    func startAssistant() {
        guard canStartAssistant, let sess = session else { return }
        guard ModelClient.baseComponents(modelBaseURL) != nil, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            assistantMessage = "请先选择并保存助手模型。"
            return
        }
        let a = Assistant(session: sess)
        note("眼镜语音：用户请求启用，开始注册眼镜语音")
        assistantMessage = "正在等眼镜确认语音注册…"
        assistantAnswer = ""
        assistantRegistering = true
        a.log = { [weak self] line in self?.note("asst: \(line)") }
        a.onTurn = { [weak self, weak a] interaction in
            Task { @MainActor in
                guard let self, let a, self.assistantRef === a, self.voiceTurn != interaction else { return }
                self.resetVoiceTurn()
                self.voiceTurn = interaction
                self.assistantMessage = "已收到眼镜唤醒，等待你说完问题…"
                self.voiceWait = Task { [weak self, weak a] in
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                    guard let self, let a, self.assistantRef === a, self.voiceTurn == interaction else { return }
                    self.assistantTranscriptMissing = true
                    self.assistantMessage = "收到唤醒，但没有收到问题文字。可以再说一次，或直接输入。"
                }
            }
        }
        a.onTranscript = { [weak self, weak a] transcript, interaction in
            Task { @MainActor in
                guard let self, let a, self.assistantRef === a else { return }
                self.answerVoiceQuestion(transcript, interaction: interaction, assistant: a)
            }
        }
        a.onTurnEnded = { [weak self, weak a] interaction in
            Task { @MainActor in
                guard let self, let a, self.assistantRef === a, self.voiceTurn == interaction,
                      self.submittedVoiceTurn != interaction else { return }
                self.voiceWait?.cancel()
                self.assistantTranscriptMissing = true
                self.assistantMessage = "眼镜已结束这轮语音，App 没收到问题文字。"
            }
        }
        a.onAudioWithoutTranscript = { [weak self, weak a] in
            Task { @MainActor in
                guard let self, let a, self.assistantRef === a else { return }
                self.voiceWait?.cancel()
                self.assistantTranscriptMissing = true
                self.assistantMessage = "已收到眼镜的麦克风语音流，未收到转写文字。这轮可以直接打字提问。"
            }
        }
        a.onFailure = { [weak self, weak a] error in
            Task { @MainActor in
                guard let self, let a, self.assistantRef === a else { return }
                self.finishAssistantFailure(error, session: sess)
            }
        }
        assistantRef = a
        busy = true
        Task {
            defer {
                if self.session === sess {
                    self.busy = false
                    self.assistantRegistering = false
                    self.startPendingStatusRefresh()
                }
            }
            do {
                try await onGlassesQueue { try a.register() }
                guard session === sess, assistantRef === a else { return }
                a.startLoop()
                assistantOn = true
                assistantMessage = "眼镜已确认注册。说「Hey Meta」，听到提示后说出问题。"
                note("眼镜确认了助手注册")
            } catch {
                guard session === sess, assistantRef === a else { return }
                finishAssistantFailure(error, session: sess)
            }
        }
    }

    private func finishAssistantFailure(_ error: Error, session active: Session) {
        assistantRef?.stop()
        assistantRef = nil
        assistantOn = false
        assistantRegistering = false
        resetVoiceTurn()
        assistantMessage = "眼镜语音未就绪 · \(Glasses.explain(error))"
        note("眼镜语音故障：\(error)")
        if case LinkError.badMAC = error, let p = peripheral, session === active {
            failConnection("眼镜语音连接校验失败。", peripheral: p)
        } else {
            startPendingStatusRefresh()
        }
    }

    private func answerVoiceQuestion(_ transcript: String, interaction: String, assistant: Assistant) {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, submittedVoiceTurn != interaction else { return }
        if voiceTurn != interaction { resetVoiceTurn() }
        voiceTurn = interaction
        submittedVoiceTurn = interaction
        voiceWait?.cancel()
        assistantTranscriptMissing = false
        assistantAnswer = ""
        let client = configuredModel
        assistantMessage = "已收到问题，正在调用 \(client.model)…"
        note("眼镜语音：已收到转写，开始调用用户配置的模型")
        voiceAnswer = Task { [weak self, weak assistant] in
            guard let self, let assistant else { return }
            let text: String
            do {
                text = try await client.ask(question: "请用简洁的口语回答下面的问题，方便眼镜朗读。当前只收到文字，没有图片。\n\n\(question)")
            } catch {
                guard !Task.isCancelled, self.assistantRef === assistant, self.voiceTurn == interaction else { return }
                self.assistantMessage = "模型请求失败 · \(Glasses.explain(error))"
                self.note("眼镜语音的模型请求失败")
                return
            }
            guard !Task.isCancelled, self.assistantRef === assistant, self.voiceTurn == interaction else { return }
            self.assistantAnswer = text
            do {
                try await self.onGlassesQueue {
                    try assistant.complete(interaction: interaction, text: text, transcript: question)
                }
                guard !Task.isCancelled, self.assistantRef === assistant, self.voiceTurn == interaction else { return }
                self.assistantMessage = "模型已回复，已将回答发给眼镜。"
                self.note("将模型回复发给眼镜")
            } catch {
                guard !Task.isCancelled, self.assistantRef === assistant, self.voiceTurn == interaction else { return }
                self.assistantMessage = "模型已回复，眼镜播报发送失败 · \(Glasses.explain(error))"
            }
        }
    }

    func stopAssistant() {
        guard let assistantRef else { return }
        assistantRef.stop()
        self.assistantRef = nil
        assistantOn = false
        resetVoiceTurn()
        reconnect(forRegistration: false)
        note("助手接管已关闭")
    }

    // MARK: live

    func startLive() {
        guard canUseGlasses, let sess = session, !busy, !settingsLoading,
              !recording, live == nil, assistantRef == nil else { return }
        let l = LiveStream(session: sess)
        l.log = { [weak self] line in self?.note("live: \(line)") }
        l.onPhase = { [weak self] phase in
            self?.note("live phase: \(phase.rawValue)")
            if phase == .failed { self?.liveLine = "失败" }
        }
        l.onPhoto = { [weak self] photo in
            guard let self else { return }
            if let img = UIImage(data: photo.data) {
                self.lastPhoto = photo.data
                self.saveToPhotos(photo.data)
                self.note("接收取景快照 \(photo.data.count)B")
                _ = img
            } else {
                self.note("live 快照 \(photo.data.count)B，系统解不了（\(photo.isHeic ? "HEIC" : "未知")）")
            }
        }
        live = l
        l.start()
        // One second of stats into the overlay line; the stream itself runs on its own thread.
        liveTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let l = self.live else { return }
            self.liveLine = "\(l.phase.rawValue) \(l.framesPerSecond)fps \(l.kbitPerSecond)kbit/s "
                + "\(l.frames)帧" + (l.decodedSize.map { " \(Int($0.width))x\(Int($0.height))" } ?? "")
        }
    }

    func stopLive() {
        guard let live else { return }
        liveTicker?.invalidate()
        liveTicker = nil
        self.live = nil
        liveLine = "—"
        guard live.phase != .failed, live.phase != .idle else {
            startPendingStatusRefresh()
            return
        }
        live.stop()
        reconnect(forRegistration: false)
    }

    func shareVideo() {
        guard let url = lastVideoURL else { note("还没有视频"); return }
        share = ShareBox(url: url)
    }

    func readAudioOutput() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let route = outputs.map { $0.portType == .builtInSpeaker ? "iPhone 扬声器" : $0.portName }
            .joined(separator: "、")
        audioRouteName = route.isEmpty ? "未检测到媒体输出" : route
        audioRouteUsesBluetooth = outputs.contains {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
        let activeType = outputs.first?.portType
        switch activeType {
        case .bluetoothA2DP: audioMediaProfile = "蓝牙立体声 · A2DP"
        case .bluetoothHFP: audioMediaProfile = "蓝牙通话模式 · HFP"
        case .bluetoothLE: audioMediaProfile = "蓝牙 LE 音频"
        default: audioMediaProfile = nil
        }
    }

    var canRequestGlassesAudioConnection: Bool {
        canUseGlasses && !phaseBusy && !busy && !settingsLoading && !recording && !albumTransferBatch
            && live == nil && assistantRef == nil
    }

    func requestGlassesAudioConnection() {
        guard canRequestGlassesAudioConnection else { return }
        UserDefaults.standard.set(true, forKey: "requestedGlassesAudioBridging")
        note("音频：已请求 iOS 接通眼镜的经典蓝牙音频")
        reconnect(forRegistration: false)
    }

    func beginVideoPlayback() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
        readAudioOutput()
    }

    func endVideoPlayback() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        readAudioOutput()
    }

    // MARK: thumbnails (kept on disk so the album works offline)

    private static var thumbDir: URL? {
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Caches a small preview of an imported asset, so the album shows real pictures
    /// instead of placeholders — and keeps working with the glasses out of range.
    func rememberThumb(_ id: String, _ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let small = image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image
        thumbs[id] = small
        if let dir = Self.thumbDir,
           let jpeg = small.jpegData(compressionQuality: 0.7) {
            try? jpeg.write(to: dir.appendingPathComponent(Self.safeName(id) + ".jpg"))
        }
    }

    func loadThumbs() {
        guard let dir = Self.thumbDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" {
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            thumbs[file.deletingPathExtension().lastPathComponent] = image
        }
    }

    private static func safeName(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private func saveToPhotos(_ data: Data) {
        Task {
            do {
                try await persistCapture(data, isPhoto: true)
            } catch {
                note("存相册失败：\(error)")
            }
        }
    }

    private func persistCapture(_ data: Data?, isPhoto: Bool, original: URL? = nil) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw LinkError.io("请允许 GlassesLink 添加到 iPhone 相册。")
        }
        if let original {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: isPhoto ? .photo : .video,
                                                              fileURL: original, options: nil)
            }
        } else if let data, isPhoto {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        } else if let data {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: file) }
            try await onGlassesQueue { try data.write(to: file, options: .atomic) }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
            }
        } else {
            throw LinkError.io("找不到要保存的原件。")
        }
        note("已保存到 iPhone 相册")
    }

    /// Poster frame for a clip, using the first decodable frame.
    func rememberVideoThumb(_ id: String, _ url: URL) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 336, height: 336)
        Task {
            guard let first = try? await gen.image(at: .zero) else { return }
            let ui = UIImage(cgImage: first.image)
            thumbs[id] = ui
            if let dir = Self.thumbDir, let jpeg = ui.jpegData(compressionQuality: 0.7) {
                try? jpeg.write(to: dir.appendingPathComponent(Self.safeName(id) + ".jpg"), options: .atomic)
            }
        }
    }

    // MARK: ask your own model
    private var configuredModel: ModelClient {
        ModelClient(baseURL: modelBaseURL, model: modelName, apiKey: ModelCredentials.read(for: modelBaseURL))
    }

    func saveModelSettings(baseURL: String, model: String, key: String) throws {
        guard let address = ModelClient.baseComponents(baseURL)?.string else {
            throw LinkError.io("请填写有效的服务地址。")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LinkError.io("请填写模型 ID。") }
        try ModelCredentials.save(key, for: address)
        UserDefaults.standard.removeObject(forKey: "modelKey")
        modelBaseURL = address
        modelName = model
        UserDefaults.standard.set(address, forKey: "modelBaseURL")
        UserDefaults.standard.set(model, forKey: "modelName")
    }

    func testModel() {
        guard !testingModel else { return }
        let client = configuredModel
        testingModel = true
        modelTestLine = ""
        Task {
            defer { testingModel = false }
            let started = Date()
            do {
                let raw = try await client.ping()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let snippet = raw.replacingOccurrences(of: "\n", with: " ").prefix(60)
                modelTestOK = true
                modelTestLine = "通了 · \(ms) ms · \(snippet)"
            } catch {
                modelTestOK = false
                modelTestLine = "失败：\(error)"
            }
        }
    }

    var hasPhotoForModel: Bool { lastPhoto != nil || latestLocalPhoto != nil }

    private var latestLocalPhoto: URL? {
        guard let capture = localCaptures.filter(\.isPhoto).max(by: { ($0.timestampNS ?? 0) < ($1.timestampNS ?? 0) }) else {
            return nil
        }
        return localMediaURL(for: capture)
    }

    func ask(_ question: String, includePhoto: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !askingModel, !question.isEmpty else { return }
        let photo = includePhoto ? lastPhoto : nil
        let photoURL = includePhoto && photo == nil ? latestLocalPhoto : nil
        let client = configuredModel
        askingModel = true
        answer = ""
        Task {
            defer { askingModel = false }
            do {
                let image: Data?
                if let photoURL {
                    image = try await Task.detached { try Data(contentsOf: photoURL) }.value
                } else {
                    image = photo
                }
                if includePhoto && image == nil { throw LinkError.io("请先在相册导入一张照片。") }
                answer = try await client.ask(question: question, image: image)
            } catch {
                answer = "模型调用失败 · \(Glasses.explain(error))"
            }
        }
    }

    // MARK: provisioning (no Android, no PC)

    var canStartOwnerRegistration: Bool {
        connected && channel != nil && session != nil && ownerState == .unverified
            && !busy && !ownerRegistrationCompleted
    }

    func becomeOwner(userToken: String) {
        guard canStartOwnerRegistration, let sess = session else {
            registrationMessage = "设置连接已断开，请重新连接眼镜后再登录。"
            if let registrationMessage { note(registrationMessage) }
            return
        }
        let key = sess.owner
        busy = true
        registrationMessage = "正在注册眼镜。需要确认时，App 会提示你按拍摄键。"
        Task {
            defer { busy = false }
            do {
                let bundle = try await Provisioner.becomeOwner(session: sess, owner: key,
                                                               userToken: userToken,
                                                               log: { [weak self] line in
                    self?.note(line)
                    if line.contains("请按一下"), line.contains("拍摄键") {
                        Task { @MainActor [weak self] in
                            self?.registrationMessage = "请按一下眼镜上的拍摄键。"
                        }
                    }
                })
                owner = key
                ownerRegistrationCompleted = session === sess
                UserDefaults.standard.set(true, forKey: "isOwner")
                ownerLine = "owner key: 已注册 · serial \(bundle.serial)"
                registrationMessage = "注册已完成。请重新连接并验证主人身份。"
                note("主人注册已完成，接下来重新连接验证")
            } catch {
                registrationMessage = "注册失败。\(Glasses.explain(error))"
                note("❌ 改 owner 失败：\(error)")
            }
        }
    }

    // MARK: export

    /// Short, stable identifier for the key currently loaded — so the user can see *which* key it is.
    var ownerFingerprint: String {
        guard let o = owner else { return "没有钥匙" }
        let xy = o.publicKeyXy
        let tail = xy.suffix(6).map { String(format: "%02x", $0) }.joined()
        return "公钥尾号 \(tail)（\(xy.count) 字节）"
    }

    /// Copies an owner bundle picked in the Files app into Documents, then loads it.
    @discardableResult
    func importOwner(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            return adopt(data, source: "文件")
        } catch {
            note("读文件失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Same as the file importer, but from text the user pasted into a field.
    @discardableResult
    func importOwner(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { note("没有内容可导入"); return false }
        return adopt(Data(trimmed.utf8), source: "粘贴")
    }

    func importOwnerFromPasteboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            note("剪贴板里没有文字——先把 owner-export.json 的内容复制下来")
            return
        }
        importOwner(text: text)
    }

    /// Parses, normalises and stores; returns false (with a log line) when the blob is not a key.
    private func adopt(_ data: Data, source: String) -> Bool {
        guard let temp = try? writeTemp(data),
              let parsed = try? OwnerMaterial.loadAny(from: temp) else {
            note("导入失败：内容不是 owner key（要含 publicKeyXy 与 privateKeyPkcs8）")
            return false
        }
        do {
            let normalised = try JSONEncoder().encode(parsed.1)
            try normalised.write(to: OwnerMaterial.defaultURL, options: .atomic)
            try parsed.0.saveToKeychain()
            owner = parsed.0
            ownerState = .unverified
            UserDefaults.standard.set(false, forKey: "isOwner")
            UserDefaults.standard.set("unverified", forKey: "ownerState")
            UserDefaults.standard.removeObject(forKey: "ownerStateAt")
            ownerLine = "owner key: 已导入 \(parsed.1.serial) · \(ownerFingerprint)"
            note("已从\(source)导入 \(parsed.1.serial) 的 owner key · \(ownerFingerprint)")
            trustLine = "未验证（钥匙已就位，连接一次看结果）"
            route = nil
            return true
        } catch {
            note("导入失败：\(error.localizedDescription)")
            return false
        }
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-owner.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func shareOwner() {        let url = OwnerMaterial.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            note("还没有 owner-export.json（provision 成功后才会有）")
            return
        }
        share = ShareBox(url: url)
    }

    func shareLog() {
        share = ShareBox(url: logURL)
    }

    /// Copies the log to the pasteboard so it can be pasted into a chat in one step.
    func copyLog() {
        UIPasteboard.general.string = diagnosticBundle()
        note("诊断包已复制到剪贴板（\(log.count) 行日志 + 环境信息）")
    }

    /// Everything needed to explain a failed trust without another round trip: what build
    /// is running, which key the phone claims, and the last frames it saw.
    func diagnosticBundle() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var out: [String] = []
        out.append("GlassesLink \(v) (\(b)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        if let k = owner {
            out.append("owner pubkey(SHA256) \(Data(SHA256.hash(data: k.publicKeyXy)).hexShort)")
            out.append("owner source \(ownerLine)")
        } else {
            out.append("owner 无")
        }
        out.append("trust \(trustLine)")
        out.append("link \(glassesLine)")
        out.append("--- log ---")
        out.append(contentsOf: log.reversed())
        return out.joined(separator: "\n")
    }

    // MARK: settings (svc33)

    /// Reads the whole settings namespace once and keeps it keyed by setting name.
    func loadSettings() {
        guard canUseGlasses, let sess = session, !busy, !settingsLoading,
              live == nil, assistantRef == nil else {
            return
        }
        settingsLoading = true
        glassesQueue.async { [weak self] in
            do {
                let objects = try sess.driveObjects()
                var map: [String: String] = [:]
                for object in objects where object.type == Drive.kv && !object.deleted {
                    map[object.uri] = object.data
                }
                DispatchQueue.main.async {
                    guard let self, self.session === sess else { return }
                    self.settings = map
                    self.settingsLoading = false
                    self.note("设置：读到 \(map.count) 项")
                    self.startPendingStatusRefresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.session === sess else { return }
                    self.settingsLoading = false
                    self.reportOperationError(error, session: sess)
                    self.startPendingStatusRefresh()
                }
            }
        }
    }

    /// Writes one setting and only reports success if the read-back agrees.
    func writeSetting(_ key: String, _ value: String) {
        guard canUseGlasses, let sess = session, !busy, !settingsLoading,
              live == nil, assistantRef == nil else {
            note("先连接眼镜，再改设置")
            return
        }
        note("写 \(key) = \(value)")
        let schema = SettingsSchemaTable.schema(key)
        settingsLoading = true
        glassesQueue.async { [weak self] in
            do {
                // Firmware-parsed settings go over svc31; the rest live in RLDrive.
                // Either way the write is only trusted once a read comes back equal.
                var ok = false
                if let schema, !schema.viaDrive {
                    let sent = try sess.writeSettingsField(schema, value: value)
                    if sent {
                        // Read-back is only meaningful where RLDrive mirrors the same key.
                        let after = try sess.driveObjects()
                        let mirrored = after.first { $0.uri == key }
                        ok = mirrored?.data == value
                    }
                } else {
                    ok = try sess.driveWrite(key: key, value: value)
                }
                DispatchQueue.main.async {
                    guard let self, self.session === sess else { return }
                    self.settingsLoading = false
                    if ok {
                        self.settings[key] = value
                        self.note("\(key) 已生效")
                    } else {
                        self.note("\(key) 写进去了但读回不一致（固件可能拒收）")
                    }
                    self.startPendingStatusRefresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.session === sess else { return }
                    self.settingsLoading = false
                    self.reportOperationError(error, session: sess)
                    self.startPendingStatusRefresh()
                }
            }
        }
    }
}

// MARK: - CoreBluetooth

extension Glasses: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn:
                discoveryMessage = nil
                note("蓝牙就绪")
                autoReconnect()
            case .unauthorized, .poweredOff, .unsupported:
                stopScan()
                resetRecovery()
                reconnectAfterDisconnect = nil
                clearLink()
                discoveryMessage = bluetoothUnavailableMessage
                phase = .failed(bluetoothUnavailableMessage)
                glassesLine = bluetoothUnavailableMessage
                note(bluetoothUnavailableMessage)
            default: note("central state \(c.state.rawValue)")
            }
        }
    }

    /// iOS relaunches us in the background with the old central; take the peripheral back.
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return
        }
        Task { @MainActor in
            guard !connecting, channel == nil else { return }
            guard restored.identifier == savedGlassesID, !autoReconnectSuppressed else { return }
            peripheral = restored
            if c.state == .poweredOn { autoReconnect() }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peripheralName = ScanEntry.usableName(p.name)
        let localName = ScanEntry.usableName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        // Bluetooth SIG company allocations identify candidates. The session verifies the device separately.
        let hasMetaManufacturer = manufacturerData?.prefix(2).elementsEqual([0xAB, 0x01]) ?? false
        let hasMetaService = (services + overflow + Array(serviceData.keys)).contains {
            $0.uuidString == "FD5F" || $0.uuidString == Self.metaService
        }
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue != false
        let candidate = hasMetaService || hasMetaManufacturer || ScanEntry.matchesRayBanMetaName(peripheralName)
            || ScanEntry.matchesRayBanMetaName(localName)
        let id = p.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard self.scanning else { return }
            let index = self.devices.firstIndex { $0.id == id }
            let previous = index.map { self.devices[$0] }
            let verifiedName = self.verifiedPeripheralNames[id.uuidString]
            guard isConnectable, candidate || previous?.isVisibleCandidate == true || verifiedName != nil else {
                self.ignoredAdvertisers.insert(id)
                return
            }
            self.discoveredPeripherals[id] = p
            self.sawGlassesAdvertisement = self.sawGlassesAdvertisement || candidate || verifiedName != nil
            self.ignoredAdvertisers.remove(id)
            let entry = ScanEntry(id: id, peripheralName: peripheralName ?? previous?.peripheralName,
                                  verifiedName: verifiedName, advertisementName: localName ?? previous?.advertisementName,
                                  rssi: rssi, isGlasses: candidate || previous?.isGlasses == true,
                                  isVerified: verifiedName != nil, source: previous?.source ?? .advertisement)
            if let index, let previous {
                if entry.peripheralName != previous.peripheralName || entry.advertisementName != previous.advertisementName
                    || entry.isGlasses != previous.isGlasses || entry.isVerified != previous.isVerified
                    || entry.signalLabel != previous.signalLabel { self.devices[index] = entry }
            } else {
                self.devices.append(entry)
                self.note("找到蓝牙候选：\(entry.displayName)")
            }
        }
    }

    nonisolated func peripheralDidUpdateName(_ p: CBPeripheral) {
        Task { @MainActor in
            guard canUseGlasses, peripheral?.identifier == p.identifier else { return }
            rememberVerifiedPeripheral(p)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            self.openLink(p)
        }
    }

    private func openLink(_ p: CBPeripheral) {
        guard connectingID == p.identifier, connectionAttempt != nil,
              reconnectAfterDisconnect == nil, channel == nil, !openingL2CAP,
              p.state == .connected else { return }
        openingL2CAP = true
        note("打开 L2CAP PSM 0x\(String(psm, radix: 16))")
        p.openL2CAPChannel(psm)
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard self.peripheral?.identifier == p.identifier, p.state == .disconnected else { return }
            if let reconnect = self.reconnectAfterDisconnect, reconnect.id == p.identifier {
                self.reconnectAfterDisconnect = nil
                self.clearLink()
                self.beginConnection(reconnect.id, forRegistration: reconnect.forRegistration)
            } else if self.channel != nil || self.connecting {
                self.failConnection("眼镜蓝牙已断开。", peripheral: p, underlying: error)
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard self.connectingID == p.identifier, p.state == .disconnected else { return }
            let reason = error?.localizedDescription ?? "蓝牙连接未建立"
            self.failConnection("连接失败：\(reason)", peripheral: p)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in p.services ?? [] { self.note("service \(s.uuid)") }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        Task { @MainActor in
            guard self.connectingID == p.identifier, let attempt = self.connectionAttempt,
                  self.reconnectAfterDisconnect == nil, self.channel == nil, p.state == .connected else {
                channel?.inputStream?.close()
                channel?.outputStream?.close()
                return
            }
            self.openingL2CAP = false
            guard let ch = channel else {
                let reason = error?.localizedDescription ?? "蓝牙通道未建立"
                if reason.localizedCaseInsensitiveContains("already connected"), !self.retriedL2CAP {
                    self.retriedL2CAP = true
                    self.note("蓝牙通道仍被占用，准备重试一次")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if self.connectionAttempt == attempt { self.openLink(p) }
                } else {
                    self.failConnection("L2CAP 打开失败：\(reason)", peripheral: p)
                }
                return
            }
            self.channel = ch
            self.connecting = false
            self.connectionAttempt = nil
            self.note("L2CAP up psm=0x\(String(ch.psm, radix: 16))")
            self.phase = .handshaking
            let requireTrust = self.owner != nil && !self.connectingForRegistration
            await self.bringUp(trust: requireTrust)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didClose channel: CBL2CAPChannel?,
                                error: Error?) {
        Task { @MainActor in
            guard let channel, self.channel === channel else { return }
            self.failConnection("眼镜蓝牙数据通道已关闭。", peripheral: p, underlying: error)
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var g: Glasses
    @ObservedObject private var logStore = LogStore.shared
    @State private var question = "我面前有什么？有台阶或障碍物吗？"
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var showImport = false
    @State private var showLive = false
    @State private var showQuick = false
    @State private var verboseLog = false

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Text(g.ownerLine).font(.footnote)
                    Text(g.glassesLine).font(.footnote).foregroundStyle(.secondary)
                }

                Section("1 · 连眼镜") {
                    Button("从系统已配对里找（不用扫描）") { g.loadSystemPaired() }
                    Button("扫描附近眼镜（6 轮）") { g.startScan() }
                    Button("断开（点不动或报 PSM 已占用时用）") { g.disconnect() }
                    ForEach(g.devices, id: \.id) { d in
                        Button {
                            g.connect(d.id)
                        } label: {
                            HStack {
                                if d.isGlasses { Image(systemName: "eyeglasses") }
                                Text(d.displayName)
                                Spacer()
                                Text("\(d.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(d.isGlasses ? Color.accentColor : .secondary)
                            }
                        }
                    }
                    Text("这里只列出眼镜候选和已知设备。找不到眼镜时，等指示灯闪蓝后再扫描。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重新握手（setup 链路，不验 owner）") { g.connectSetup() }
                    Toggle("详细日志（抓完整帧，排查用）", isOn: $verboseLog)
                        .onChange(of: verboseLog) { _, on in Session.verbose = on }
                    Text("打开后每帧最多记 512 字节十六进制；连不上或掉线时打开，再「复制全部」发我。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("2 · 自检（不用连眼镜也能跑）") {
                    Button("跑一遍密钥 / 签名 / ECDH 自检") { g.runSelfTest() }
                    Text("结果会写进下面的日志；连不上眼镜时先看这里，能分清是手机这套密码学的问题还是链路的问题。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("3 · 成为主人（只做一次）") {
                    Button("用 Meta 账号登录并注册这台 iPhone") { showLogin = true }
                    Text("登录在 app 内完成；token 只用来给眼镜签一张 ownership receipt。"
                         + "成功后 owner-export.json 会弹出来，务必存到 iCloud。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("导出 owner-export.json") { g.shareOwner() }
                    Button("从文件 App 导入 owner-export.json") { showImport = true }
                }

                Section("3.5 · 相册 / 拍照") {
                    HStack {
                        Button(g.busy ? "处理中…" : "刷新清单") { g.loadCaptures() }
                            .disabled(!g.connected || g.busy)
                        Spacer()
                        Button(g.busy ? "处理中…" : "拉最新照片") { g.capture() }
                            .disabled(!g.connected || g.busy)
                    }
                    Button(g.busy ? "处理中…" : "按眼镜快门拍一张") { g.snap() }
                        .disabled(!g.connected || g.busy)
                    Button(g.recording ? "停止录像" : "开始录像") { g.toggleRecording() }
                        .disabled(!g.connected || g.busy)
                        .tint(g.recording ? .red : .accentColor)
                    ForEach(g.captures, id: \.handle) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.isPhoto ? "照片" : "视频") · \(item.assets.count) 个资产")
                                Text(item.handle).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let ns = item.timestampNS {
                                    Text(Date(timeIntervalSince1970: Double(ns) / 1e9)
                                        .formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("取回") { g.fetch(item, saveToLibrary: item.isPhoto) }
                                .disabled(g.busy)
                        }
                    }
                    if let d = g.lastPhoto, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                    if g.lastVideoURL != nil {
                        Button("分享视频") { g.shareVideo() }
                    }
                }

                Section("设备状态") {
                    ForEach(g.status.lines, id: \.self) { line in
                        Text(line).font(.footnote)
                    }
                    Button("刷新状态") { g.refreshStatus() }.disabled(!g.connected)
                }

                Section("3.5 · 快捷") {
                    Button("常用开关（助手 / 提示音 / 画质）") { showQuick = true }
                        .disabled(!g.connected)
                }

                Section("4 · Live 取景") {
                    Button(g.live == nil ? "打开取景" : "取景中…") { showLive = true }
                        .disabled(!g.connected)
                    if let size = g.live?.decodedSize {
                        Text("\(Int(size.width))×\(Int(size.height))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("5 · 问自己的模型") {
                    TextField("base URL", text: $g.modelBaseURL)
                        .textInputAutocapitalization(.never).font(.footnote)
                    TextField("model", text: $g.modelName).font(.footnote)
                    TextField("问题", text: $question, axis: .vertical).lineLimit(1 ... 3)
                    Button("看图问答") { g.ask(question, includePhoto: true) }.disabled(!g.hasPhotoForModel || g.askingModel)
                    if !g.answer.isEmpty { Text(g.answer).font(.callout) }
                }

                Section("5.5 · 助手接管（Hey Meta 走这个 app）") {
                    Button(g.assistantOn ? "关闭接管" : "开启接管") {
                        if g.assistantOn { g.stopAssistant() } else { g.startAssistant() }
                    }
                    .disabled(!g.connected)
                    Text("开启后眼镜的唤醒词会路由到这里，由你自己配的模型回答。语音转写还在做，现在是先接住这一轮再回一句话。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("6 · 眼镜设置（\(SettingsCatalog.all.count) 项）") {
                    Button("打开设置") { showSettings = true }
                        .disabled(!g.connected)
                    Text(g.settingsLoading ? "读取中…" : "已读到 \(g.settings.count) 项")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("日志") {
                    HStack {
                        Button("导出日志文件") { g.shareLog() }
                        Spacer()
                        Button("复制全部") { g.copyLog() }
                    }
                    // A wall of text is not a log viewer. Newest 12 lines inline, the rest behind
                    // one disclosure, and the count in the header so you know what you're hiding.
                    if logStore.lines.isEmpty {
                        Text("还没有日志").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(logStore.lines.prefix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                        }
                        if logStore.lines.count > 12 {
                            DisclosureGroup("更早的 \(logStore.lines.count - 12) 行") {
                                ForEach(Array(logStore.lines.dropFirst(12).enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11, design: .monospaced))
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Glasses")
            .sheet(isPresented: $showLogin) {
                LoginWebView(url: Meta.authorize(state: UUID().uuidString),
                             onCode: { code in
                                 showLogin = false
                                 g.note("拿到 code，交换 token…")
                                 Task {
                                     do {
                                         let token = try await MetaClient(log: { g.note($0) })
                                             .exchangeCode(code)
                                         g.becomeOwner(userToken: token)
                                     } catch {
                                         g.note("token 交换失败：\(error)")
                                     }
                                 }
                             },
                             onCancel: { showLogin = false })
            }
            .sheet(item: $g.share) { box in ActivityView(url: box.url) }
            .sheet(isPresented: $showSettings) { SettingsView(g: g) }
            .sheet(isPresented: $showLive) { LiveView(g: g) }
            .sheet(isPresented: $showQuick) { NavigationStack { QuickPanel(g: g) } }
            .sheet(isPresented: $g.showSelfTest) { SelfTestView(g: g) }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .data]) { result in
                switch result {
                case .success(let url): g.importOwner(from: url)
                case .failure(let error): g.note("选文件失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
