import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The four tabs, in tab-bar order.
enum AppTab: Hashable { case device, album, camera, assistant }

/// Four screens organised by what you are trying to do — deal with the glasses, look at media, shoot,
/// talk to the assistant — instead of by which protocol service answered.
///
/// The screens live in HomeViews / AlbumViews / ShootViews / AssistantViews; the shared look is in
/// DesignSystem. This file keeps what must sit at the root: the tab bar, the toast, and the sheets
/// that have to survive every publish of `g`.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var g = Glasses()
    @State private var selectedTab: AppTab = .device
    @State private var manualMediaWiFiSheet: ManualMediaWiFiJoin?

    private var importBadge: String? { g.mediaImportInProgress ? "导入中" : nil }
    private var shouldPollGlassesStatus: Bool {
        selectedTab == .device && scenePhase == .active && g.canUseGlasses && !g.mediaImportInProgress
    }

    /// With Hey Meta on, its reader sees the glasses' camera reports as they come. Without it nothing
    /// reads the link between requests, and a take stopped on the glasses would go unnoticed.
    private var watchesRecording: Bool {
        scenePhase == .active && g.recording && !g.assistantOn && g.canUseGlasses
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab(g: g, openTab: { selectedTab = $0 })
                .tabItem { Label("眼镜", systemImage: "eyeglasses") }
                .tag(AppTab.device)
            AlbumTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("相册", systemImage: "photo.on.rectangle.angled") }
                .badge(importBadge)
                .tag(AppTab.album)
            ShootTab(g: g, openDevice: { selectedTab = .device }, openAlbum: { selectedTab = .album })
                .tabItem { Label("拍摄", systemImage: "camera") }
                .tag(AppTab.camera)
            AssistantTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("助手", systemImage: "waveform") }
                .tag(AppTab.assistant)
        }
        .tint(GlassesTheme.accent)
        // Results of every action land here, above all four tabs.
        .overlay(alignment: .top) { ToastOverlay(g: g) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                g.readAudioOutput()
                g.enterForeground()
            } else if phase == .background {
                g.enterBackground()
                LogStore.shared.flushToDisk()
            }
        }
        .task(id: shouldPollGlassesStatus) {
            guard shouldPollGlassesStatus else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                g.refreshVisibleDeviceStatus()
            }
        }
        .task(id: watchesRecording) {
            guard watchesRecording else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                g.refreshVisibleDeviceStatus()
            }
        }
        .onChange(of: g.manualMediaWiFi?.id, initial: true) { _, _ in
            manualMediaWiFiSheet = g.manualMediaWiFi
        }
        .sheet(item: $manualMediaWiFiSheet) { request in
            ManualMediaWiFiSheet(g: g, request: request) { useWiFi in
                resolveManualMediaWiFi(request, useWiFi: useWiFi)
            }
            .onDisappear { resolveManualMediaWiFi(request, useWiFi: false) }
        }
        // One-time setup lives at the root, not inside a NavigationLink.
        // A sheet presented from a pushed destination dies the moment `g` publishes
        // (the stack rebuilds and the presenter goes away) — which is why the login
        // page flashed open and closed. Routed from here it survives.
        .sheet(item: $g.route) { route in
            NavigationStack {
                switch route {
                case .ownerSetup: OwnerSetupView(g: g)
                case .importOwner: ImportOwnerView(g: g)
                case .becomeOwner: BecomeOwnerView(g: g)
                case .login:
                    LoginWebView(url: Meta.authorize(state: UUID().uuidString),
                                 onCode: { code in
                                     g.route = .becomeOwner
                                     // The page hands back an OAuth code; registration needs the token it
                                     // exchanges for (the diagnostics screen already did this).
                                     g.note("拿到 code，交换 token…")
                                     Task {
                                         do {
                                             let token = try await MetaClient(log: { g.note($0) }).exchangeCode(code)
                                             g.becomeOwner(userToken: token)
                                         } catch {
                                             g.note("token 交换失败：\(error)")
                                         }
                                     }
                                 },
                                 onCancel: { g.route = .becomeOwner })
                        .ignoresSafeArea()
                }
            }
            .overlay(alignment: .top) { ToastOverlay(g: g, announces: false) }
        }
    }

    private func resolveManualMediaWiFi(_ request: ManualMediaWiFiJoin, useWiFi: Bool) {
        guard g.manualMediaWiFi?.id == request.id else { return }
        g.resolveManualMediaWiFi(useWiFi)
        if manualMediaWiFiSheet?.id == request.id { manualMediaWiFiSheet = nil }
    }
}

