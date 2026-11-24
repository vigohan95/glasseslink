// App.swift — the iPhone talks to the glasses by itself.
//
//   scan → connect → L2CAP(PSM 128) → AirShield handshake
//        → (once) become owner via svc36 + Meta   → afterwards: trust
//        → capture list → pull newest photo over the encrypted link
//        → ask your own model about it (any OpenAI-compatible endpoint)

import SwiftUI
import CoreBluetooth
import Photos
import UIKit
import UniformTypeIdentifiers

@main
struct GlassesApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
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

// MARK: - link controller

@MainActor
final class Glasses: NSObject, ObservableObject {
    @Published var log: [String] = []
    @Published var devices: [(id: UUID, name: String)] = []
    @Published var connected = false
    @Published var busy = false
    @Published var ownerLine = "owner key: 未知"
    @Published var glassesLine = "未连接"
    @Published var lastPhoto: Data?
    @Published var answer = ""
    @Published var share: ShareBox?

    @Published var modelBaseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? "http://192.168.3.90:11434/v1"
    @Published var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "gemma3:4b"
    @Published var settings: [String: String] = [:]
    @Published var settingsLoading = false
    @Published var status = GlassesState()
    @Published var captures: [Capture] = []
    @Published var recording = false
    @Published var lastVideo: Data?
    @Published var live: LiveStream?
    @Published var liveLine = "—"
    private var liveTicker: Timer?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var stream: SDUStream?
    private var session: Session?
    private var owner: OwnerMaterial?

    /// Ray-Ban Meta Gen 2 exposes its link on L2CAP PSM 0x80.
    let psm: CBL2CAPPSM = 0x80

