import SwiftUI

/// The app's real shape: four screens you actually use, plus a diagnostics tab that keeps the
/// old knob-by-knob panel around for when a handshake goes wrong.
struct RootView: View {
    @StateObject private var g = Glasses()

    var body: some View {
        TabView {
            AlbumTab(g: g)
                .tabItem { Label("相册", systemImage: "photo.stack") }
            LiveTab(g: g)
                .tabItem { Label("取景", systemImage: "video.fill") }
            ControlTab(g: g)
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            AssistantTab(g: g)
                .tabItem { Label("助手", systemImage: "waveform") }
            ContentView(g: g)
                .tabItem { Label("诊断", systemImage: "wrench.and.screwdriver") }
        }
        .tint(.cyan)
    }
}

// MARK: - shared bits

/// One line of connection state with the two things you ever need: connect and disconnect.
struct LinkBar: View {
    @ObservedObject var g: Glasses

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(g.connected ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.connected ? "已连接" : "未连接")
                    .font(.subheadline.weight(.semibold))
                Text(g.glassesLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if g.connected {
                Button("断开") { g.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if let first = g.devices.first {
                Button("连接") { g.connect(first.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("扫描") { g.startScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }
}

private func bytes(_ n: Int) -> String {
    if n > 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
    if n > 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
    return "\(n) B"
}

private func when(_ ns: Int?) -> String {
    guard let ns else { return "" }
    let d = Date(timeIntervalSince1970: Double(ns) / 1_000_000_000)
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
}

// MARK: - 相册

struct AlbumTab: View {
    @ObservedObject var g: Glasses
    @State private var busyRow: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkBar(g: g)
                }

                if !g.connected {
                    Section("附近的眼镜") {
                        if g.devices.isEmpty {
                            Text("点右上角「扫描」，把眼镜双镜腿折起来、长按拍摄键 5 秒到闪蓝光。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(g.devices) { d in
                            Button {
                                g.connect(d.id)
                            } label: {
                                HStack {
                                    Image(systemName: d.isGlasses ? "eyeglasses" : "dot.radiowaves.left.and.right")
                                        .foregroundStyle(d.isGlasses ? Color.cyan : Color.secondary)
                                    VStack(alignment: .leading) {
                                        Text(d.name).font(.subheadline)
                                        Text("\(d.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                Section("眼镜里的照片与视频") {
                    if g.captures.isEmpty {
                        Text(g.connected ? "还没有记录，点下面的「按快门拍一张」。" : "连上眼镜后这里会列出眼镜里存着的东西。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(g.captures.enumerated()), id: \.offset) { _, c in
                        HStack(spacing: 12) {
                            Image(systemName: c.isPhoto ? "photo" : "video")
                                .foregroundStyle(c.isPhoto ? Color.cyan : Color.orange)
                                .font(.title3)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.isPhoto ? "照片" : "视频").font(.subheadline)
                                Text("\(when(c.timestampNS)) · \(bytes(c.assets.reduce(0) { $0 + $1.size }))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.still(c.isPhoto ? 0 : 0) != nil || !c.assets.isEmpty {
                                Button(busyRow == c.handle ? "取回中…" : "存到相册") {
                                    busyRow = c.handle
                                    g.fetch(c, saveToLibrary: true)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { busyRow = nil }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(busyRow != nil)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        g.snap()
                    } label: {
                        Label("按快门拍一张", systemImage: "camera.aperture")
                    }
                    .disabled(!g.connected)
                    Button {
                        g.toggleRecording()
                    } label: {
                        Label(g.recording ? "停止录像" : "开始录像",
                              systemImage: g.recording ? "stop.circle" : "record.circle")
                    }
                    .disabled(!g.connected)
                    Button {
                        g.loadCaptures()
                    } label: {
                        Label("刷新列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(!g.connected)
                }
            }
            .navigationTitle("相册")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        g.startScan()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .onAppear {
                if g.connected && g.captures.isEmpty { g.loadCaptures() }
            }
        }
    }
}

private extension Capture {
    func still(_ i: Int) -> CaptureAsset? {
        let s = stills
        return i < s.count ? s[i] : nil
    }
}

// MARK: - 取景

struct LiveTab: View {
    @ObservedObject var g: Glasses

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                LinkBar(g: g)
                    .padding(.horizontal)
                LiveView(g: g)
                Spacer(minLength: 0)
            }
            .navigationTitle("取景")
        }
    }
}

// MARK: - 设置

struct ControlTab: View {
    @ObservedObject var g: Glasses
    @State private var showQuick = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkBar(g: g)
                }
                Section("常用") {
                    Button {
                        showQuick = true
                    } label: {
                        Label("音量、指示灯、唤醒词、画质…", systemImage: "dial.medium")
                    }
                    Button {
                        g.refreshStatus()
                    } label: {
                        Label("刷新设备状态", systemImage: "battery.75")
                    }
                    .disabled(!g.connected)
                }
                if let b = g.status.batteryPercent {
                    Section("电池") {
                        LabeledContent("电量", value: "\(b)%")
                        if let c = g.status.charging, c {
                            LabeledContent("正在充电", value: "是")
                        }
                        if let left = g.status.storageFreeMb {
                            LabeledContent("剩余空间", value: "\(left / 1024) GB")
                        }
                    }
                }
                Section {
                    NavigationLink("全部 \(SettingsCatalog.all.count) 项眼镜设置") {
                        SettingsView(g: g)
                    }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showQuick) {
                NavigationStack { QuickPanel(g: g) }
            }
        }
    }
}

// MARK: - 助手

struct AssistantTab: View {
    @ObservedObject var g: Glasses
    @State private var question = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkBar(g: g)
                }
                Section {
                    Toggle("让眼镜走这个 app（说「Hey Meta」时）", isOn: Binding(
                        get: { g.assistantOn },
                        set: { on in on ? g.startAssistant() : g.stopAssistant() }
                    ))
                    .disabled(!g.connected)
                } footer: {
                    Text("打开后，眼镜的提问会交给下面这个模型回答，再让眼镜用自己的声音念出来。")
                }

                Section("模型") {
                    LabeledContent("地址") {
                        TextField("http://…/v1", text: Binding(
                            get: { g.modelBaseURL },
                            set: { g.modelBaseURL = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    LabeledContent("名称") {
                        TextField("gemma3:4b", text: Binding(
                            get: { g.modelName },
                            set: { g.modelName = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                }

                Section("问一句") {
                    TextField("这是什么？前面有台阶吗？", text: $question, axis: .vertical)
                        .focused($typing)
                        .lineLimit(1...4)
                    Button {
                        typing = false
                        g.ask(question)
                    } label: {
                        Label("带上最近一张照片问", systemImage: "paperplane")
                    }
                    .disabled(question.isEmpty || g.busy)
                }

                if !g.answer.isEmpty {
                    Section("回答") {
                        Text(g.answer)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("助手")
        }
    }
}