/// The build string, surfaced in the UI on purpose.
///
/// Twice now a pasted log turned out to come from the previous binary, and a fix that had already
/// shipped was re-diagnosed as "the same old bug". A version you can read off the screen settles
/// that in one glance, with no log archaeology. It sits at the foot of the 眼镜 tab and of 更多.
enum BuildInfo {
    static var short: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - 手动加入眼镜 Wi-Fi

private struct ManualMediaWiFiSheet: View {
    @ObservedObject var g: Glasses
    let request: ManualMediaWiFiJoin
    let resolve: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("网络名称") {
                        Text(request.ssid).monospaced().textSelection(.enabled)
                    }
                    if !request.password.isEmpty {
                        LabeledContent("密码") {
                            Text(request.password).monospaced().textSelection(.enabled)
                        }
                        Button {
                            UIPasteboard.general.string = request.password
                            copied = true
                            g.showToast("密码已复制", .success)
                        } label: {
                            Label(copied ? "已复制，去设置里粘贴" : "复制密码",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                    }
                } header: {
                    Text("眼镜 Wi-Fi")
                } footer: {
                    Text("这组名称和密码以后不会再变。只要输一次，iPhone 就会记住这个网络。")
                }
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在等 iPhone 连上这个网络，连上后自动开始导入。")
                            .font(.subheadline)
                    }
                    Button {
                        openWiFiSettings()
                    } label: {
                        Label("打开「设置」去加入", systemImage: "gear")
                    }
                    .fontWeight(.semibold)
                } footer: {
                    Text("免费签名的 App 不能替你切换 Wi-Fi，每次都要你在「设置 › 无线局域网」或控制中心里点一下这个眼镜网络。iPhone 在家里的 Wi-Fi 上时不会自己切过去。")
                }
                Section("第一次怎么加入") {
                    Text("1. 点上面的「复制密码」。")
                    Text("2. 打开 iPhone「设置 › 无线局域网」，点这个眼镜网络，在密码框长按选「粘贴」。")
                }
                Section("以后") {
                    Text("在控制中心长按 Wi-Fi 图标，选这个眼镜网络即可，不用再输密码。导入完 iPhone 会自己回到原来的网络。")
                }
                Section {
                    Button("改用蓝牙（较慢）") { resolve(false) }
                }
            }
            .navigationTitle("加入眼镜 Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay(alignment: .top) { ToastOverlay(g: g, announces: false) }
    }

    /// The Wi-Fi page of Settings when iOS opens it for us, else this app's own page there.
    private func openWiFiSettings() {
        let fallback = URL(string: UIApplication.openSettingsURLString)
        guard let wifi = URL(string: "App-Prefs:root=WIFI") else { return }
        UIApplication.shared.open(wifi, options: [:]) { opened in
            if !opened, let fallback { UIApplication.shared.open(fallback) }
        }
    }
}

// MARK: - 主人身份（一次性设置）

/// The one-time, high-risk step, kept off the daily screens and explained before it runs.
struct OwnerSetupView: View {
    @ObservedObject var g: Glasses