    var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("glasses.log")
    }

    override init() {
        super.init()
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
        note("启动。owner=\(owner == nil ? "无" : "有")")
    }

    /// Runs the checks that only this phone can answer (key import, both signing paths,
    /// ECDH) and pushes every line into the log so it can be shared after a failed connect.
    func runSelfTest() {
        let lines = SelfTest.run()
        note("—— 自检开始 ——")
        for l in lines { note("\(l.ok ? "✓" : "✗") \(l.text)") }
        let bad = lines.filter { !$0.ok }.count
        note("—— 自检结束：\(lines.count) 项，失败 \(bad) ——")
    }

    // MARK: logging (kept on disk so it can be shared from the phone)

    func note(_ s: String) {
        let line = "\(Self.ts()) \(s)"
        log.insert(line, at: 0)
        if log.count > 500 { log.removeLast() }
        if let d = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: logURL)
            }
        }
        print(line)
    }

    static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    // MARK: scan / connect

    func startScan() {
        guard central.state == .poweredOn else { note("蓝牙不可用：\(central.state.rawValue)"); return }
        devices.removeAll()
        note("扫描中…眼镜展开、靠近手机")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("找不到这台设备（先扫描）"); return
        }
        central.stopScan()
        peripheral = p
        p.delegate = self
        UserDefaults.standard.set(id.uuidString, forKey: "lastPeripheral")
        note("连接 \(p.name ?? "?") …")
        central.connect(p, options: nil)
    }

    /// The glasses stay paired at the iOS level, so a cold launch can go straight back to
    /// the same peripheral without scanning — that is what makes "打开就能用" work.
    func autoReconnect() {
        guard central.state == .poweredOn else { return }
        guard let saved = UserDefaults.standard.string(forKey: "lastPeripheral"),
              let id = UUID(uuidString: saved) else { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("上次的眼镜现在不在系统里，点「扫描」一次")
            return
        }
        peripheral = p
        p.delegate = self
        note("自动连接上次的眼镜 \(p.name ?? saved) …")
        central.connect(p, options: nil)
    }

    // MARK: link bring-up

    private func bringUp(trust: Bool) async {
        guard let ch = channel else { note("没有 L2CAP 通道"); return }
        let s = SDUStream(channel: ch)
        s.onLog = { [weak self] in self?.note($0) }
        stream = s
        guard let own = owner else {
            note("没有 owner key：这条链路只能用来跑「成为主人」")
            return
        }
        let sess = Session(stream: s, owner: own, log: { [weak self] in self?.note($0) })
        session = sess
        do {
            try sess.handshake(trust: trust)
            connected = true
            if trust { UserDefaults.standard.set(true, forKey: "isOwner") }
            glassesLine = "已连上 · trust=\(trust) · serial \(sess.peerSerial)"
            note("✅ 握手完成")
        } catch {
            note("❌ 握手中断：\(error)")
            glassesLine = "握手失败：\(error)"
        }
    }

    /// Connect without proving ownership — used before the first provisioning.
    func connectSetup() { Task { await bringUp(trust: false) } }

    /// Normal connect: prove we hold the owner key.
    func connectTrusted() { Task { await bringUp(trust: true) } }

    // MARK: capture

    func loadCaptures() {
        guard let sess = session else { note("先连接"); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let caps = try sess.captureList()
                captures = caps.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
                note("清单 \(caps.count) 条")
            } catch {
                note("读清单失败：\(error)")
            }
        }
    }

    /// Pulls one capture's best asset: the still for a photo, the first video asset otherwise.
    func fetch(_ captureItem: Capture, saveToLibrary: Bool) {
        guard let sess = session else { note("先连接"); return }
        let asset = captureItem.isPhoto
            ? (captureItem.stills.first ?? captureItem.assets.first)
            : (captureItem.assets.first { $0.type == 1 } ?? captureItem.assets.first)
        guard let asset else {
            note("这条没有可传的资产")
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                note("拉取 \(captureItem.handle) / \(asset.uuid)（\(asset.size)B）")
                try sess.requestAsset(handle: captureItem.handle, assetID: asset.uuid)
                guard let transfer = try sess.receiveFile(timeout: 300) else {
                    note("没收到文件（对端没发起传输）")
                    return
                }
                note("收到 \(transfer.name) \(transfer.size)B")
                if transfer.data.prefix(2) == Data([0xFF, 0xD8]) {
                    lastPhoto = transfer.data
                    if saveToLibrary { saveToPhotos(transfer.data) }
                } else {
                    lastVideo = transfer.data
                    note("视频已收到，用「分享视频」导出")
                }
            } catch {
                note("取文件失败：\(error)")
            }
        }
    }

    /// Press the glasses' shutter, then pull whatever landed. The glasses take a
    /// second or two to write the file, so this waits before asking for the list.
    func snap() {
        guard let sess = session else { note("先连接"); return }
        busy = true
        Task {
            do {
                try sess.shutterPhoto()
                note("已按快门，等眼镜写文件…")
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                busy = false
                capture()
            } catch {
                busy = false
                note("快门失败：\(error)")
            }
        }
    }

    /// Start or stop a recording through the same SNIntent path Visor uses.
    /// On stop it waits for the file and pulls it, like the photo path.
    func toggleRecording() {
        guard let sess = session else { note("先连接"); return }
        let wasRecording = recording
        busy = true
        Task {
            do {
                if wasRecording {
                    try sess.stopVideo()
                    note("已发停止录像，等眼镜收尾…")
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    recording = false
                    busy = false
                    loadCaptures()
                } else {
                    try sess.startVideo()
                    note("已发开始录像")
                    recording = true
                    busy = false
                }
            } catch {
                busy = false
                note("录像控制失败：\(error)")
            }
        }
    }

    func capture() {
        guard let sess = session else { note("先连接"); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let caps = try sess.captureList()
                note("清单 \(caps.count) 条")
                captures = caps.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
                guard let newest = caps.filter({ $0.isPhoto })
                        .max(by: { ($0.timestampNS ?? 0) < ($1.timestampNS ?? 0) }),
                      let still = newest.stills.first else {
                    note("清单里没有照片资产")
                    return
                }
                note("拉取 \(newest.handle) / \(still.uuid) (\(still.size)B)")
                try sess.requestAsset(handle: newest.handle, assetID: still.uuid)
                if let t = try sess.receiveFile() {
                    lastPhoto = t.data
                    note("收到 \(t.name) \(t.size)B")
                    saveToPhotos(t.data)
                } else {
                    note("没收到文件（对端没发起传输）")
                }
            } catch {
                note("取图失败：\(error)")
            }
        }
    }

    func refreshStatus() {
        guard let sess = session else { note("先连接"); return }
        Task {
            do {
                let s = try sess.subscribeStatus()
                status = s
                if s.lines.isEmpty { note("状态：眼镜没回设备状态") }
            } catch {
                note("状态读取失败：\(error)")
            }
        }
    }

    // MARK: assistant takeover

    @Published var assistantOn = false
    private var assistantRef: Assistant?

    /// svc15 registration: after this the glasses' own wake word routes to this app.
    func startAssistant() {
        guard let sess = session else { note("先连接"); return }
        guard assistantRef == nil else { return }
        let a = Assistant(session: sess)
        a.log = { [weak self] line in self?.note("asst: \(line)") }
        a.onTurn = { [weak self] interaction in
            guard let self else { return }
            let client = ModelClient(baseURL: self.modelBaseURL, model: self.modelName)
            Task {
                let q = "用户刚唤醒智能眼镜。只用一句不超过 20 字的简体中文回应用户。"
                let text = (try? await client.ask(question: q, jpeg: Data())) ?? "我在。"
                a.complete(interaction: interaction, text: text)
            }
        }
        // The glasses' own speech recognition finished a sentence: answer it with the model.
        a.onTranscript = { [weak self] transcript, interaction in
            guard let self else { return }
            let client = ModelClient(baseURL: self.modelBaseURL, model: self.modelName)
            Task {
                let q = "用户戴着智能眼镜说：“\(transcript)”。用不超过 40 字的简体中文直接回答，不用复述问题。"
                let text = (try? await client.ask(question: q, jpeg: Data())) ?? "我没听清，再说一遍？"
                a.complete(interaction: interaction, text: text)
            }
        }
        do {
            try a.register()
            a.startLoop()
            assistantRef = a
            assistantOn = true
            note("助手接管已开启")
        } catch {
            note("助手接管失败：\(error)")
        }
    }

    func stopAssistant() {
        assistantRef?.stop()
        assistantRef = nil
        assistantOn = false
        note("助手接管已关闭")
    }

    // MARK: live

    func startLive() {
        guard let sess = session else { note("先连接"); return }
        guard live == nil else { return }
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
                self.note("live 快照 \(photo.data.count)B 已存相册")
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
        liveTicker?.invalidate()
        liveTicker = nil
        live?.stop()
        live = nil
        liveLine = "—"
    }

    func shareVideo() {
        guard let data = lastVideo else { note("还没有视频"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture.mp4")
        do {
            try data.write(to: url)
            share = ShareBox(url: url)
        } catch {
            note("写临时文件失败：\(error)")
        }
    }

    private func saveToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self?.note("没有相册权限，照片只在 app 内") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, err in
                let msg = ok ? "已存到相册" : "存相册失败：\(err?.localizedDescription ?? "?")"
                Task { @MainActor in self?.note(msg) }
            }
        }
    }

    // MARK: ask your own model

    func ask(_ question: String) {
        guard let photo = lastPhoto else { note("先拍一张"); return }
        UserDefaults.standard.set(modelBaseURL, forKey: "modelBaseURL")
        UserDefaults.standard.set(modelName, forKey: "modelName")
        busy = true
        Task {
            defer { busy = false }
            do {
                let text = try await ModelClient(baseURL: modelBaseURL, model: modelName,
                                                 log: { [weak self] in self?.note($0) })
                    .ask(question: question, jpeg: photo)
                answer = text
            } catch {
                note("模型调用失败：\(error)")
            }
        }
    }

    // MARK: provisioning (no Android, no PC)

    func becomeOwner(userToken: String) {
        guard let sess = session else {
            note("先点「连接（setup 链路）」，再登录")
            return
        }
        let key = owner ?? OwnerMaterial.generate()
        owner = key
        ownerLine = "owner key: 新建 \(key.publicKeyXy.hexShort)"
        busy = true
        Task {
            defer { busy = false }
            do {
                let bundle = try await Provisioner.becomeOwner(session: sess, owner: key,
                                                               userToken: userToken,
                                                               log: { [weak self] in self?.note($0) })
                UserDefaults.standard.set(true, forKey: "isOwner")
                ownerLine = "owner key: 已注册 · serial \(bundle.serial)"
                note("✅ 这台 iPhone 现在是主人。断开重连一次走 trust 链路")
                shareOwner()
            } catch {
                note("❌ 改 owner 失败：\(error)")
            }
        }
    }

    // MARK: export

    /// Copies an owner bundle picked in the Files app into Documents, then loads it.
    func importOwner(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = try? OwnerMaterial.loadAny(from: try writeTemp(data)) else {
                note("解析失败——要 owner-export.json 或 Visor 导出的 visor-owner-*.json")
                return
            }
            // Normalise to owner-export.json so the next launch finds it without the original file.
            let normalised = try JSONEncoder().encode(parsed.1)
            try normalised.write(to: OwnerMaterial.defaultURL, options: .atomic)
            try parsed.0.saveToKeychain()
            owner = parsed.0
            ownerLine = "owner key: 已导入 \(parsed.1.serial)"
            note("已导入 \(parsed.1.serial) 的 owner key（来源文件可直接是 Visor 导出的那个）")
        } catch {
            note("导入失败：\(error)")
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
        UIPasteboard.general.string = log.reversed().joined(separator: "\n")
        note("日志已复制到剪贴板（\(log.count) 行）")
    }

    // MARK: settings (svc33)

    /// Reads the whole settings namespace once and keeps it keyed by setting name.
    func loadSettings() {
        guard let sess = session, connected else {
            note("先连接眼镜，再读设置")
            return
        }
        settingsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let objects = try sess.driveObjects()
                var map: [String: String] = [:]
                for object in objects where object.type == Drive.kv && !object.deleted {
                    map[object.uri] = object.data
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settings = map
                    self.settingsLoading = false
                    self.note("设置：读到 \(map.count) 项")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settingsLoading = false
                    self.note("设置读取失败：\(error)")
                }
            }
        }
    }

    /// Writes one setting and only reports success if the read-back agrees.
    func writeSetting(_ key: String, _ value: String) {
        guard let sess = session, connected else {
            note("先连接眼镜，再改设置")
            return
        }
        note("写 \(key) = \(value)")
        let schema = SettingsSchemaTable.schema(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                        ok = mirrored.map { $0.data == value } ?? true
                    }
                } else {
                    ok = try sess.driveWrite(key: key, value: value)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok {
                        self.settings[key] = value
                        self.note("\(key) 已生效")
                    } else {
                        self.note("\(key) 写进去了但读回不一致（固件可能拒收）")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.note("写 \(key) 失败：\(error)")
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
                note("蓝牙就绪")
                autoReconnect()
            case .unauthorized: note("蓝牙权限被拒——检查 Info.plist")
            case .poweredOff: note("蓝牙关闭")
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
            peripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                note("后台恢复：\(restored.name ?? "眼镜") 仍连着")
            } else {
                note("后台恢复：重连 \(restored.name ?? "眼镜") …")
                c.connect(restored, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        Task { @MainActor in
            if !self.devices.contains(where: { $0.id == p.identifier }) {
                self.devices.append((p.identifier, name))
                self.note("发现 \(name) rssi=\(RSSI)")
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            self.note("已连接，打开 L2CAP PSM 0x\(String(self.psm, radix: 16))")
            p.discoverServices(nil)
            p.openL2CAPChannel(self.psm)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.connected = false
            self.glassesLine = "断开"
            self.note("断开：\(error?.localizedDescription ?? "正常")")
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in p.services ?? [] { self.note("service \(s.uuid)") }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        Task { @MainActor in
            guard let ch = channel else {
                self.note("L2CAP 打开失败：\(error?.localizedDescription ?? "?")")
                return
            }
            self.channel = ch
            self.note("L2CAP up psm=0x\(String(ch.psm, radix: 16))")
            let hasOwner = self.owner != nil && UserDefaults.standard.bool(forKey: "isOwner")
            await self.bringUp(trust: hasOwner)
        }
    }
}

// MARK: - model client

struct ModelClient {
    let baseURL: String
    let model: String
    var log: (String) -> Void = { _ in }

    func ask(question: String, jpeg: Data) async throws -> String {
        guard var comps = URLComponents(string: baseURL) else { throw LinkError.io("bad base URL") }
        comps.path = (comps.path.hasSuffix("/") ? comps.path : comps.path + "/") + "chat/completions"
        guard let url = comps.url else { throw LinkError.io("bad base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserDefaults.standard.string(forKey: "modelKey") ?? "none")",
                     forHTTPHeaderField: "Authorization")
        let b64 = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": question],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
                ],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        log("POST \(url.absoluteString) model=\(model) img=\(jpeg.count)B")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw LinkError.io("model \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        return text
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var g = Glasses()
    @State private var question = "我面前有什么？有台阶或障碍物吗？"
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var showImport = false
    @State private var showLive = false
    @State private var showQuick = false

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Text(g.ownerLine).font(.footnote)
                    Text(g.glassesLine).font(.footnote).foregroundStyle(.secondary)
                }

                Section("1 · 连眼镜") {
                    Button("扫描附近眼镜") { g.startScan() }
                    ForEach(g.devices, id: \.id) { d in
                        Button("连接 \(d.name)") { g.connect(d.id) }
                    }
                    Button("重新握手（setup 链路，不验 owner）") { g.connectSetup() }
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
                    if g.lastVideo != nil {
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
                    Button("看图问答") { g.ask(question) }.disabled(g.lastPhoto == nil || g.busy)
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
                    ForEach(Array(g.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
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
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .data]) { result in
                switch result {
                case .success(let url): g.importOwner(from: url)
                case .failure(let error): g.note("选文件失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
