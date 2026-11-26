import AVFoundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Four screens organised by what you are trying to do — look at media, shoot, talk to the
/// assistant, or deal with the device — instead of by which protocol service answered.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var g = Glasses()
    @State private var selectedTab: Tab = .device
    @State private var manualMediaWiFiSheet: ManualMediaWiFiJoin?

    private enum Tab: Hashable { case album, camera, assistant, device }

    private var importBadge: String? { g.mediaImportInProgress ? "导入中" : nil }
    private var shouldPollGlassesStatus: Bool {
        selectedTab == .device && scenePhase == .active && g.canUseGlasses && !g.mediaImportInProgress
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceTab(g: g)
                .tabItem { Label("眼镜", systemImage: "eyeglasses") }
                .tag(Tab.device)
            AlbumTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("相册", systemImage: "photo.stack") }
                .badge(importBadge)
                .tag(Tab.album)
            ShootTab(g: g, openDevice: { selectedTab = .device }, openAlbum: { selectedTab = .album })
                .tabItem { Label("拍摄", systemImage: "camera") }
                .tag(Tab.camera)
            AssistantTab(g: g, openDevice: { selectedTab = .device })
                .tabItem { Label("助手", systemImage: "waveform") }
                .tag(Tab.assistant)
        }
        .tint(GlassesTheme.accent)
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
        .onChange(of: g.manualMediaWiFi?.id, initial: true) { _, _ in
            manualMediaWiFiSheet = g.manualMediaWiFi
        }
        .sheet(item: $manualMediaWiFiSheet) { request in
            ManualMediaWiFiSheet(request: request) { useWiFi in
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
                                     g.becomeOwner(userToken: code)
                                 },
                                 onCancel: { g.route = .becomeOwner })
                        .ignoresSafeArea()
                }
            }
        }
    }

    private func resolveManualMediaWiFi(_ request: ManualMediaWiFiJoin, useWiFi: Bool) {
        guard g.manualMediaWiFi?.id == request.id else { return }
        g.resolveManualMediaWiFi(useWiFi)
        if manualMediaWiFiSheet?.id == request.id { manualMediaWiFiSheet = nil }
    }
}

