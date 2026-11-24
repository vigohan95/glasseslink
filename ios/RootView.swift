import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Four screens organised by what you are trying to do — look at media, shoot, talk to the
/// assistant, or deal with the device — instead of by which protocol service answered.
struct RootView: View {
    @StateObject private var g = Glasses()

    var body: some View {
        TabView {
            AlbumTab(g: g)
                .tabItem { Label("相册", systemImage: "photo.stack") }
            ShootTab(g: g)
                .tabItem { Label("拍摄", systemImage: "camera") }
            AssistantTab(g: g)
                .tabItem { Label("助手", systemImage: "waveform") }
            DeviceTab(g: g)
                .tabItem { Label("设备", systemImage: "eyeglasses") }
        }
        .tint(.cyan)
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
                                     g.route = nil
                                     g.becomeOwner(userToken: code)
                                 },
                                 onCancel: { g.route = nil })
                        .ignoresSafeArea()
                }
            }
        }
    }
}

// MARK: - 全局状态胶囊

/// Every screen depends on the link, so every screen shows it, and tapping it goes to the
/// device page rather than hiding the state inside one tab.
struct StatusCapsule: View {
    @ObservedObject var g: Glasses
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(g.connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(g.connected ? "已连接" : "未连接")
                    .font(.caption.weight(.semibold))
                if g.connected, let b = g.status.batteryPercent {
                    Text("\(b)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(b < 20 ? Color.red : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

private func sizeText(_ n: Int) -> String {
    if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
    if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
    return "\(n) B"
}

private func clockText(_ ns: Int?) -> String {
    guard let ns else { return "" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ns) / 1_000_000_000))
}

// MARK: - 相册

/// Two different things live here and they must not be mixed up: what is still on the glasses
/// (a queue to drain) and what already lives on the phone (a library that works offline).
struct AlbumTab: View {
    @ObservedObject var g: Glasses
    @State private var filter: Filter = .all
    @State private var imported: Set<String> = []
    @State private var inFlight: String?
    @State private var failed: Set<String> = []
    @State private var showDevice = false

    enum Filter: String, CaseIterable { case all = "全部", pending = "未导入", done = "已导入" }

    private var rows: [Capture] {
        g.captures.filter { c in
            switch filter {
            case .all: return true
            case .pending: return !imported.contains(c.handle)
            case .done: return imported.contains(c.handle)
            }
        }
    }

    private var pendingCount: Int { g.captures.filter { !imported.contains($0.handle) }.count }

    var body: some View {
        NavigationStack {
            List {
                if !g.connected {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("眼镜不在线").font(.headline)
                            Text("下面是已经导入到这台手机的媒体；要看眼镜里的东西，先连上它。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("去连接") { showDevice = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if g.connected {
                    Section {
                        Picker("筛选", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if let id = inFlight {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在导入 \(g.captures.firstIndex(where: { $0.handle == id }).map { "\($0 + 1)" } ?? "1")/\(g.captures.count)")
                                    .font(.caption)
                                Spacer()
                                Text("一次一条，慢慢来").font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if pendingCount > 0 {
                            HStack {
                                Text("还有 \(pendingCount) 项没导入").font(.caption)
                                Spacer()
                                Button("全部导入") { importAll() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Section {
                    if rows.isEmpty {
                        Text(g.connected ? "眼镜里没有记录。去「拍摄」按一下快门。" : "这台手机还没有导入过任何东西。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, c in
                        CaptureRow(capture: c,
                                   thumb: g.thumbs[c.id],
                                   imported: imported.contains(c.handle),
                                   working: inFlight == c.handle,
                                   failed: failed.contains(c.handle),
                                   fraction: g.progress[c.id] ?? 0) {
                            importOne(c)
                        }
                    }
                } header: {
                    Text(filter == .done ? "已导入（离线可看）" : "眼镜里的记录")
                }
            }
            .navigationTitle("相册")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusCapsule(g: g) { showDevice = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        g.loadCaptures()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!g.connected)
                }
            }
            .sheet(isPresented: $showDevice) { DeviceSheet(g: g) }
            .onAppear { if g.connected && g.captures.isEmpty { g.loadCaptures() } }
        }
    }

    private func importOne(_ c: Capture) {
        guard inFlight == nil else { return }
        inFlight = c.handle
        failed.remove(c.handle)
        g.fetch(c, saveToLibrary: true)
        // The protocol has no completion callback here, so give it a beat and then settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            imported.insert(c.handle)
            inFlight = nil
        }
    }

    private func importAll() {
        let queue = g.captures.filter { !imported.contains($0.handle) }
        guard !queue.isEmpty else { return }
        var delay = 0.0
        for c in queue {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                inFlight = c.handle
                g.fetch(c, saveToLibrary: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    imported.insert(c.handle)
                    inFlight = nil
                }
            }
            delay += 3.0
        }
    }
}

struct CaptureRow: View {
    let capture: Capture
    let thumb: UIImage?
    let imported: Bool
    let working: Bool
    let failed: Bool
    /// 0…1 while transferring; the glasses tell us the real total, so this is not an estimate.
    let fraction: Double
    var onImport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 56, height: 56)
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: capture.isPhoto ? "photo" : "video")
                        .font(.title3)
                        .foregroundStyle(capture.isPhoto ? Color.cyan : Color.orange)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(clockText(capture.timestampNS)).font(.subheadline)
                Text("\(capture.isPhoto ? "照片" : "视频") · \(sizeText(capture.assets.reduce(0) { $0 + $1.size }))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if working {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView()
                        .controlSize(.small)
                    if fraction > 0 {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else if failed {
                Button(action: onImport) {
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else if imported {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
            } else {
                Button(action: onImport) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !imported { onImport() } }
    }
}

// MARK: - 拍摄

struct ShootTab: View {
    @ObservedObject var g: Glasses
    @State private var showDevice = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if !g.connected {
                    VStack(spacing: 10) {
                        Image(systemName: "eyeglasses").font(.largeTitle).foregroundStyle(.secondary)
                        Text("先连上眼镜").font(.headline)
                        Button("去连接") { showDevice = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    LiveView(g: g)
                        .frame(maxHeight: .infinity)
                    HStack(spacing: 12) {
                        Button {
                            g.snap()
                        } label: {
                            Label("拍照", systemImage: "camera.aperture")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            g.toggleRecording()
                        } label: {
                            Label(g.recording ? "停止" : "录像",
                                  systemImage: g.recording ? "stop.fill" : "record.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    HStack(spacing: 8) {
                        Text("最长录制").font(.caption).foregroundStyle(.secondary)
                        Picker("最长录制", selection: $g.maxRecordSeconds) {
                            Text("不限").tag(0)
                            Text("30 秒").tag(30)
                            Text("1 分钟").tag(60)
                            Text("3 分钟").tag(180)
                            Text("5 分钟").tag(300)
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        if let d = g.recordDeadline {
                            Text(timerText(d))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal)
                    Text("蓝牙链路只有约 120–165 KB/s，取景是低码率画面；要高清照就按快门，再回相册导入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
            }
            .navigationTitle("拍摄")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { showDevice = true } }
            }
            .sheet(isPresented: $showDevice) { DeviceSheet(g: g) }
        }
    }

    private func timerText(_ d: Date) -> String {
        let left = max(0, Int(d.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d 后停", left / 60, left % 60)
    }
}

// MARK: - 助手

struct AssistantTab: View {
    @ObservedObject var g: Glasses
    @State private var question = ""
    @State private var showModel = false
    @State private var showDevice = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("让眼镜用这个 app 回答", isOn: Binding(
                        get: { g.assistantOn },
                        set: { on in on ? g.startAssistant() : g.stopAssistant() }
                    ))
                    .disabled(!g.connected)
                } footer: {
                    Text(g.connected
                         ? "打开后说「Hey Meta」，问题会交给你的模型，答案由眼镜自己的喇叭念出来。"
                         : "眼镜不在线，下面仍然可以先测试模型能不能答。")
                }

                Section("提问") {
                    TextField("这是什么？前面有台阶吗？", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($typing)
                    Button {
                        typing = false
                        g.ask(question)
                    } label: {
                        Label(g.busy ? "正在问…" : "带上最近一张照片问", systemImage: "paperplane")
                    }
                    .disabled(question.isEmpty || g.busy)
                }

                if !g.answer.isEmpty {
                    Section("回答") {
                        Text(g.answer).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("助手")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { showDevice = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("模型") { showModel = true }
                }
            }
            .sheet(isPresented: $showModel) { ModelSheet(g: g) }
            .sheet(isPresented: $showDevice) { DeviceSheet(g: g) }
        }
    }
}

struct ModelSheet: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss

    /// Presets first: most people run one of these and only need to paste a key.
    private struct Preset: Identifiable {
        let id = UUID()
        let label: String
        let base: String
        let model: String
        let hint: String
    }
    private let presets: [Preset] = [
        .init(label: "本地 Ollama", base: "http://192.168.3.90:11434/v1", model: "gemma3:4b",
              hint: "电脑上跑 ollama serve；模型名填 ollama list 里的名字"),
        .init(label: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini",
              hint: "key 填 sk-… 开头那个"),
        .init(label: "DeepSeek", base: "https://api.deepseek.com/v1", model: "deepseek-chat",
              hint: "key 在 platform.deepseek.com 里建"),
        .init(label: "OpenRouter", base: "https://openrouter.ai/api/v1", model: "google/gemini-2.5-flash",
              hint: "一个 key 走很多家模型"),
        .init(label: "自建 / 其他", base: "", model: "", hint: "任何 OpenAI 兼容的 /v1/chat/completions"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("选择服务") {
                    ForEach(presets) { p in
                        Button {
                            if !p.base.isEmpty { g.modelBaseURL = p.base }
                            if !p.model.isEmpty { g.modelName = p.model }
                        } label: {
                            HStack {
                                Text(p.label)
                                Spacer()
                                if g.modelBaseURL == p.base, !p.base.isEmpty {
                                    Image(systemName: "checkmark").foregroundStyle(.cyan)
                                }
                            }
                        }
                    }
                }
                Section("地址（OpenAI 兼容）") {
                    TextField("https://…/v1", text: Binding(
                        get: { g.modelBaseURL }, set: { g.modelBaseURL = $0 }))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section("模型名") {
                    TextField("模型名", text: Binding(
                        get: { g.modelName }, set: { g.modelName = $0 }))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("API key（本地 Ollama 可留空）", text: Binding(
                        get: { g.modelKey }, set: { g.modelKey = $0 }))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text(presets.first { $0.base == g.modelBaseURL }?.hint
                         ?? "任何兼容 /v1/chat/completions 的服务都能用；带图的模型才能看图。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        g.testModel()
                    } label: {
                        HStack {
                            Text("测试连通性")
                            Spacer()
                            if g.testingModel { ProgressView().controlSize(.small) }
                        }
                    }
                    if !g.modelTestLine.isEmpty {
                        Text(g.modelTestLine).font(.footnote)
                            .foregroundStyle(g.modelTestOK ? Color.green : Color.orange)
                    }
                }
            }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 设备

struct DeviceTab: View {
    @ObservedObject var g: Glasses

    var body: some View {
        NavigationStack {
            DeviceTabBody(g: g)
                .navigationTitle("设备")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { StatusCapsule(g: g) {} }
                }
        }
    }
}

/// Sheet version of the device page, so any tab can open the connection UI without leaving.
struct DeviceSheet: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DeviceTabBody(g: g)
                .navigationTitle("设备")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

/// The list body, shared by the tab and the sheet.
struct DeviceTabBody: View {
    @ObservedObject var g: Glasses
    @State private var showSettings = false
    @State private var showQuick = false
    @State private var showDiagnostics = false
    @State private var showAbout = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.connected ? "已连接" : "未连接").font(.headline)
                        Text(g.glassesLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if g.connected {
                        Button("断开") { g.disconnect() }.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button("扫描") { g.startScan() }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            Section("主人身份") {
                Text(g.trustLine).font(.footnote)
                Button("一次性设置（导入或注册钥匙）") { g.route = .ownerSetup }
            }
            if !g.connected {
                Section {
                    if g.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("还没看到眼镜", systemImage: "eyeglasses")
                                .font(.subheadline.weight(.semibold))
                            Text("① 把双镜腿折起来\n② 长按右侧拍摄键 5 秒，直到镜框内侧闪蓝\n③ 回到这里点「扫描」")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(g.primaryDevices) { d in
                        Button { g.connect(d.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: d.isGlasses ? "eyeglasses" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(d.isGlasses ? Color.cyan : Color.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.displayName).foregroundStyle(.primary)
                                    if d.isGlasses {
                                        Text("点一下连接").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if g.connectingID == d.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("\(d.rssi) dBm").font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(g.connectingID != nil)
                    }
                    if !g.otherDevices.isEmpty {
                        DisclosureGroup("其他 \(g.otherDevices.count) 个蓝牙信号") {
                            ForEach(g.otherDevices) { d in
                                HStack {
                                    Text(d.displayName).font(.footnote)
                                    Spacer()
                                    Text("\(d.rssi) dBm").font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("附近的眼镜")
                } footer: {
                    if g.scanning { Text("正在扫描…（20 秒自动停）") }
                }
            }
            if g.connected {
                Section("日常") {
                    Button { showQuick = true } label: {
                        Label("音量、指示灯、唤醒词、画质", systemImage: "dial.medium")
                    }
                    Button { showSettings = true } label: {
                        Label("全部 \(SettingsCatalog.all.count) 项设置", systemImage: "slider.horizontal.3")
                    }
                    Button { g.refreshStatus() } label: {
                        Label("刷新设备状态", systemImage: "arrow.clockwise")
                    }
                }
            }
            Section("一次性设置") {
                Button("成为这副眼镜的主人") { g.route = .ownerSetup }
            }
            Section("高级") {
                Button { showDiagnostics = true } label: {
                    Label("自检、读写日志、原始诊断", systemImage: "wrench.and.screwdriver")
                }
                Button { showAbout = true } label: {
                    Label("关于 · 许可 · 隐私", systemImage: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showQuick) { NavigationStack { QuickPanel(g: g) } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView(g: g) } }
        .sheet(isPresented: $showDiagnostics) { NavigationStack { ContentView(g: g) } }
        .sheet(isPresented: $showAbout) { AboutView() }
    }
}

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
    }
}

struct ImportOwnerView: View {
    @ObservedObject var g: Glasses
    @State private var picking = false

    var body: some View {
        VStack(spacing: 16) {
            Text("选 owner-export.json").font(.headline)
            Button("从文件 App 选择") { picking = true }
                .buttonStyle(.borderedProminent)
            Button("从剪贴板粘贴（更快）") { g.importOwnerFromPasteboard() }
                .buttonStyle(.bordered)
            Text("把 owner-export.json 的全部内容复制，然后点上面这个按钮。").font(.caption2).foregroundStyle(.secondary)
            Text(g.ownerLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("导入钥匙")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result { g.importOwner(from: url) }
        }
    }
}

struct BecomeOwnerView: View {
    @ObservedObject var g: Glasses

    var body: some View {
        List {
            Section {
                Button("开始注册流程") { g.route = .login }
                Text(g.ownerLine).font(.caption).foregroundStyle(.secondary)
            }
            Section("会看到什么") {
                Text("① Meta 登录页（只这一次）\n② 眼镜连按拍摄键 3–5 次确认\n③ 成功后立刻导出 owner-export.json")
                    .font(.footnote)
            }
            Section("不想再碰 Meta？") {
                Text("回到上一页选「① 用上次导出的钥匙文件导入」。那把钥匙在补丁版 Visor 里导出过一次就够了，之后这台 iPhone 不再需要 Meta 账号。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("向 Meta 注册")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { g.route = .ownerSetup }
            }
        }
    }
}
