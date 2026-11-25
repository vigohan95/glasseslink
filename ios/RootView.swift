import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Four screens organised by what you are trying to do — look at media, shoot, talk to the
/// assistant, or deal with the device — instead of by which protocol service answered.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var g = Glasses()
    @State private var selectedTab: Tab = .album

    private enum Tab: Hashable { case album, camera, assistant, device }

    var body: some View {
        TabView(selection: $selectedTab) {
            AlbumTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("相册", systemImage: "photo.stack") }
                .tag(Tab.album)
            ShootTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("拍摄", systemImage: "camera") }
                .tag(Tab.camera)
            AssistantTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("助手", systemImage: "waveform") }
                .tag(Tab.assistant)
            DeviceTab(g: g)
                .tabItem { Label("设备", systemImage: "eyeglasses") }
                .tag(Tab.device)
        }
        .tint(GlassesTheme.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { g.autoReconnect() }
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
                                     g.becomeOwner(userToken: code)
                                 },
                                 onCancel: { g.route = .becomeOwner })
                        .ignoresSafeArea()
                }
            }
        }
    }
}

private enum GlassesTheme {
    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.07, blue: 0.09, alpha: 1)
            : UIColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
    })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.39, green: 0.88, blue: 0.85, alpha: 1)
            : UIColor(red: 0.00, green: 0.36, blue: 0.39, alpha: 1)
    })
    static let console = Color(red: 0.04, green: 0.11, blue: 0.15)
    static let edge = Color.primary.opacity(0.09)
}

private extension View {
    func glassesPanel(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassesTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(GlassesTheme.edge).allowsHitTesting(false)
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
                if g.phaseBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(g.canUseGlasses ? Color.green
                              : { if case .failed = g.phase { return Color.red }; return Color.orange }())
                        .frame(width: 7, height: 7)
                }
                Text(g.connected && !g.canUseGlasses ? "待验证" : g.phaseText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if g.canUseGlasses, let b = g.status.batteryPercent {
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

private let mediaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
}()

private func clockText(_ ns: Int?) -> String {
    guard let ns else { return "" }
    return mediaDateFormatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1_000_000_000))
}

// MARK: - 相册

