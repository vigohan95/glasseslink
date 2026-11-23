// App.swift — the whole point: an iPhone that talks to the glasses by itself.
//
//   scan → connect → L2CAP(PSM 128) → AirShield handshake
//        → (first run) become owner via svc36 + Meta   → afterwards: trust
//        → capture list → pull the newest photo over the encrypted link
//        → ask your own model about it (any OpenAI-compatible endpoint)

import SwiftUI
import CoreBluetooth
import AuthenticationServices
import Photos

@main
struct GlassesApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
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

    @Published var modelBaseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? "http://192.168.3.90:11434/v1"
    @Published var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "gemma3:4b"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var stream: SDUStream?
    private var session: Session?
    private var owner: OwnerMaterial?

    /// Ray-Ban Meta Gen 2 exposes the link on L2CAP PSM 0x80.
    let psm: CBL2CAPPSM = 0x80

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        if let k = OwnerMaterial.loadFromKeychain() {
            owner = k
            ownerLine = "owner key: 已载入 \(k.publicKeyXy.hexShort)"
        } else if let (k, b) = try? OwnerMaterial.load(from: OwnerMaterial.defaultURL) {
            owner = k
            ownerLine = "owner key: 从文件导入 \(b.serial)"
        } else {
            ownerLine = "owner key: 没有——先点「成为主人」"
        }
    }

    func note(_ s: String) {
        let line = "\(Self.ts()) \(s)"
        log.insert(line, at: 0)
        if log.count > 400 { log.removeLast() }
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
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        note("连接 \(p.name ?? "?") …")
        central.connect(p, options: nil)
    }

    // MARK: link bring-up

    private func bringUp(trust: Bool) async {
        guard let ch = channel else { note("没有 L2CAP 通道"); return }
        let s = SDUStream(channel: ch)
        s.onLog = { [weak self] in self?.note($0) }
        stream = s
        guard let own = owner else {
            note("没有 owner key：先跑一次「成为主人」（它会用全新 key）")
            return
        }
        let sess = Session(stream: s, owner: own, log: { [weak self] in self?.note($0) })
        session = sess
        do {
            try sess.handshake(trust: trust)
            connected = true
            if trust { UserDefaults.standard.set(true, forKey: "isOwner") }
            glassesLine = "已连上 (trust=\(trust))"
            note("✅ 链路建立完成")
        } catch {
            note("❌ 握手中断：\(error)")
        }
    }

    // MARK: capture

    func capture() {
        guard let sess = session else { note("先连接"); return }
        busy = true
        Task {
            defer { Task { @MainActor in self.busy = false } }
            do {
                let caps = try sess.captureList()
                note("清单 \(caps.count) 条")
                guard let newest = caps.filter({ $0.isPhoto }).max(by: { ($0.timestampNS ?? 0) < ($1.timestampNS ?? 0) }),
                      let still = newest.stills.first else {
                    note("清单里没有照片资产")
                    return
                }
                note("拉取 \(newest.handle) / \(still.uuid) (\(still.size)B)")
                try sess.requestAsset(handle: newest.handle, assetID: still.uuid)
                if let t = try sess.receiveFile() {
                    await MainActor.run {
                        self.lastPhoto = t.data
                        self.note("收到 \(t.name) \(t.size)B")
                    }
                    saveToPhotos(t.data)
                }
            } catch {
                note("取图失败：\(error)")
            }
        }
    }

    private func saveToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                self.note("没有相册权限，照片只在 app 内")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, err in
                self.note(ok ? "已存到相册" : "存相册失败：\(err?.localizedDescription ?? "?")")
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
            defer { Task { @MainActor in self.busy = false } }
            do {
                let text = try await ModelClient(baseURL: modelBaseURL, model: modelName,
                                                 log: { [weak self] in self?.note($0) })
                    .ask(question: question, jpeg: photo)
                await MainActor.run { self.answer = text }
            } catch {
                note("模型调用失败：\(error)")
            }
        }
    }

    // MARK: provisioning (no Android, no PC)

    func becomeOwner(userToken: String) {
        guard let sess = session else { note("先连接眼镜（首次会以 setup 链路连上）"); return }
        let key = owner ?? OwnerMaterial.generate()
        owner = key
        ownerLine = "owner key: 新建 \(key.publicKeyXy.hexShort)"
        busy = true
        Task {
            defer { Task { @MainActor in self.busy = false } }
            do {
                let bundle = try await Provisioner.becomeOwner(session: sess, owner: key,
                                                               userToken: userToken,
                                                               log: { [weak self] in self?.note($0) })
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: "isOwner")
                    self.ownerLine = "owner key: 已注册，serial \(bundle.serial)"
                    self.note("✅ 这台 iPhone 现在是主人了。断开重连一次，就会走 trust 链路")
                }
            } catch {
                note("❌ 改 owner 失败：\(error)")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension Glasses: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn: note("蓝牙就绪")
            case .unauthorized: note("蓝牙权限被拒——检查 Info.plist")
            case .poweredOff: note("蓝牙关闭")
            default: note("central state \(c.state.rawValue)")
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
            // First run: no owner yet → setup link (no trust) so we can provision.
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

    struct Message: Codable { let role: String; let content: AnyCodable }
    struct AnyCodable: Codable {
        let value: Any
        init(_ v: Any) { value = v }
        init(from d: Decoder) throws { value = "" }   // not needed for requests
        func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            if let s = value as? String { try c.encode(s) }
            else if let a = value as? [AnyCodable] { try c.encode(a) }
            else { try c.encode("\(value)") }
        }
    }
    struct Body: Codable {
        struct Part: Codable { let type: String; let text: String?; let image_url: Img? }
        struct Img: Codable { let url: String }
        let model: String
        let messages: [[String: AnyCodable]]
        let max_tokens: Int
    }
    struct Resp: Codable {
        struct Choice: Codable { let message: [String: AnyCodable]? }
        let choices: [Choice]?
    }

    func ask(question: String, jpeg: Data) async throws -> String {
        guard var comps = URLComponents(string: baseURL) else { throw LinkError.io("bad base URL") }
        comps.path = (comps.path.hasSuffix("/") ? comps.path : comps.path + "/") + "chat/completions"
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
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
        log("POST \(comps.url!.absoluteString) model=\(model) img=\(jpeg.count)B")
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
    @State private var loginSession: ASWebAuthenticationSession?
    @State private var pendingProvision = false

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Text(g.ownerLine).font(.footnote)
                    Text(g.glassesLine).font(.footnote).foregroundStyle(.secondary)
                }

                Section("眼镜") {
                    Button("扫描附近眼镜") { g.startScan() }
                    ForEach(g.devices, id: \.id) { d in
                        Button("连接 \(d.name)") { g.connect(d.id) }
                    }
                    if !g.connected {
                        Button("以 setup 链路连接（首次 / 改 owner 用）") {
                            g.startScan()
                        }
                    }
                }

                Section("成为主人（一次）") {
                    Button("用 Meta 账号登录并注册这台 iPhone") { startLogin() }
                        .disabled(!g.connected && !pendingProvision)
                    Text("登录在系统浏览器里完成；token 只用来给眼镜签一张 ownership receipt。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("拍照 / 取图") {
                    Button(g.busy ? "处理中…" : "拉取最新一张照片") { g.capture() }
                        .disabled(!g.connected || g.busy)
                    if let d = g.lastPhoto, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                }

                Section("问自己的模型") {
                    TextField("base URL", text: $g.modelBaseURL).textInputAutocapitalization(.never).font(.footnote)
                    TextField("model", text: $g.modelName).font(.footnote)
                    TextField("问题", text: $question, axis: .vertical).lineLimit(1 ... 3)
                    Button("看图问答") { g.ask(question) }.disabled(g.lastPhoto == nil || g.busy)
                    if !g.answer.isEmpty {
                        Text(g.answer).font(.callout)
                    }
                }

                Section("日志") {
                    ForEach(Array(g.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Glasses")
        }
    }

    private func startLogin() {
        let state = UUID().uuidString
        let url = Meta.authorize(state: state)
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "https") { callback, err in
            guard let cb = callback, let code = Meta.code(from: cb) else {
                g.note("登录取消：\(err?.localizedDescription ?? "无回调")")
                return
            }
            g.note("拿到 code，交换 token…")
            Task {
                do {
                    let token = try await MetaClient(log: { g.note($0) }).exchangeCode(code)
                    g.becomeOwner(userToken: token)
                } catch {
                    g.note("token 交换失败：\(error)")
                }
            }
        }
        s.presentationContextProvider = WebAuthContext.shared
        s.prefersEphemeralWebBrowserSession = false
        loginSession = s
        s.start()
    }
}

final class WebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthContext()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