private struct ManualMediaWiFiSheet: View {
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
                Section("第一次怎么加入") {
                    Text("1. 点上面的「复制密码」。")
                    Text("2. 打开 iPhone「设置 › 无线局域网」，点这个眼镜网络，在密码框长按选「粘贴」。")
                    Text("加入后 GlassesLink 会自己继续，不用回来点按钮。")
                }
                Section("以后") {
                    Text("在控制中心长按 Wi-Fi 图标，选这个眼镜网络即可，不用再输密码。")
                }
                Section {
                    Button("已加入") { resolve(true) }
                    Button("改用蓝牙（较慢）") { resolve(false) }
                }
            }
            .navigationTitle("手动加入眼镜 Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
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
                if g.phaseBusy || g.mediaImportInProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(g.canUseGlasses ? Color.green
                              : { if case .failed = g.phase { return Color.red }; return Color.orange }())
                        .frame(width: 7, height: 7)
                }
                Text(g.mediaImportInProgress ? "导入中" : (g.connected && !g.canUseGlasses ? "待验证" : g.phaseText))
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
    formatter.dateFormat = "HH:mm"
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
    @State private var library: Library = .glasses
    @State private var filter: Filter = .all
    @State private var preview: AlbumMediaSelection?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var pendingDeletion: [Capture]?
    @State private var isDeleting = false

    private enum Library: String, CaseIterable { case glasses = "眼镜", local = "本机" }
    private enum Filter: String, CaseIterable { case all = "全部", photo = "照片", video = "视频", pending = "未导入" }

    private struct MediaDay: Identifiable {
        let id: Date
        let captures: [Capture]
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 245 : 140), spacing: 10, alignment: .top)]
    }

    private var canBrowseGlasses: Bool { g.canUseGlasses || g.mediaImportInProgress }
    private var displayedLibrary: Library { canBrowseGlasses ? library : .local }
    private var canDelete: Bool { g.canDeleteGlassesCaptures && !isDeleting }
    private var canStartTransfer: Bool {
        g.canStartMediaImport && !isSelecting && !isDeleting
    }

    private var selectableRows: [Capture] {
        guard displayedLibrary == .glasses else { return [] }
        return rows.filter { !$0.handle.isEmpty && g.importedCaptures[$0.id] == nil }
    }

    private var selectedRows: [Capture] { selectableRows.filter { selectedIDs.contains($0.id) } }

    private var captures: [Capture] {
        var seen: Set<String> = []
        let records = displayedLibrary == .glasses
            ? g.captures
            : g.localCaptures + Array(g.importedCaptures.values)
        return records.filter { seen.insert($0.id).inserted }
            .sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
    }

    private var rows: [Capture] {
        switch filter {
        case .all: return captures
        case .photo: return captures.filter(\.isPhoto)
        case .video: return captures.filter { !$0.isPhoto }
        case .pending:
            return displayedLibrary == .glasses ? captures.filter { g.importedCaptures[$0.id] == nil } : captures
        }
    }

    private var days: [MediaDay] {
        let groups = Dictionary(grouping: rows) { capture -> Date in
            guard let ns = capture.timestampNS else { return .distantPast }
            return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(ns) / 1_000_000_000))
        }
        return groups.keys.sorted(by: >).map { MediaDay(id: $0, captures: groups[$0] ?? []) }
    }

    var body: some View {
        let mediaDays = days
        let eyeIDs = Set(g.captures.map(\.id))
        let selectableIDs = Set(selectableRows.map(\.id))
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    galleryHeader
                    filters.disabled(isSelecting)
                    transferStatus
                    if mediaDays.isEmpty {
                        emptyPanel
                    } else {
                        ForEach(mediaDays) { day in
                            Text(day.id == .distantPast ? "日期未知" : day.id.formatted(date: .long, time: .omitted))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(day.captures, id: \.id) { capture in
                                    mediaTile(capture, presentOnGlasses: eyeIDs.contains(capture.id),
                                              selectable: selectableIDs.contains(capture.id))
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(GlassesTheme.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    selectionBar(selectableIDs: selectableIDs)
                }
            }
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusCapsule(g: g) { openDevice() }
                        .disabled(isSelecting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("完成") { clearSelection() }
                            .disabled(isDeleting)
                    } else {
                        HStack(spacing: 14) {
                            if !selectableIDs.isEmpty {
                                Button("选择") { isSelecting = true }
                                    .disabled(!canDelete)
                            }
                            Button { g.loadCaptures() } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("刷新眼镜相册")
                            .disabled(!canStartTransfer)
                        }
                    }
                }
            }
            .fullScreenCover(item: $preview) { item in
                AlbumMediaView(g: g, media: item)
            }
            .confirmationDialog("删除眼镜中的原件？",
                                isPresented: Binding(
                                    get: { pendingDeletion != nil },
                                    set: { if !$0 { pendingDeletion = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: pendingDeletion) { captures in
                Button("从眼镜删除 \(captures.count) 项", role: .destructive) {
                    deleteConfirmed(captures)
                }
                Button("取消", role: .cancel) {}
            } message: { captures in
                Text("将清除眼镜存储中所选的 \(captures.count) 项未导入原件。")
            }
            .onChange(of: displayedLibrary) { _, source in
                if source == .local {
                    clearSelection()
                    if filter == .pending { filter = .all }
                }
            }
            .onChange(of: selectableIDs) { _, available in
                selectedIDs.formIntersection(available)
            }
            .onDisappear {
                if !isDeleting { clearSelection() }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            if canBrowseGlasses {
                Picker("相册来源", selection: $library) {
                    ForEach(Library.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Menu {
                Picker("筛选媒体", selection: $filter) {
                    ForEach(Filter.allCases.filter { displayedLibrary == .glasses || $0 != .pending }, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
            } label: {
                Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(GlassesTheme.surface, in: Capsule())
            }
            .accessibilityHint("选择要显示的媒体")
        }
    }

    private var galleryHeader: some View {
        let pending = rows.filter { g.importedCaptures[$0.id] == nil }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                galleryTitle
                Spacer(minLength: 8)
                galleryAction(pending: pending)
            }
            VStack(alignment: .leading, spacing: 10) {
                galleryTitle
                galleryAction(pending: pending)
            }
        }
    }

    private var galleryTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayedLibrary == .glasses ? "眼镜相册" : "本机相册")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("\(rows.count) 项")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func galleryAction(pending: [Capture]) -> some View {
        if !g.canUseGlasses {
            Button(g.connected ? "去验证" : "连接眼镜") { openDevice() }
                .buttonStyle(.bordered)
        } else if !isSelecting && displayedLibrary == .glasses && !rows.isEmpty {
            VStack(alignment: .trailing, spacing: 7) {
                if !pending.isEmpty {
                    Button { transfer(pending) } label: {
                        Label("导入 \(pending.count) 项", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartTransfer)
                }
                Menu {
                    Picker("导入方式", selection: $g.importRoute) {
                        ForEach(MediaImportRoute.allCases) { route in Text(route.title).tag(route) }
                    }
                } label: {
                    Label(g.importRoute.title, systemImage: "slider.horizontal.3")
                        .font(.footnote.weight(.medium))
                        .padding(.vertical, 5)
                }
                .accessibilityLabel("导入方式，\(g.importRoute.title)")
                .disabled(!canStartTransfer)
            }
        }
    }

    @ViewBuilder
    private var transferStatus: some View {
        if g.mediaImportInProgress {
            VStack(alignment: .leading, spacing: 7) {
                let title = g.mediaMessage ?? "正在从眼镜导入…"
                if let id = g.mediaImportCurrentID, let fraction = g.progress[id], fraction.isFinite, fraction > 0 {
                    ProgressView(title, value: min(fraction, 1)).font(.footnote)
                } else {
                    ProgressView(title).font(.footnote)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已完成 \(g.mediaImportCompleteCount)/\(g.mediaImportTotal) 项")
                        if let detail = g.transferDetail { Text(detail) }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(g.mediaImportCancelling ? "正在停止…" : "停止导入") { g.cancelMediaImport() }
                        .font(.footnote)
                        .disabled(g.mediaImportCancelling)
                }
            }
            .glassesPanel(padding: 12)
        } else if let message = g.mediaMessage {
            Text(message)
                .font(.footnote)
                .glassesPanel(padding: 12)
        }
    }

    private var emptyPanel: some View {
        VStack(spacing: 9) {
            Image(systemName: displayedLibrary == .glasses ? "photo.on.rectangle" : "tray")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(GlassesTheme.accent)
                .accessibilityHidden(true)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .glassesPanel()
    }

    private var emptyMessage: String {
        if filter != .all { return "没有符合筛选条件的媒体。" }
        if displayedLibrary == .local { return "导入的照片和视频会显示在这里。" }
        return g.busy ? "等待眼镜返回相册…" : "眼镜相册没有可显示的媒体。"
    }

    private func selectionBar(selectableIDs: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDeleting {
                ProgressView("正在从眼镜删除…")
            } else {
                Text("已选择 \(selectedRows.count) 项未导入的媒体")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(selectedIDs == selectableIDs ? "取消全选" : "全选当前") {
                        selectedIDs = selectedIDs == selectableIDs ? [] : selectableIDs
                    }
                    .disabled(selectableIDs.isEmpty || !canDelete)
                    Spacer(minLength: 8)
                    Button("删除所选", role: .destructive) { pendingDeletion = selectedRows }
                        .buttonStyle(.bordered)
                        .disabled(selectedRows.isEmpty || !canDelete)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private func clearSelection() {
        isSelecting = false
        selectedIDs.removeAll()
        pendingDeletion = nil
    }

    private func deleteConfirmed(_ captures: [Capture]) {
        let ids = Set(captures.map(\.id))
        guard isSelecting, canDelete, !ids.isEmpty,
              ids == Set(selectedRows.map(\.id)) else { return }
        isDeleting = true
        Task { @MainActor in
            let removed = await g.deleteGlassesCaptures(captures)
            selectedIDs.subtract(removed)
            isDeleting = false
            if selectedIDs.isEmpty { clearSelection() }
        }
    }

    private func mediaTile(_ capture: Capture, presentOnGlasses: Bool, selectable: Bool) -> some View {
        let item = AlbumMediaSelection(id: capture.id, isPhoto: capture.isPhoto,
                                       original: g.localMediaURL(for: capture), thumbnail: g.thumbs[capture.id],
                                       timestampNS: capture.timestampNS)
        let saved = g.importedCaptures[capture.id] != nil
        let selection: CaptureTile.Selection
        if !isSelecting {
            selection = .inactive
        } else if selectable {
            selection = .eligible(selected: selectedIDs.contains(capture.id), enabled: canDelete, toggle: {
                guard canDelete else { return }
                if selectedIDs.remove(capture.id) == nil { selectedIDs.insert(capture.id) }
            })
        } else {
            selection = .unavailable
        }
        return CaptureTile(capture: capture,
                           media: item,
                           imported: saved,
                           working: g.mediaImportCurrentID == capture.id,
                           failed: g.mediaImportFailedIDs.contains(capture.id),
                           fraction: g.progress[capture.id] ?? 0,
                           canFetch: canStartTransfer && presentOnGlasses,
                           presentOnGlasses: canBrowseGlasses && presentOnGlasses,
                           selection: selection,
                           onOpen: { preview = item },
                           onTransfer: { transfer([capture], originalOnly: saved) })
    }

    private func transfer(_ queue: [Capture], originalOnly: Bool = false) {
        guard canStartTransfer else { return }
        g.startMediaImport(queue, saveToPhotos: !originalOnly)
    }
}

private struct CaptureTile: View {
    enum Selection {
        case inactive
        case unavailable
        case eligible(selected: Bool, enabled: Bool, toggle: () -> Void)
    }

    let capture: Capture
    let media: AlbumMediaSelection
    let imported: Bool
    let working: Bool
    let failed: Bool
    let fraction: Double
    let canFetch: Bool
    let presentOnGlasses: Bool
    let selection: Selection
    let onOpen: () -> Void
    let onTransfer: () -> Void

    private var progress: Double { fraction.isFinite ? min(1, max(0, fraction)) : 0 }
    private var hasOriginal: Bool { media.original != nil }
    private var canOpen: Bool { hasOriginal || media.thumbnail != nil || imported }
    private var mediaKind: String { capture.isPhoto ? "照片" : "视频" }
    private var openTitle: String {
        if hasOriginal { return capture.isPhoto ? "查看原图" : "播放视频" }
        if media.thumbnail != nil { return capture.isPhoto ? "看预览图" : "看视频封面" }
        return "查看详情"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tileCover
            VStack(alignment: .leading, spacing: 7) {
                let time = clockText(capture.timestampNS)
                Text(time.isEmpty ? mediaKind : time)
                    .font(.subheadline.weight(.semibold))
                Text(sizeText(capture.assets.reduce(0) { $0 + $1.size }))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .inactive = selection { primaryControl }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(GlassesTheme.edge).allowsHitTesting(false) }
    }

    @ViewBuilder
    private var tileCover: some View {
        switch selection {
        case .inactive:
            if canOpen {
                Button(action: onOpen) { cover }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(openTitle))
            } else {
                cover
            }
        case .unavailable:
            cover.opacity(0.5)
        case .eligible(let selected, let enabled, let toggle):
            Button(action: toggle) {
                cover.overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(selected ? Color.accentColor : .black.opacity(0.7), in: Circle())
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(Text("\(selected ? "取消选择" : "选择")\(mediaKind) \(clockText(capture.timestampNS))"))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private var cover: some View {
        LinearGradient(colors: [GlassesTheme.console, Color(red: 0.10, green: 0.35, blue: 0.36)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        .aspectRatio(1.18, contentMode: .fit)
        .overlay {
            if let thumbnail = media.thumbnail {
                GeometryReader { bounds in
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: capture.isPhoto ? "photo" : "video")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
            }
            if case .inactive = selection, !capture.isPhoto && hasOriginal {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(11)
                    .background(.black.opacity(0.7), in: Circle())
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(mediaKind)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(7)
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if working {
            if progress > 0 {
                ProgressView(value: progress) {
                    Text("传输中 \(Int(progress * 100))%").font(.caption.monospacedDigit())
                }
            } else {
                ProgressView("处理中").font(.caption)
            }
        } else if imported && hasOriginal {
            Button(action: onOpen) {
                Label(openTitle, systemImage: capture.isPhoto ? "arrow.up.left.and.arrow.down.right" : "play")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 33)
            }
            .buttonStyle(.bordered)
        } else if imported {
            Text(media.thumbnail == nil ? "已导入系统照片" : (capture.isPhoto ? "仅有预览图" : "仅有视频封面"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if presentOnGlasses { transferButton(failed ? "重试下载" : "获取原件") }
        } else if presentOnGlasses {
            transferButton(failed ? "重试导入" : "导入原件")
        } else if hasOriginal {
            Label("已保存在 App", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func transferButton(_ title: String) -> some View {
        Button(action: onTransfer) {
            Label(title, systemImage: failed ? "arrow.clockwise" : "arrow.down")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 33)
        }
        .buttonStyle(.bordered)
        .tint(failed ? .orange : GlassesTheme.accent)
        .disabled(!canFetch)
    }
}

// MARK: - 拍摄

struct ShootTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
    let openAlbum: () -> Void
    @State private var mode: CaptureMode = .photo
    @State private var showLive = false

    private enum CaptureMode: String, CaseIterable {
        case photo = "照片"
        case video = "视频"
    }

    private var cameraTitle: String {
        if g.recording { return "正在录像" }
        if g.mediaImportInProgress { return "正在从眼镜导入" }
        if g.canUseGlasses { return "蓝牙拍摄已就绪" }
        return g.connected ? "拍摄需要验证主人身份" : "眼镜未连接"
    }

    private var shutterTitle: String {
        if g.recording { return "停止录像" }
        if g.queuedGlassesActionText != nil { return "已排队" }
        return mode == .photo ? "拍照" : "开始录像"
    }

    private var cameraActionBlocked: Bool {
        if g.assistantRegistering || g.queuedGlassesActionText != nil { return true }
        return g.mediaImportInProgress ? g.recording : g.busy
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
                    if !g.canUseGlasses && !g.mediaImportInProgress {
                        Button(g.connected ? "验证主人身份" : "连接眼镜") { openDevice() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .glassesPanel()
                    }
                    if let message = g.mediaMessage, !g.mediaImportInProgress {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if g.canUseGlasses || g.mediaImportInProgress {
                    shutterControls
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("拍摄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { openDevice() } }
            }
            .sheet(isPresented: $showLive) { LiveView(g: g) }
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
            if let queued = g.queuedGlassesActionText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(queued, systemImage: "clock")
                        .font(.footnote)
                    Spacer(minLength: 4)
                    Button("取消排队") { g.cancelQueuedGlassesAction() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else if g.mediaImportInProgress && !cameraActionBlocked {
                Label("拍摄会在导入结束后执行。", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("拍摄模式", selection: $mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(cameraActionBlocked || g.recording)

            if mode == .video {
                Picker("手机端停止计时", selection: $g.maxRecordSeconds) {
                    Text("手动停止").tag(0)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("3 分钟").tag(180)
                    Text("5 分钟").tag(300)
                }
                .pickerStyle(.menu)
                .disabled(cameraActionBlocked || g.recording)
            }

            HStack(alignment: .center, spacing: 12) {
                Button(action: openAlbum) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3.weight(.medium))
                        Text("相册").font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)

                shutterButton

                Button { showLive = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                            .font(.title3.weight(.medium))
                        Text("实验取景").font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .disabled(g.busy || g.mediaImportInProgress || g.recording || g.assistantRegistering)
            }
        }
        .glassesPanel(padding: 12)
    }

    private var shutterButton: some View {
        Button {
            if g.recording || mode == .video { g.toggleRecording() }
            else { g.snap() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(GlassesTheme.console)
                        .frame(width: 72, height: 72)
                    Circle()
                        .strokeBorder(shutterColor, lineWidth: 2)
                        .frame(width: 63, height: 63)
                    RoundedRectangle(cornerRadius: g.recording ? 5 : 24)
                        .fill(shutterColor)
                        .frame(width: g.recording ? 25 : 48, height: g.recording ? 25 : 48)
                }
                .accessibilityHidden(true)
                Text(shutterTitle).font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .disabled(cameraActionBlocked)
        .opacity(cameraActionBlocked ? 0.5 : 1)
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
    @State private var showSpokenQuestion = false
    @State private var includePhoto = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modelCard
                    voiceCard
                    if !g.assistantAnswer.isEmpty {
                        responseCard(title: "眼镜语音回复", text: g.assistantAnswer)
                    }
                    if g.askingModel {
                        ProgressView("正在请求 \(g.modelName)…").glassesPanel()
                    } else if !g.answer.isEmpty {
                        responseCard(title: "输入问答", text: g.answer)
                    }
                }
                .padding(18)
            }
            .background(GlassesTheme.page.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusCapsule(g: g) { openDevice() } }
            }
            .sheet(isPresented: $showModel) { ModelSheet(g: g) }
            .sheet(isPresented: $showSpokenQuestion) {
                SpokenQuestionView(glassesName: g.connectedGlassesName, modelName: g.modelName) { prompt in
                    g.ask(prompt)
                }
            }
        }
    }

    private var modelCard: some View {
        Button {
            showModel = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle").foregroundStyle(GlassesTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前模型").font(.caption).foregroundStyle(.secondary)
                    Text(g.modelName.isEmpty ? "选择模型" : g.modelName)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Label("设置", systemImage: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassesTheme.accent)
            }
            .contentShape(Rectangle())
            .glassesPanel()
        }
        .buttonStyle(.plain)
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hey Meta 交给 GlassesLink", systemImage: "mic")
                .font(.headline)
            if g.assistantRegistering {
                ProgressView("等眼镜确认注册…").font(.subheadline)
            } else if g.canUseGlasses {
                Button(g.assistantOn ? "关闭 Hey Meta 接管" : "开启 Hey Meta 接管") {
                    if g.assistantOn { g.stopAssistant() } else { g.startAssistant() }
                }
                .buttonStyle(.bordered)
                .disabled(!g.assistantOn && !g.canStartAssistant)
            } else {
                Button("连接眼镜") { openDevice() }.buttonStyle(.bordered)
            }
            if let message = g.assistantMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            } else if g.canUseGlasses && !g.assistantOn && !g.assistantRegistering {
                Text(g.assistantAutoStart ? "连上眼镜后会自动开启。" : "已关闭；点上面的按钮重新开启。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("开启后直接对眼镜说「Hey Meta，what is your name?」，回答会在眼镜里播出。拍照、录像、音量这些指令由眼镜自己处理，不经过 App。目前先用英文提问。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                typing = false
                showSpokenQuestion = true
            } label: {
                Label("点按说话", systemImage: "waveform.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(g.askingModel || g.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if g.assistantTranscriptMissing {
                Button("打开键盘听写") { typing = true }
                    .buttonStyle(.bordered)
                Text("点键盘上的麦克风，说完后确认文字，再发送。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassesPanel()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if g.hasPhotoForModel {
                Toggle("附上最近一张照片", isOn: $includePhoto)
                    .font(.footnote)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入问题", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(GlassesTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                Button {
                    let prompt = question
                    question = ""
                    typing = false
                    g.ask(prompt, includePhoto: includePhoto && g.hasPhotoForModel)
                } label: {
                    Image(systemName: "arrow.up").font(.headline.weight(.bold))
                        .frame(minWidth: 32, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("发送问题")
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || g.askingModel)
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private func responseCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(GlassesTheme.accent)
            Text(text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassesPanel()
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
        case .verified: return "本机可以访问眼镜的拍摄、相册和设置。"
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var audioTest = AudioRouteTest()
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showMicrophoneCheck = false

    private var candidates: [ScanEntry] {
        g.primaryDevices.sorted { $0.isListedBefore($1) }
    }

    private var connectionTitle: String {
        if g.canUseGlasses { return "眼镜控制已连接" }
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
                    settingsEntry
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        OwnerBadge(g: g)
                        Button("设置主人身份") { g.route = .ownerSetup }
                            .buttonStyle(.bordered)
                    }
                    .glassesPanel()
                }
                audioPanel
                advancedPanel
            }
            .padding(18)
        }
        .background(GlassesTheme.page.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { NavigationStack { GlassesSettingsView(g: g) } }
        .sheet(isPresented: $showDiagnostics) { NavigationStack { ContentView(g: g) } }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showMicrophoneCheck) { MicrophoneCheckView(glassesName: g.connectedGlassesName) }
        .onDisappear { stopAudioTest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopAudioTest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                stopAudioTest()
            }
        }
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
                    if let name = g.connectedGlassesName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !name.isEmpty, name != "?", UUID(uuidString: name) == nil {
                        Text(name).font(.subheadline.weight(.medium))
                    }
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
        let listed = candidates
        let verified = listed.filter(\.isVerified)
        let nearby = listed.filter { !$0.isVerified && !$0.needsIdentification }
        let unidentified = listed.filter(\.needsIdentification)

        return VStack(alignment: .leading, spacing: 12) {
            if !verified.isEmpty {
                Label("已验证的眼镜", systemImage: "checkmark.shield")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(verified) { candidateRow($0) }
            }
            if !nearby.isEmpty || !unidentified.isEmpty || verified.isEmpty || g.scanning || g.discoveryMessage != nil {
                if !verified.isEmpty { Divider() }

                Text("待确认的设备")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let message = g.discoveryMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                } else if nearby.isEmpty && unidentified.isEmpty {
                    if g.scanning {
                        ProgressView("扫描附近的眼镜…").font(.footnote)
                    }
                    Text(g.hasSavedGlasses && !g.scanning
                         ? "眼镜开机并在手机附近时，可以直接重连。"
                         : "首次连接时，将开机的眼镜放回充电盒，按住盒背按钮约 5 秒，等指示灯闪蓝后扫描。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(nearby) { candidateRow($0) }
                if !unidentified.isEmpty {
                    DisclosureGroup("更多蓝牙候选（\(unidentified.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这些广播的眼镜名称还待确认。名称缺失时，用 iPhone 蓝牙标识的后四位区分条目。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(unidentified) { candidateRow($0) }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
            }
            if g.hasSavedGlasses && !g.scanning && !g.phaseBusy {
                Button("扫描眼镜") { g.startScan() }.buttonStyle(.bordered)
            }
        }
        .glassesPanel()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("眼镜状态").font(.headline)
                Spacer()
                if g.statusRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在读取眼镜状态")
                }
                Button { g.refreshStatus() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 34)
                }
                .accessibilityLabel("刷新眼镜状态")
                .disabled(g.statusRefreshing)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 180 : 126), spacing: 8)], spacing: 8) {
                let charge = g.status.batteryCharge
                statusMetric("眼镜电量", value: g.status.batteryPercent.map { "\($0)%" },
                             icon: charge == .charging || charge == .chargingLow ? "bolt.fill" : "battery.100",
                             detail: charge?.label)
                caseBatteryMetric
                statusMetric("可用空间", value: g.status.storageFreeMb.map(storageText), icon: "internaldrive")
                statusMetric("眼镜音量", value: g.status.volumePercent.map { "\($0)%" }, icon: "speaker.wave.2")
            }
            if let message = g.statusMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .glassesPanel()
    }

    private var caseBatteryMetric: some View {
        let current = g.status.caseBattery
        let reading = current?.reading ?? g.status.lastCaseBatteryReading
        let time = reading.map { $0.observedAt.formatted(date: .abbreviated, time: .shortened) }
        let timestamp = time.map { current?.reading != nil ? "上报于 \($0)" : "上次上报 \($0)" }
        let detail = [current?.label, timestamp].compactMap { $0 }.joined(separator: "\n")
        return statusMetric("充电盒电量", value: reading?.level.label,
                            icon: current?.charging == true ? "bolt.fill" : "shippingbox",
                            detail: detail.isEmpty ? nil : detail)
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: g.audioRouteUsesBluetooth ? "headphones" : "speaker.wave.2")
                    .font(.title3)
                    .foregroundStyle(GlassesTheme.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("蓝牙音频与麦克风").font(.headline)
                    Text("播放输出 · \(g.audioRouteName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("当前播放输出，\(g.audioRouteName)")
                    if let profile = g.audioMediaProfile {
                        Text(profile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                AudioOutputPicker()
                    .frame(width: 44, height: 44)
            }
            Text("拍摄和导入走眼镜控制连接。播放声音由 iPhone 选择音频设备。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            glassesAudioStatus
            Button {
                if audioTest.isPlaying { stopAudioTest() }
                else { audioTest.start { g.readAudioOutput() } }
            } label: {
                Label(audioTest.isPlaying ? "停止测试音" : "播放测试音",
                      systemImage: audioTest.isPlaying ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.bordered)
            if let error = audioTest.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            Text(audioTest.isPlaying
                 ? "测试音持续 15 秒。可打开 iPhone 控制中心，在播放卡片中选择眼镜。"
                 : "播放视频或其他 App 时，在控制中心的播放卡片中选择眼镜。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            actionRow("测试眼镜麦克风", icon: "mic") {
                stopAudioTest()
                showMicrophoneCheck = true
            }
        }
        .glassesPanel(padding: 13)
    }

    /// Only a system Bluetooth pairing makes the glasses an iPhone headset, so this says which
    /// state iOS is in and, when needed, walks through the repair that fixed the 0.99 report.
    @ViewBuilder private var glassesAudioStatus: some View {
        switch g.glassesAudio {
        case .glasses(let profile):
            Label("眼镜音频已接通 · \(profile)", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassesTheme.accent)
        case .otherBluetooth(let name):
            Text("当前声音走「\(name)」。要用眼镜，请在右上角的输出选择或控制中心里选眼镜。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .unavailable:
            VStack(alignment: .leading, spacing: 5) {
                Text("眼镜还不是 iPhone 的耳机，修复一次即可：").font(.footnote.weight(.semibold))
                Text("1. 设置 → 蓝牙：「我的设备」里已有眼镜就点 ⓘ →「忽略此设备」")
                Text("2. 折叠眼镜，长按拍摄键约 5 秒到指示灯闪蓝，再展开")
                Text("3. 在「设置 → 蓝牙 → 其他设备」里点眼镜，弹窗选「配对」")
                Text("4. 回到这里，会自动显示「眼镜音频已接通」")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func stopAudioTest() {
        guard audioTest.isPlaying else { return }
        audioTest.stop()
        g.readAudioOutput()
    }

    private func statusMetric(_ title: String, value: String?, icon: String, detail: String? = nil) -> some View {
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
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(GlassesTheme.page, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private func storageText(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    /// The glasses' own settings, one tap from the 眼镜 tab (it used to sit under 高级 › 完整设置列表).
    private var settingsEntry: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(GlassesTheme.accent.opacity(0.13))
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(GlassesTheme.accent)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("眼镜设置").font(.headline).foregroundStyle(.primary)
                    Text("Hey Meta、拍摄画质、声音、佩戴检测、来电播报等 \(CuratedSettings.all.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(g.busy)
        .glassesPanel(padding: 14)
    }

    private var advancedPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 13) {
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
                Text("眼镜的自动更新开关在「眼镜设置 › 隐私与更新」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        let detail = device.nameSourceLabel.map { "\(device.sourceLabel) · \($0)" } ?? device.sourceLabel
        return Button { g.connect(device.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: device.isVerified ? "eyeglasses" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(GlassesTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let alias = device.alternateAdvertisementName {
                        Text("广播名称 · \(alias)").font(.caption).foregroundStyle(.secondary)
                    }
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