struct AlbumTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var filter: Filter = .all
    @State private var imported: Set<String> = []
    @State private var inFlight: String?
    @State private var failed: Set<String> = []
    @State private var preview: ThumbnailPreview?

    enum Filter: String, CaseIterable { case all = "全部", pending = "未导入", done = "已导入" }

    private struct ThumbnailPreview: Identifiable {
        let id: String
        let image: UIImage
        let isPhoto: Bool
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 245 : 146), spacing: 12, alignment: .top)]
    }

    private var captures: [Capture] {
        var seen = Set<String>()
        return g.captures.filter { seen.insert($0.id).inserted }
    }

    private var pending: [Capture] { captures.filter { !imported.contains($0.id) } }
    private var canImport: Bool { g.canUseGlasses && inFlight == nil && !g.busy }

    private var rows: [Capture] {
        if !g.canUseGlasses { return captures.filter { imported.contains($0.id) } }
        switch filter {
        case .all: return captures
        case .pending: return pending
        case .done: return captures.filter { imported.contains($0.id) }
        }
    }

    private var emptyMessage: String {
        if !g.canUseGlasses { return "导入过的照片和视频也可以在 iPhone 的「照片」里查看。" }
        switch filter {
        case .all: return "眼镜里还没有照片或视频。"
        case .pending: return "没有待导入的媒体。"
        case .done: return "这次还没有导入媒体。"
        }
    }

    var body: some View {
        let visibleRows = rows
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    galleryHeader
                    if g.canUseGlasses {
                        Picker("导入状态", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if inFlight != nil {
                        ProgressView(g.mediaMessage ?? "正在导入…")
                            .font(.footnote)
                            .glassesPanel(padding: 12)
                    } else if let message = g.mediaMessage {
                        Text(message)
                            .font(.footnote)
                            .glassesPanel(padding: 12)
                    }

                    if visibleRows.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(GlassesTheme.accent)
                                .accessibilityHidden(true)
                            Text(emptyMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .glassesPanel()
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visibleRows, id: \.id) { capture in
                                let thumb = g.thumbs[capture.id]
                                CaptureTile(capture: capture,
                                            thumbnail: thumb,
                                            imported: imported.contains(capture.id),
                                            working: inFlight == capture.id,
                                            failed: failed.contains(capture.id),
                                            fraction: g.progress[capture.id] ?? 0,
                                            canImport: canImport,
                                            onPreview: {
                                                if let thumb {
                                                    preview = ThumbnailPreview(id: capture.id, image: thumb, isPhoto: capture.isPhoto)
                                                }
                                            },
                                            onImport: { importCaptures([capture]) })
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(GlassesTheme.page.ignoresSafeArea())
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { openDevice() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { g.loadCaptures() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新眼镜相册")
                    .disabled(!canImport)
                }
            }
            .sheet(item: $preview) { item in
                NavigationStack {
                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .background(Color.black.ignoresSafeArea())
                        .navigationTitle(item.isPhoto ? "照片预览图" : "视频封面")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { preview = nil }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
            .onChange(of: g.canUseGlasses, initial: true) { _, canUse in
                if canUse && !g.busy { g.loadCaptures() }
            }
        }
    }

    private var galleryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                galleryTitle
                Spacer(minLength: 10)
                galleryAction
            }
            VStack(alignment: .leading, spacing: 12) {
                galleryTitle
                galleryAction
            }
        }
    }

    private var galleryTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(g.canUseGlasses ? "眼镜相册" : "媒体")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(g.canUseGlasses
                 ? "\(captures.count) 项媒体 · \(pending.count) 项未导入"
                 : (g.connected ? "连接已建立，等待主人验证" : "连接眼镜后查看原始照片和视频"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var galleryAction: some View {
        if !g.canUseGlasses {
            Button(g.connected ? "去验证" : "连接眼镜") { openDevice() }
                .buttonStyle(.borderedProminent)
        } else if !pending.isEmpty {
            Button { importCaptures(pending) } label: {
                Label("全部导入", systemImage: "arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canImport)
        }
    }

    private func importCaptures(_ queue: [Capture]) {
        guard canImport, let first = queue.first else { return }
        inFlight = first.id
        Task { @MainActor in
            defer { inFlight = nil }
            for capture in queue where !imported.contains(capture.id) {
                guard g.canUseGlasses, !Task.isCancelled else { break }
                inFlight = capture.id
                failed.remove(capture.id)
                if await g.importCapture(capture) {
                    imported.insert(capture.id)
                } else {
                    failed.insert(capture.id)
                }
            }
        }
    }
}

private struct CaptureTile: View {
    let capture: Capture
    let thumbnail: UIImage?
    let imported: Bool
    let working: Bool
    let failed: Bool
    let fraction: Double
    let canImport: Bool
    let onPreview: () -> Void
    let onImport: () -> Void

    private var progress: Double { fraction.isFinite ? min(1, max(0, fraction)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if thumbnail != nil {
                Button(action: onPreview) { cover }
                    .buttonStyle(.plain)
                    .accessibilityLabel(capture.isPhoto ? "打开照片预览图" : "查看视频封面")
            } else {
                cover
            }
            VStack(alignment: .leading, spacing: 9) {
                let time = clockText(capture.timestampNS)
                Text(time.isEmpty ? mediaKind : time)
                    .font(.subheadline.weight(.semibold))
                Text(sizeText(capture.assets.reduce(0) { $0 + $1.size }))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                importControl
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassesTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(GlassesTheme.edge).allowsHitTesting(false) }
    }

    private var mediaKind: String { capture.isPhoto ? "照片" : "视频" }

    private var cover: some View {
        LinearGradient(
            colors: [GlassesTheme.console, capture.isPhoto ? Color(red: 0.13, green: 0.44, blue: 0.45)
                     : Color(red: 0.24, green: 0.27, blue: 0.47)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .aspectRatio(1.15, contentMode: .fit)
        .overlay {
            if let thumbnail {
                GeometryReader { bounds in
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: capture.isPhoto ? "photo" : "video")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(mediaKind)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private var importControl: some View {
        if working {
            if progress > 0 {
                ProgressView(value: progress) {
                    Text("导入中 \(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                }
            } else {
                ProgressView("导入中").font(.caption)
            }
        } else if imported {
            Label("已导入", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GlassesTheme.accent)
                .frame(minHeight: 44, alignment: .leading)
        } else {
            Button(action: onImport) {
                Label(failed ? "重试导入" : "导入原件",
                      systemImage: failed ? "arrow.clockwise" : "arrow.down")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(failed ? .orange : GlassesTheme.accent)
            .disabled(!canImport)
        }
    }
}

// MARK: - 拍摄

struct ShootTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
    @State private var mode: CaptureMode = .photo

    private enum CaptureMode: String, CaseIterable {
        case photo = "照片"
        case video = "视频"
    }

    private var cameraTitle: String {
        if g.recording { return "正在录像" }
        if g.canUseGlasses { return "蓝牙拍摄已就绪" }
        return g.connected ? "拍摄需要验证主人身份" : "眼镜未连接"
    }

    private var shutterTitle: String {
        if g.recording { return "停止录像" }
        return mode == .photo ? "拍照" : "开始录像"
    }

    private var shutterColor: Color { mode == .video || g.recording ? .red : .white }
    private var lastReceivedPhoto: UIImage? {
        g.captures.lazy.filter(\.isPhoto).compactMap { g.thumbs[$0.id] }.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    cameraStage
                    if g.canUseGlasses {
                        shutterControls
                    } else {
                        Button(g.connected ? "验证主人身份" : "连接眼镜") { openDevice() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .glassesPanel()
                    }
                    if let message = g.mediaMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            if g.busy {
                                ProgressView().controlSize(.small)
                            }
                            Text(message).font(.footnote)
                        }
                        .glassesPanel(padding: 13)
                    }
                }
                .padding(18)
            }
            .background(GlassesTheme.page.ignoresSafeArea())
            .navigationTitle("拍摄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { openDevice() } }
            }
            .onChange(of: g.recording, initial: true) { _, recording in
                if recording { mode = .video }
            }
        }
    }

    private var cameraStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(cameraTitle, systemImage: g.recording ? "record.circle.fill" : "eyeglasses")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(g.recording ? Color(red: 1, green: 0.49, blue: 0.49) : .white)
                Spacer(minLength: 8)
                if g.recording, let deadline = g.recordDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timerText(deadline, now: context.date))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .accessibilityLabel("倒计时，\(timerText(deadline, now: context.date))")
                    }
                }
            }

            if let photo = lastReceivedPhoto {
                Color.black
                    .aspectRatio(1.7, contentMode: .fit)
                    .overlay {
                        GeometryReader { bounds in
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: bounds.size.width, height: bounds.size.height)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(alignment: .bottomLeading) {
                        Text("最近接收的照片")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(9)
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: g.recording ? "video.fill" : "camera.aperture")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityHidden(true)
                    Text("实时取景仍在测试")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 6]))
                }
            }
        }
        .padding(15)
        .background {
            LinearGradient(colors: [GlassesTheme.console, Color(red: 0.07, green: 0.24, blue: 0.26)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var shutterControls: some View {
        VStack(spacing: 14) {
            Picker("拍摄模式", selection: $mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(g.busy || g.recording)

            if mode == .video {
                Picker("最长录制", selection: $g.maxRecordSeconds) {
                    Text("不限").tag(0)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("3 分钟").tag(180)
                    Text("5 分钟").tag(300)
                }
                .pickerStyle(.menu)
                .disabled(g.busy || g.recording)
            }

            Button {
                if g.recording || mode == .video { g.toggleRecording() }
                else { g.snap() }
            } label: {
                VStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(GlassesTheme.console)
                            .frame(width: 78, height: 78)
                        Circle()
                            .strokeBorder(shutterColor, lineWidth: 2)
                            .frame(width: 67, height: 67)
                        RoundedRectangle(cornerRadius: g.recording ? 5 : 26)
                            .fill(shutterColor)
                            .frame(width: g.recording ? 26 : 52, height: g.recording ? 26 : 52)
                    }
                    .accessibilityHidden(true)
                    Text(shutterTitle).font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .disabled(g.busy)
            .opacity(g.busy ? 0.50 : 1)
        }
        .glassesPanel()
    }

    private func timerText(_ deadline: Date, now: Date) -> String {
        let left = max(0, Int(deadline.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}

// MARK: - 助手

struct AssistantTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
    @State private var question = ""
    @State private var showModel = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("照片问答") {
                    TextField("这是什么？前面有台阶吗？", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($typing)
                    Button {
                        typing = false
                        g.ask(question)
                    } label: {
                        Label(g.askingModel ? "正在问…" : "带上最近一张照片问", systemImage: "paperplane")
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || g.askingModel || g.lastPhoto == nil)
                    if g.lastPhoto == nil {
                        Text("先拍摄或导入一张照片。").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !g.answer.isEmpty {
                    Section("回答") {
                        Text(g.answer).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("助手")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { openDevice() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("模型") { showModel = true }
                }
            }
            .sheet(isPresented: $showModel) { ModelSheet(g: g) }
        }
    }
}

// MARK: - 设备

/// The build string, surfaced in the UI on purpose.
///
/// Twice now a pasted log turned out to come from the previous binary, and a fix that had already
/// shipped was re-diagnosed as "the same old bug". A version you can read off the screen settles
/// that in one glance, with no log archaeology.
enum BuildInfo {
    static var short: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

struct DeviceTab: View {
    @ObservedObject var g: Glasses

    var body: some View {
        NavigationStack {
            DeviceTabBody(g: g)
                .navigationTitle("设备")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(BuildInfo.short)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }
}

/// One question, one answer: does the glasses accept the key this phone holds?
struct OwnerBadge: View {
    @ObservedObject var g: Glasses

    private var title: String {
        switch g.ownerState {
        case .unknown: return "还不知道（还没连过眼镜）"
        case .unverified: return "待验证主人身份"
        case .verified: return "已验证 · 这台 iPhone 是主人"
        case .rejected(let code): return "被拒绝 · 0x\(String(code, radix: 16).uppercased())"
        }
    }

    private var detail: String {
        switch g.ownerState {
        case .unknown: return "连一次眼镜就会拿到答案。"
        case .unverified: return "\(g.trustLine)。导入或注册钥匙后，点「重新验证」。"
        case .verified: return "拍照、录像、取照片、改设置都已经解锁。"
        case .rejected(let code):
            return Glasses.explain(LinkError.trustRejected(code))
        }
    }

    private var color: Color {
        switch g.ownerState {
        case .verified: return .green
        case .rejected: return .red
        case .unverified: return .orange
        case .unknown: return .secondary
        }
    }

    private var symbol: String {
        switch g.ownerState {
        case .verified: return "checkmark.seal.fill"
        case .rejected: return "xmark.seal.fill"
        case .unverified: return "questionmark.circle"
        case .unknown: return "circle.dotted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let at = UserDefaults.standard.string(forKey: "ownerStateAt") {
                Text("上次验证：\(at)").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("重新验证") { g.reconnectForOwnerVerification() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(g.phaseBusy)
                Text(g.ownerFingerprint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeviceTabBody: View {
    @ObservedObject var g: Glasses
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSettings = false
    @State private var showQuick = false
    @State private var showDiagnostics = false
    @State private var showAbout = false

    private var candidates: [ScanEntry] {
        g.primaryDevices.sorted { $0.isListedBefore($1) }
    }

    private var connectionTitle: String {
        if g.canUseGlasses { return "眼镜已连接" }
        if g.connected { return "等待主人验证" }
        if case .failed = g.phase { return "连接失败" }
        return g.phaseText
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                connectionPanel
                if !g.connected { nearbyPanel }
                if g.canUseGlasses {
                    statusPanel
                    actionRow("常用眼镜设置", icon: "slider.horizontal.3") { showQuick = true }
                        .disabled(g.busy)
                        .glassesPanel(padding: 14)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        OwnerBadge(g: g)
                        Button("设置主人身份") { g.route = .ownerSetup }
                            .buttonStyle(.bordered)
                    }
                    .glassesPanel()
                }
                advancedPanel
            }
            .padding(18)
        }
        .background(GlassesTheme.page.ignoresSafeArea())
        .sheet(isPresented: $showQuick) { NavigationStack { QuickPanel(g: g) } }
        .sheet(isPresented: $showSettings) { SettingsView(g: g) }
        .sheet(isPresented: $showDiagnostics) { NavigationStack { ContentView(g: g) } }
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(GlassesTheme.accent.opacity(0.13))
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(GlassesTheme.accent)
                }
                .frame(width: 57, height: 57)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(connectionTitle)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    if g.glassesLine != connectionTitle && g.glassesLine != "未连接" {
                        Text(g.glassesLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if g.phaseBusy { ProgressView().controlSize(.small) }
            }
            if g.phaseBusy {
                Button("取消连接") { g.disconnect() }.buttonStyle(.bordered)
            } else if g.connected {
                Button("断开") { g.disconnect() }.buttonStyle(.bordered)
            } else if g.scanning {
                Button("停止扫描") { g.stopScan() }.buttonStyle(.bordered)
            } else if g.hasSavedGlasses {
                Button("重新连接上次眼镜") { g.reconnectLastGlasses() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("扫描眼镜") { g.startScan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .glassesPanel()
    }

    private var nearbyPanel: some View {
        let nearby = candidates
        return VStack(alignment: .leading, spacing: 12) {
            Text("已知与附近设备").font(.headline)
            if let message = g.discoveryMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            } else if nearby.isEmpty {
                if g.scanning {
                    ProgressView("扫描附近的眼镜…").font(.footnote)
                }
                Text(g.hasSavedGlasses && !g.scanning
                     ? "眼镜开机并在手机附近时，可以直接重连。"
                     : "首次连接时，折叠两侧镜腿，按住拍摄键直到镜框内侧的指示灯闪蓝。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(nearby) { device in candidateRow(device) }
            if g.hasSavedGlasses && !g.scanning && !g.phaseBusy {
                Button("扫描眼镜") { g.startScan() }.buttonStyle(.bordered)
            }
        }
        .glassesPanel()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("设备状态").font(.headline)
                Spacer()
                Button { g.refreshStatus() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 30)
                }
                .accessibilityLabel("刷新设备状态")
                .disabled(g.busy)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 180 : 89), spacing: 8)], spacing: 8) {
                statusMetric("电量", value: g.status.batteryPercent.map { "\($0)%" },
                             icon: g.status.charging == true ? "bolt.fill" : "battery.100")
                statusMetric("可用空间", value: g.status.storageFreeMb.map(storageText), icon: "internaldrive")
                statusMetric("眼镜音量", value: g.status.volumePercent.map { "\($0)%" }, icon: "speaker.wave.2")
            }
        }
        .glassesPanel()
    }

    private func statusMetric(_ title: String, value: String?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(GlassesTheme.accent)
                .accessibilityHidden(true)
            Text(value ?? "暂无数据")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(GlassesTheme.page, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private func storageText(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    private var advancedPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 13) {
                actionRow("完整设置列表", icon: "list.bullet") { showSettings = true }
                    .disabled(!g.canUseGlasses || g.busy)
                if g.canUseGlasses {
                    actionRow("管理主人身份", icon: "checkmark.shield") { g.route = .ownerSetup }
                }
                actionRow("诊断与实验功能", icon: "wrench.and.screwdriver") { showDiagnostics = true }
                actionRow("关于 · 许可 · 隐私", icon: "info.circle") { showAbout = true }
                Divider()
                Toggle("拦截固件升级", isOn: Binding(
                    get: { Glasses.blockOTA },
                    set: { Glasses.blockOTA = $0 }
                ))
                Button("关闭眼镜云端自动更新") {
                    g.writeSetting("cloud_ota_enabled", "false")
                }
                .disabled(!g.canUseGlasses || g.busy)
            }
            .padding(.top, 12)
        } label: {
            Label("高级", systemImage: "gearshape")
                .font(.headline)
        }
        .glassesPanel(padding: 14)
    }

    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func candidateRow(_ device: ScanEntry) -> some View {
        Button { g.connect(device.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: device.isGlasses ? "eyeglasses" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(GlassesTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.subheadline.weight(.semibold))
                    Text(device.sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if g.phaseBusy && g.connectingID == device.id {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text(g.phaseText))
                } else if let signal = device.signalLabel {
                    Text(signal).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(GlassesTheme.page, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(g.phaseBusy)
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
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data]) { res in
            switch res {
            case .success(let url):
                let ok = g.importOwner(from: url)
                failed = !ok
                result = ok ? "导入成功：\(g.ownerFingerprint)" : "这个文件不是可用的 owner key"
            case .failure(let e):
                failed = true
                result = "打不开文件：\(e.localizedDescription)"
            }
        }
    }

    private func doImport() {
        let ok = g.importOwner(text: text)
        failed = !ok
        result = ok ? "导入成功：\(g.ownerFingerprint)" : "内容不是可用的 owner key（要有 publicKeyXy 和 privateKeyPkcs8 两行）"
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
                    Text("请先在「设备」页选中眼镜。设置连接建立后就能登录注册。")
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { g.route = .ownerSetup }
            }
        }
    }
}
