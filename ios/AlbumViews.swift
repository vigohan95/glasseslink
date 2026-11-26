import SwiftUI
import UIKit

// MARK: - 相册

/// Everything shot with the glasses, three across and grouped by day. A badge on each tile says where
/// it lives; one tap opens what is on the phone, or fetches what is still on the glasses.
struct AlbumTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
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

    /// The album as shown right now. Built once per body pass and handed to every part of the screen,
    /// so one publish (several a second during an import) sorts and groups the library a single time.
    private struct Snapshot {
        var days: [MediaDay] = []
        var rowCount = 0
        /// Shown items that are not on the phone yet (glasses library only).
        var pending: [Capture] = []
        /// Shown items that may be deleted from the glasses.
        var selectable: [Capture] = []
        var selectableIDs: Set<String> = []
        var glassesIDs: Set<String> = []
    }

    init(g: Glasses, openDevice: @escaping () -> Void) {
        self.g = g
        self.openDevice = openDevice
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    }

    private var canBrowseGlasses: Bool { g.canUseGlasses || g.mediaImportInProgress }
    private var displayedLibrary: Library { canBrowseGlasses ? library : .local }
    private var canDelete: Bool { g.canDeleteGlassesCaptures && !isDeleting }
    private var canStartTransfer: Bool {
        g.canStartMediaImport && !isSelecting && !isDeleting
    }

    private var availableFilters: [Filter] {
        Filter.allCases.filter { displayedLibrary == .glasses || $0 != .pending }
    }

    private func makeSnapshot() -> Snapshot {
        let source = displayedLibrary
        let imported = g.importedCaptures
        let records: [Capture]
        if source == .glasses {
            records = g.captures
        } else {
            records = g.localCaptures + Array(imported.values)
        }
        var seen: Set<String> = []
        let unique = records.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }

        let rows: [Capture]
        switch filter {
        case .all:
            rows = sorted
        case .photo:
            rows = sorted.filter { $0.isPhoto }
        case .video:
            rows = sorted.filter { !$0.isPhoto }
        case .pending:
            rows = source == .glasses ? sorted.filter { imported[$0.id] == nil } : sorted
        }

        var snapshot = Snapshot()
        snapshot.rowCount = rows.count
        snapshot.glassesIDs = Set(g.captures.map { $0.id })
        if source == .glasses {
            let waiting = rows.filter { imported[$0.id] == nil }
            // Everything on the glasses can be deleted there; what is already on the phone most of all.
            let deletable = rows.filter { !$0.handle.isEmpty }
            snapshot.pending = waiting
            snapshot.selectable = deletable
            snapshot.selectableIDs = Set(deletable.map { $0.id })
        }

        // Rows are newest first, so each day's captures keep that order.
        let calendar = Calendar.current
        var dayOrder: [Date] = []
        var buckets: [Date: [Capture]] = [:]
        for capture in rows {
            var day = Date.distantPast
            if let moment = GlassesFormat.captureDate(capture.timestampNS) {
                day = calendar.startOfDay(for: moment)
            }
            if buckets[day] == nil {
                dayOrder.append(day)
                buckets[day] = [capture]
            } else {
                buckets[day]?.append(capture)
            }
        }
        dayOrder.sort(by: >)
        snapshot.days = dayOrder.map { MediaDay(id: $0, captures: buckets[$0] ?? []) }
        return snapshot
    }

    var body: some View {
        let snapshot = makeSnapshot()
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    controls(snapshot)
                    gallery(snapshot)
                }
                .padding(.horizontal, GlassesTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .glassesPage()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar(snapshot)
            }
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    barItems(hasSelectable: !snapshot.selectableIDs.isEmpty)
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
                let unsaved = captures.filter { g.importedCaptures[$0.id] == nil }.count
                Text(unsaved == 0
                     ? "这 \(captures.count) 项已经导入到 iPhone，只删除眼镜里的那一份。"
                     : "其中 \(unsaved) 项还没有导入，从眼镜删除后无法找回。")
            }
            .onChange(of: displayedLibrary) { _, source in
                if source == .local {
                    clearSelection()
                    if filter == .pending { filter = .all }
                }
            }
            .onChange(of: snapshot.selectableIDs) { _, available in
                selectedIDs.formIntersection(available)
            }
            .onDisappear {
                if !isDeleting { clearSelection() }
            }
        }
    }

    // MARK: 顶部

    @ViewBuilder
    private func barItems(hasSelectable: Bool) -> some View {
        if isSelecting {
            Button("完成") { clearSelection() }
                .fontWeight(.semibold)
                .disabled(isDeleting)
        } else {
            HStack(spacing: 16) {
                if displayedLibrary == .glasses {
                    Button("选择") { isSelecting = true }
                        .disabled(!canDelete || !hasSelectable)
                }
                Button {
                    Haptics.tap()
                    g.loadCaptures(announce: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新眼镜相册")
                .disabled(!canStartTransfer)
            }
        }
    }

    private func controls(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !canBrowseGlasses {
                ConnectHintCard(g: g,
                                purpose: "连接后可以浏览和导入眼镜里的照片、视频。已经导入的内容随时能看。",
                                openDevice: openDevice)
            }
            if canBrowseGlasses {
                Picker("相册来源", selection: $library) {
                    ForEach(Library.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSelecting)
            }
            chips
                .disabled(isSelecting)
            importCard(snapshot)
            statusLine
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableFilters, id: \.self) { option in
                    FilterChip(title: option.rawValue, selected: filter == option) {
                        filter = option
                    }
                }
            }
        }
    }

    /// "N 项还没导入" with the one obvious action; the route choice sits beside it.
    @ViewBuilder
    private func importCard(_ snapshot: Snapshot) -> some View {
        if g.canUseGlasses && displayedLibrary == .glasses && !snapshot.pending.isEmpty
            && !isSelecting && !g.mediaImportInProgress {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("\(snapshot.pending.count) 项还没导入")
                        .font(.headline)
                    Spacer(minLength: 8)
                    routeMenu
                }
                Button {
                    startTransfer(snapshot.pending, originalOnly: false)
                } label: {
                    Label("导入 \(snapshot.pending.count) 项", systemImage: "arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canStartTransfer)
            }
            .glassesCard()
        }
    }

    private var routeMenu: some View {
        Menu {
            Picker("导入方式", selection: $g.importRoute) {
                ForEach(MediaImportRoute.allCases) { route in
                    Text(route.title).tag(route)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(g.importRoute.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("导入方式，\(g.importRoute.title)")
        .disabled(!canStartTransfer)
    }

    /// What the glasses last said about the album (reading, empty, a failed import), outside an import.
    @ViewBuilder
    private var statusLine: some View {
        if let message = g.mediaMessage, !g.mediaImportInProgress {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if g.busy {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .glassesCard(padding: 14)
        }
    }

    // MARK: 网格

    @ViewBuilder
    private func gallery(_ snapshot: Snapshot) -> some View {
        if snapshot.days.isEmpty {
            emptyState
        } else {
            ForEach(snapshot.days) { day in
                Text(GlassesFormat.dayTitle(day.id))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(day.captures, id: \.id) { capture in
                        tile(capture, snapshot: snapshot)
                    }
                }
            }
            Text("共 \(snapshot.rowCount) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
    }

    private var emptyTitle: String {
        if filter != .all { return "没有符合条件的内容" }
        if displayedLibrary == .local { return "还没有导入的内容" }
        return g.busy ? "正在读取眼镜相册…" : "眼镜里没有照片或视频"
    }

    private var emptyDetail: String {
        if filter != .all { return "换一个筛选条件试试。" }
        if displayedLibrary == .local { return "从眼镜导入的照片和视频会出现在这里。" }
        return g.busy ? "马上就好。" : "拍一张试试，或点右上角的刷新。"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: displayedLibrary == .glasses ? "photo.on.rectangle.angled" : "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(emptyTitle)
                .font(.headline)
                .padding(.top, 4)
            Text(emptyDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func tile(_ capture: Capture, snapshot: Snapshot) -> some View {
        let item = AlbumMediaSelection(id: capture.id, isPhoto: capture.isPhoto,
                                       original: g.localMediaURL(for: capture),
                                       thumbnail: g.thumbs[capture.id],
                                       timestampNS: capture.timestampNS,
                                       processed: LocalMediaLibrary.processedURL(for: capture))
        let imported = g.importedCaptures[capture.id] != nil
        let onGlasses = canBrowseGlasses && snapshot.glassesIDs.contains(capture.id)
        let selectable = snapshot.selectableIDs.contains(capture.id)
        let failed = g.mediaImportFailedIDs.contains(capture.id)
        let mode: MediaTile.Mode
        if !isSelecting {
            mode = .browse
        } else if selectable {
            mode = .select(selectedIDs.contains(capture.id))
        } else {
            mode = .locked
        }
        return MediaTile(capture: capture,
                         thumbnail: item.thumbnail,
                         hasOriginal: item.original != nil,
                         imported: imported,
                         onGlasses: onGlasses,
                         showsSavedBadge: displayedLibrary == .glasses,
                         working: g.mediaImportCurrentID == capture.id,
                         failed: failed,
                         fraction: g.progress[capture.id] ?? 0,
                         mode: mode,
                         onTap: {
                             tapped(capture, item: item, imported: imported,
                                    onGlasses: onGlasses, selectable: selectable)
                         })
            .contextMenu {
                if !isSelecting {
                    tileMenu(capture, item: item, imported: imported, onGlasses: onGlasses, failed: failed)
                    if onGlasses && selectable && canDelete {
                        Button(role: .destructive) {
                            isSelecting = true
                            selectedIDs = [capture.id]
                            pendingDeletion = [capture]
                        } label: {
                            Label("从眼镜删除", systemImage: "trash")
                        }
                    }
                }
            }
    }

    /// Long-press: the same actions as a tap, plus fetching an original that only went to iPhone Photos.
    @ViewBuilder
    private func tileMenu(_ capture: Capture, item: AlbumMediaSelection, imported: Bool,
                          onGlasses: Bool, failed: Bool) -> some View {
        if item.original != nil || item.thumbnail != nil || imported {
            Button {
                preview = item
            } label: {
                Label("查看", systemImage: "eye")
            }
        }
        if onGlasses && !imported {
            Button {
                startTransfer([capture], originalOnly: false)
            } label: {
                Label(failed ? "重试导入" : "导入到 iPhone", systemImage: "arrow.down.circle")
            }
        }
        if onGlasses && imported && item.original == nil {
            Button {
                startTransfer([capture], originalOnly: true)
            } label: {
                Label(failed ? "重试下载原件" : "把原件下载到 App", systemImage: "arrow.down.doc")
            }
        }
    }

    private func tapped(_ capture: Capture, item: AlbumMediaSelection, imported: Bool,
                        onGlasses: Bool, selectable: Bool) {
        if isSelecting {
            guard selectable, canDelete else { return }
            if selectedIDs.remove(capture.id) == nil { selectedIDs.insert(capture.id) }
            return
        }
        if item.original != nil || item.thumbnail != nil || imported {
            preview = item
            return
        }
        if onGlasses {
            startTransfer([capture], originalOnly: false)
        }
    }

    private func startTransfer(_ queue: [Capture], originalOnly: Bool) {
        guard canStartTransfer else {
            g.showToast(g.mediaImportInProgress ? "正在导入，请等这一批结束。" : "眼镜正忙，请稍后再试。")
            return
        }
        Haptics.tap()
        g.startMediaImport(queue, saveToPhotos: !originalOnly)
    }

    // MARK: 底部

    @ViewBuilder
    private func bottomBar(_ snapshot: Snapshot) -> some View {
        if isSelecting {
            selectionBar(snapshot)
        } else if g.mediaImportInProgress {
            ImportProgressCard(g: g)
        }
    }

    private func selectionBar(_ snapshot: Snapshot) -> some View {
        let chosen = snapshot.selectable.filter { selectedIDs.contains($0.id) }
        let everything = snapshot.selectableIDs
        let allSelected = !everything.isEmpty && selectedIDs == everything
        return VStack(alignment: .leading, spacing: 10) {
            if isDeleting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在从眼镜删除…")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                Text(chosen.isEmpty ? "选择要从眼镜删除的项目。已导入的在 iPhone 上还有一份。" : "已选择 \(chosen.count) 项")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(allSelected ? "取消全选" : "全选") {
                        selectedIDs = allSelected ? [] : everything
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(everything.isEmpty || !canDelete)
                    Button("从眼镜删除") {
                        pendingDeletion = chosen
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Color.red))
                    .disabled(chosen.isEmpty || !canDelete)
                }
            }
        }
        .padding(.horizontal, GlassesTheme.pagePadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func clearSelection() {
        isSelecting = false
        selectedIDs.removeAll()
        pendingDeletion = nil
    }

    private func deleteConfirmed(_ captures: [Capture]) {
        let ids = Set(captures.map { $0.id })
        let current = makeSnapshot().selectable.filter { selectedIDs.contains($0.id) }
        guard isSelecting, canDelete, !ids.isEmpty,
              ids == Set(current.map { $0.id }) else { return }
        isDeleting = true
        Task { @MainActor in
            let removed = await g.deleteGlassesCaptures(captures)
            selectedIDs.subtract(removed)
            isDeleting = false
            if selectedIDs.isEmpty { clearSelection() }
            if removed.isEmpty {
                g.showToast("没有删除，请刷新后再试", .failure)
            } else if removed.count < ids.count {
                g.showToast("删除了 \(removed.count)/\(ids.count) 项", .failure)
            } else {
                g.showToast("已从眼镜删除 \(removed.count) 项", .success)
            }
        }
    }
}

// MARK: - 导入进度

/// The one card that speaks for a running import, pinned above the tab bar.
private struct ImportProgressCard: View {
    @ObservedObject var g: Glasses

    private var title: String {
        if g.mediaImportCancelling { return "正在停止…" }
        let total = g.mediaImportTotal
        if total <= 0 { return "正在准备导入…" }
        return "正在导入 \(min(g.mediaImportCompleteCount + 1, total))/\(total)"
    }

    /// Finished items plus the share of the one in flight.
    private var overall: Double {
        let total = g.mediaImportTotal
        guard total > 0 else { return 0 }
        var current = 0.0
        if let id = g.mediaImportCurrentID, let fraction = g.progress[id], fraction.isFinite {
            current = min(1, max(0, fraction))
        }
        return min(1, (Double(g.mediaImportCompleteCount) + current) / Double(total))
    }

    private var detail: String {
        g.transferDetail ?? g.mediaMessage ?? "正在准备…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("停止") {
                    g.cancelMediaImport()
                }
                .buttonStyle(SecondaryButtonStyle(tint: Color.red, fillsWidth: false))
                .disabled(g.mediaImportCancelling)
                .accessibilityLabel("停止导入")
            }
            ThinBar(fraction: overall)
            Text(detail)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("请停在 GlassesLink，屏幕会保持常亮。切到别的 App 或锁屏会暂停，回来后自动继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: GlassesTheme.card)
        .overlay {
            GlassesTheme.card.strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 缩略图

/// One square in the grid. Bottom-left: a play mark on videos. Bottom-right: where the item lives —
/// a checkmark once it is on the phone, an arrow while it is only on the glasses.
private struct MediaTile: View {
    enum Mode {
        case browse
        case locked
        case select(Bool)
    }

    let capture: Capture
    let thumbnail: UIImage?
    let hasOriginal: Bool
    let imported: Bool
    let onGlasses: Bool
    let showsSavedBadge: Bool
    let working: Bool
    let failed: Bool
    let fraction: Double
    let mode: Mode
    let onTap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private var saved: Bool { hasOriginal || imported }

    private var selection: Bool? {
        if case .select(let chosen) = mode { return chosen }
        return nil
    }

    private var isLocked: Bool {
        if case .locked = mode { return true }
        return false
    }

    private var spokenLabel: String {
        var parts: [String] = [capture.isPhoto ? "照片" : "视频"]
        let time = GlassesFormat.clock(capture.timestampNS)
        if !time.isEmpty { parts.append(time) }
        if working {
            parts.append("正在导入")
        } else if failed {
            parts.append("导入失败")
        } else if saved {
            parts.append("已导入")
        } else if onGlasses {
            parts.append("还在眼镜里")
        }
        return parts.joined(separator: "，")
    }

    private var spokenHint: String {
        if selection != nil { return "轻点选择或取消选择" }
        if isLocked { return "" }
        if saved || thumbnail != nil { return "轻点查看" }
        return onGlasses ? "轻点导入" : ""
    }

    var body: some View {
        Button(action: onTap) {
            face
        }
        .buttonStyle(TileButtonStyle())
        .disabled(isLocked)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(spokenHint)
        .accessibilityAddTraits(selection == true ? .isSelected : [])
    }

    private var face: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { picture }
            .clipShape(shape)
            .overlay(alignment: .bottomLeading) {
                if !capture.isPhoto {
                    badge("play.fill", tint: Color.primary)
                }
            }
            .overlay(alignment: .bottomTrailing) { statusBadge }
            .overlay(alignment: .topTrailing) { selectionMark }
            .overlay {
                if working {
                    ProgressRing(fraction: fraction)
                        .padding(7)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .contentShape(shape)
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            GeometryReader { bounds in
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: bounds.size.width, height: bounds.size.height)
                    .clipped()
            }
        } else {
            ZStack {
                GlassesTheme.fill
                Image(systemName: capture.isPhoto ? "photo" : "video")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if working || selection != nil {
            EmptyView()
        } else if failed {
            badge("exclamationmark", tint: Color.orange)
        } else if saved {
            if showsSavedBadge {
                badge("checkmark", tint: GlassesTheme.accent)
            }
        } else if onGlasses {
            badge("arrow.down", tint: Color.primary)
        }
    }

    @ViewBuilder
    private var selectionMark: some View {
        if let chosen = selection {
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(chosen ? GlassesTheme.accent : Color.secondary)
                .background(.regularMaterial, in: Circle())
                .padding(5)
                .accessibilityHidden(true)
        }
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(.regularMaterial, in: Circle())
            .padding(5)
            .accessibilityHidden(true)
    }
}