    var body: some View {
        List {
            Section {
                Text("这一步只做一次：让你的 iPhone 成为这副眼镜的主人。做完之后，不再需要任何 Meta app 参与日常使用。")
                    .font(.footnote)
            }
            Section("两种做法") {
                Button("① 用上次导出的钥匙文件导入") { g.route = .importOwner }
                Button("② 现在向 Meta 注册（需要登录一次）") { g.route = .becomeOwner }
            }
            Section("说明") {
                Text("换手机、换签名证书、删掉 app 之前，先把 owner-export.json 存到「文件」里；丢了它就得重新做这一步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("成为主人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { g.route = nil }
            }
        }
    }
}

struct ImportOwnerView: View {
    @ObservedObject var g: Glasses
    @State private var picking = false
    @State private var text = ""
    @State private var result = ""
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("把 owner-export.json 的完整内容粘到下面").font(.headline)

                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .font(.system(.caption, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 10) {
                    Button("从剪贴板填入") {
                        text = UIPasteboard.general.string ?? ""
                        result = text.isEmpty ? "剪贴板是空的" : "已填入 \(text.count) 个字符，点「导入」确认"
                        failed = text.isEmpty
                    }
                    .buttonStyle(.bordered)

                    Button("导入") { doImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !result.isEmpty {
                    Label(result, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(failed ? Color.orange : Color.green)
                }

                Text(g.ownerLine).font(.caption).foregroundStyle(.secondary)

                Divider()

                Button("从文件 App 选择文件") { picking = true }
                    .buttonStyle(.bordered)

                Text("文件也可能是从微信/邮件里收到的；iOS 的「文件」App 里找到它，长按 → 共享 → 存储到“文件”，再回来这里选。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("导入钥匙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { g.route = .ownerSetup }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data]) { res in
            switch res {
            case .success(let url):
                let ok = g.importOwner(from: url)
                report(ok, failure: "这个文件不是可用的 owner key")
            case .failure(let e):
                failed = true
                result = "打不开文件：\(e.localizedDescription)"
                g.showToast("打不开这个文件", .failure)
            }
        }
    }

    private func doImport() {
        let ok = g.importOwner(text: text)
        report(ok, failure: "内容不是可用的 owner key（要有 publicKeyXy 和 privateKeyPkcs8 两行）")
    }

    private func report(_ ok: Bool, failure: String) {
        failed = !ok
        result = ok ? "导入成功：\(g.ownerFingerprint)" : failure
        if ok {
            g.showToast("钥匙已导入", .success)
        } else {
            g.showToast("没有导入，请检查钥匙内容", .failure)
        }
    }
}

struct BecomeOwnerView: View {
    @ObservedObject var g: Glasses

    var body: some View {
        List {
            Section {
                if g.connected && g.ownerState == .verified {
                    Label("主人身份已验证", systemImage: "checkmark.seal.fill")
                } else if g.busy {
                    ProgressView("正在处理…")
                } else if g.ownerRegistrationCompleted {
                    Button("重新连接并验证") { g.reconnectForOwnerVerification() }
                        .disabled(g.phaseBusy)
                } else if g.canStartOwnerRegistration {
                    Button("开始注册流程") { g.route = .login }
                } else if g.phaseBusy {
                    ProgressView("正在连接眼镜…")
                    Button("取消连接") { g.disconnect() }
                } else {
                    Button("为注册连接眼镜") { g.connectSetup() }
                    Text("请先在「眼镜」页选中眼镜。设置连接建立后就能登录注册。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = g.registrationMessage {
                    Text(message).font(.footnote)
                }
            }
            Section("会看到什么") {
                Text("登录 Meta 后，请按页面提示在眼镜上确认。注册成功后，点「重新连接并验证」。")
                    .font(.footnote)
            }
            Section("不想再碰 Meta？") {
                Text("回到上一页选「① 用上次导出的钥匙文件导入」。那把钥匙在补丁版 Visor 里导出过一次就够了，之后这台 iPhone 不再需要 Meta 账号。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("向 Meta 注册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { g.route = .ownerSetup }
            }
        }
    }
}
