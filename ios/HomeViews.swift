import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - 眼镜

/// The home screen. Connected: what the glasses are doing, the three things done every day, and the
/// way into everything else. Not connected: what to do next, one button, and the glasses nearby.
struct HomeTab: View {
    @ObservedObject var g: Glasses
    let openTab: (AppTab) -> Void
    @State private var showSettings = false
    @State private var showMore = false
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showMicrophoneCheck = false

    init(g: Glasses, openTab: @escaping (AppTab) -> Void) {
        self.g = g
        self.openTab = openTab
    }

    /// A Wi-Fi import lends the Bluetooth link out for a moment; that is not "disconnected".
    private var linkReady: Bool { g.canUseGlasses || g.mediaImportInProgress }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GlassesTheme.sectionSpacing) {
                    if linkReady {
                        HomeStatusCard(g: g)
                        HomeQuickActions(g: g, openTab: openTab)
                        HomeActivityLine(g: g, openTab: openTab)
                    } else {
                        HomeConnectCard(g: g)
                        if !g.connected {
                            HomeNearbyList(g: g)
                        }
                    }
                    menuCard
                    Text("GlassesLink \(BuildInfo.short)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, GlassesTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.25), value: linkReady)
            }
            .glassesPage()
            .navigationTitle("眼镜")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { statePill }
            }
            // Pushed by state, not by a NavigationLink inside the card: the row can come and go with the
            // connection without popping the page.
            .navigationDestination(isPresented: $showMore) {
                MoreView(g: g,
                         showDiagnostics: $showDiagnostics,
                         showAbout: $showAbout,
                         showMicrophoneCheck: $showMicrophoneCheck)
            }
        }
        // Presented from the stack itself, so they survive whatever the pushed page does.
        .sheet(isPresented: $showSettings) {
            NavigationStack { GlassesSettingsView(g: g) }
                .overlay(alignment: .top) { ToastOverlay(g: g, announces: false) }
        }
        .sheet(isPresented: $showDiagnostics) { NavigationStack { ContentView(g: g) } }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showMicrophoneCheck) {
            MicrophoneCheckView(glassesName: g.connectedGlassesName)
        }
    }

    private var statePill: StatePill {
        if g.canUseGlasses { return StatePill(text: "已连接", tone: .good) }
        if g.mediaImportInProgress { return StatePill(text: "导入中", tone: .busy) }
        if g.phaseBusy { return StatePill(text: "连接中…", tone: .busy) }
        if g.connected { return StatePill(text: "待验证主人", tone: .attention) }
        if g.scanning { return StatePill(text: "搜索中…", tone: .busy) }
        return StatePill(text: "未连接", tone: .idle)
    }

    private var heyMetaSubtitle: String {
        if g.assistantRegistering { return "正在开启…" }
        if g.assistantOn {
            let model = g.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "已接管" : "已接管 · 由 \(model) 回答"
        }
        return "未开启"
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            Button {
                showSettings = true
            } label: {
                CardRow(icon: "slider.horizontal.3", title: "眼镜设置",
                        subtitle: g.canUseGlasses ? "拍摄画质、声音、佩戴检测、Hey Meta" : "连接眼镜后可以修改")
            }
            .buttonStyle(RowButtonStyle())
            CardRowDivider()
            Button {
                openTab(.assistant)
            } label: {
                CardRow(icon: "waveform", title: "Hey Meta", subtitle: heyMetaSubtitle)
            }
            .buttonStyle(RowButtonStyle())
            CardRowDivider()
            Button {
                showMore = true
            } label: {
                CardRow(icon: "ellipsis.circle", title: "更多", subtitle: "声音输出、主人身份、诊断、关于")
            }
            .buttonStyle(RowButtonStyle())
        }
        .background(GlassesTheme.surface, in: GlassesTheme.card)
    }
}

// MARK: 已连接

/// The hero card: which glasses, what they are doing, battery and free space.
private struct HomeStatusCard: View {
    @ObservedObject var g: Glasses

    private var name: String {
        g.connectedGlassesName ?? "Ray-Ban Meta"
    }

    private var soundLine: String {
        switch g.glassesAudio {
        case .glasses:
            return g.audioRouteUsesBluetooth ? "声音从眼镜播放" : "声音从 iPhone 播放"
        case .otherBluetooth(let other):
            return "声音从「\(other)」播放"
        default:
            return "声音从 iPhone 播放"
        }
    }

    private var statusLine: String {
        if !g.canUseGlasses { return "正在导入，蓝牙连接稍后恢复" }
        var parts: [String] = []
        if g.recording {
            parts.append("正在录像")
        } else if let mount = g.status.mount {
            parts.append(mount == "DON" ? "已戴上" : "已摘下")
        }
        parts.append(soundLine)
        return parts.joined(separator: " · ")
    }

    /// The charging case and the volume: worth one line, not two more meters.
    private var extrasLine: String? {
        var parts: [String] = []
        let box = g.status.caseBattery
        if let reading = box?.reading {
            parts.append(box?.charging == true ? "充电盒 \(reading.level.label)，充电中" : "充电盒 \(reading.level.label)")
        } else if let last = g.status.lastCaseBatteryReading {
            let time = last.observedAt.formatted(date: .omitted, time: .shortened)
            parts.append("充电盒 \(last.level.label)（\(time) 时）")
        }
        if let volume = g.status.volumePercent {
            parts.append("音量 \(volume)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 20) {
                batteryMeter
                storageMeter
            }
            footnotes
        }
        .glassesCard(padding: 18)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(GlassesTheme.accent)
                .frame(width: 54, height: 54)
                .background(GlassesTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button {
            Haptics.tap()
            g.refreshStatus()
        } label: {
            ZStack {
                if g.statusRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .foregroundStyle(GlassesTheme.accent)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!g.canUseGlasses)
        .allowsHitTesting(!g.statusRefreshing)
        .accessibilityLabel(g.statusRefreshing ? "正在读取眼镜状态" : "刷新眼镜状态")
    }

    private var batteryMeter: some View {
        let percent = g.status.batteryPercent
        let low = (percent ?? 100) < 20
        return HomeMeter(title: "电量",
                         value: percent.map { "\($0)%" } ?? "—",
                         detail: g.status.batteryCharge?.label,
                         fraction: percent.map { Double($0) / 100 },
                         tint: low ? Color.red : GlassesTheme.accent)
    }

    private var storageMeter: some View {
        let free = g.status.storageFreeMb
        let total = g.status.storageTotalMb
        var fraction: Double?
        if let free, let total, total > 0 {
            fraction = Double(free) / Double(total)
        }
        return HomeMeter(title: "可用空间",
                         value: free.map { GlassesFormat.storage($0) } ?? "—",
                         detail: total.map { "共 \(GlassesFormat.storage($0))" },
                         fraction: fraction,
                         tint: GlassesTheme.accent)
    }

    @ViewBuilder
    private var footnotes: some View {
        if let extras = extrasLine {
            Text(extras)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let message = g.statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HomeMeter: View {
    let title: String
    let value: String
    let detail: String?
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ThinBar(fraction: fraction, tint: tint)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 拍照 · 录像 · 导入: the same calls the 拍摄 and 相册 tabs make, one tap from the home screen.
private struct HomeQuickActions: View {
    @ObservedObject var g: Glasses
    let openTab: (AppTab) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cameraBlocked: Bool {
        if g.assistantRegistering || g.queuedGlassesActionText != nil { return true }
        return g.mediaImportInProgress ? g.recording : g.busy
    }

    var body: some View {
        let waiting = g.captures.filter { g.importedCaptures[$0.id] == nil }
        // Three across normally; stacked when the text is set very large, so the labels stay whole.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            QuickActionTile(title: "拍照", icon: "camera.fill", recording: false) {
                Haptics.tap()
                g.snap()
            }
            .disabled(cameraBlocked || g.recording)

            QuickActionTile(title: g.recording ? "停止" : "录像",
                            icon: g.recording ? "stop.fill" : "video.fill",
                            recording: g.recording) {
                Haptics.tap()
                g.toggleRecording()
            }
            .disabled(cameraBlocked)

            QuickActionTile(title: importTitle(waiting.count),
                            icon: "square.and.arrow.down.fill",
                            recording: false) {
                importTapped(waiting)
            }
        }
    }

    private func importTitle(_ count: Int) -> String {
        if g.mediaImportInProgress { return "导入中" }
        return count > 0 ? "导入 \(count) 项" : "导入"
    }

    private func importTapped(_ waiting: [Capture]) {
        Haptics.tap()
        if g.mediaImportInProgress {
            openTab(.album)
            return
        }
        if waiting.isEmpty {
            g.showToast("眼镜里没有新的照片或视频。")
            openTab(.album)
            return
        }
        guard g.canStartMediaImport else {
            g.showToast("眼镜正忙，请稍后再试。")
            return
        }
        g.startMediaImport(waiting)
        openTab(.album)
    }
}

private struct QuickActionTile: View {
    let title: String
    let icon: String
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(recording ? Color.red : GlassesTheme.accent)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(recording ? Color.red.opacity(0.12) : GlassesTheme.surface, in: GlassesTheme.card)
            .contentShape(GlassesTheme.card)
        }
        .buttonStyle(TileButtonStyle())
    }
}

/// What the last tap led to, in one line: queued, importing, or the glasses' own answer.
private struct HomeActivityLine: View {
    @ObservedObject var g: Glasses
    let openTab: (AppTab) -> Void

    private var importLine: String {
        let total = g.mediaImportTotal
        if total <= 0 { return "正在准备导入…" }
        return "正在导入 \(min(g.mediaImportCompleteCount + 1, total))/\(total)"
    }

    var body: some View {
        if let queued = g.queuedGlassesActionText {
            HStack(alignment: .center, spacing: 10) {
                Label(queued, systemImage: "clock")
                    .font(.subheadline)
                Spacer(minLength: 8)
                Button("取消") {
                    g.cancelQueuedGlassesAction()
                    g.showToast("已取消排队")
                }
                .buttonStyle(SecondaryButtonStyle(fillsWidth: false))
            }
            .glassesCard(padding: 14)
        } else if g.mediaImportInProgress {
            Button {
                openTab(.album)
            } label: {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(importLine)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("去相册看进度")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .glassesCard(padding: 14)
            }
            .buttonStyle(RowButtonStyle())
        } else if let message = g.mediaMessage {
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
}

// MARK: 未连接

/// The hero card when the glasses cannot be used yet: what is going on, what to do, one button.
private struct HomeConnectCard: View {
    @ObservedObject var g: Glasses

    private enum Stage { case connecting, needsOwner, scanning, rejected, failed, saved, fresh }

    private var stage: Stage {
        if g.phaseBusy { return .connecting }
        if g.connected { return .needsOwner }
        if g.scanning { return .scanning }
        if case .rejected = g.ownerState { return .rejected }
        if case .failed = g.phase { return .failed }
        return g.hasSavedGlasses ? .saved : .fresh
    }

    private var title: String {
        switch stage {
        case .connecting:
            if case .reconnecting = g.phase { return "连接断开了，正在重连…" }
            if case .handshaking = g.phase { return "正在确认身份…" }
            return "正在连接眼镜…"
        case .needsOwner: return "还差一步：验证主人身份"
        case .scanning: return "正在搜索附近的眼镜…"
        case .rejected: return "这副眼镜还不认识这台 iPhone"
        case .failed: return "没有连上眼镜"
        case .saved: return "眼镜未连接"
        case .fresh: return "连接你的眼镜"
        }
    }

    private var detail: String {
        switch stage {
        case .connecting:
            if case .reconnecting(let attempt) = g.phase {
                return "第 \(attempt) 次尝试。让眼镜保持开机，放在手机旁边。"
            }
            return "让眼镜保持开机，放在手机旁边。"
        case .needsOwner:
            return "眼镜已经连上。验证一次主人身份后，就能拍摄、导入和修改设置。"
        case .scanning:
            return "把开机的眼镜放回充电盒，按住盒背按钮约 5 秒，等指示灯闪蓝。找到后会列在下面。"
        case .rejected:
            return g.discoveryMessage ?? "需要重新设置一次主人身份，之后就能正常连接。"
        case .failed:
            return failureDetail
        case .saved:
            return g.discoveryMessage ?? "让眼镜开机并靠近手机，然后点「重新连接」。"
        case .fresh:
            return g.discoveryMessage ?? "把开机的眼镜放回充电盒，按住盒背按钮约 5 秒，等指示灯闪蓝，再点「搜索眼镜」。"
        }
    }

    /// Reasons written for the log (codes, protocol names) stay in 诊断; here they become one plain line.
    private var failureDetail: String {
        if let message = g.discoveryMessage { return message }
        let advice = "让眼镜开机并靠近手机，然后再试一次。"
        if case .failed(let why) = g.phase {
            let markers = ["0x", "L2CAP", "MAC", "key", "握手", "serial", "rror", "："]
            let technical = markers.contains { why.contains($0) }
            if !technical && !why.isEmpty { return why + advice }
        }
        return advice
    }

    private var symbol: String {
        switch stage {
        case .needsOwner, .rejected: return "key.fill"
        case .failed: return "exclamationmark.triangle"
        default: return "eyeglasses"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    if stage == .connecting || stage == .scanning {
                        ProgressView()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(GlassesTheme.accent)
                    }
                }
                .frame(width: 54, height: 54)
                .background(GlassesTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            actions
        }
        .glassesCard(padding: 18)
    }

    @ViewBuilder
    private var actions: some View {
        switch stage {
        case .connecting:
            Button("取消") { g.disconnect() }
                .buttonStyle(SecondaryButtonStyle())
        case .needsOwner:
            Button("设置主人身份") { g.route = .ownerSetup }
                .buttonStyle(PrimaryButtonStyle())
            HStack(spacing: 12) {
                Button("重新验证") { g.reconnectForOwnerVerification() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("断开") { g.disconnect() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .scanning:
            Button("停止搜索") {
                g.stopScan()
                g.showToast("已停止搜索")
            }
            .buttonStyle(SecondaryButtonStyle())
        case .rejected:
            Button("设置主人身份") { g.route = .ownerSetup }
                .buttonStyle(PrimaryButtonStyle())
            if g.hasSavedGlasses {
                Button("重新连接") { reconnect() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("搜索眼镜") { search() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .failed, .saved:
            if g.hasSavedGlasses {
                Button("重新连接") { reconnect() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("搜索其他眼镜") { search() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("搜索眼镜") { search() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .fresh:
            Button("搜索眼镜") { search() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func reconnect() {
        Haptics.tap()
        g.reconnectLastGlasses()
    }

    private func search() {
        g.startScan()
        if g.scanning {
            g.showToast("开始搜索附近的眼镜")
        } else {
            Haptics.tap()
        }
    }
}

/// The glasses found nearby, each one a single tap to connect.
private struct HomeNearbyList: View {
    @ObservedObject var g: Glasses

    var body: some View {
        let listed = g.primaryDevices.sorted { $0.isListedBefore($1) }
        let known = listed.filter { !$0.needsIdentification }
        let others = listed.filter { $0.needsIdentification }
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("附近的眼镜")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if !known.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(known) { device in
                            row(device)
                            if device.id != known.last?.id {
                                CardRowDivider()
                            }
                        }
                    }
                    .background(GlassesTheme.surface, in: GlassesTheme.card)
                }
                if !others.isEmpty {
                    DisclosureGroup("其他蓝牙设备（\(others.count)）") {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("这些设备没有报出眼镜的名字。没有名字的，用末尾四位编号区分。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                            ForEach(others) { device in
                                row(device)
                            }
                        }
                    }
                    .font(.subheadline)
                    .glassesCard(padding: 14)
                }
            }
        }
    }

    private func caption(_ device: ScanEntry) -> String {
        var parts: [String] = []
        if device.isVerified {
            parts.append("你的眼镜")
        } else if device.source == .previouslySelected {
            parts.append("上次选过")
        } else if device.source == .systemConnected {
            parts.append("已连在这台 iPhone 上")
        } else {
            parts.append("在附近")
        }
        if let signal = device.signalLabel {
            parts.append(signal)
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ device: ScanEntry) -> some View {
        let connectingThis = g.phaseBusy && g.connectingID == device.id
        return Button {
            Haptics.tap()
            g.connect(device.id)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: device.isVerified ? "eyeglasses" : "dot.radiowaves.left.and.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(GlassesTheme.accent)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(caption(device))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if connectingThis {
                    ProgressView()
                } else {
                    Text("连接")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassesTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(g.phaseBusy)
        .accessibilityLabel("连接 \(device.displayName)")
    }
}

// MARK: - 更多

/// Everything that is not daily use, one push away from the home screen.
/// Its sheets are owned by `HomeTab`: a sheet presented from a pushed page does not survive `g` publishing.
struct MoreView: View {
    @ObservedObject var g: Glasses
    @Binding var showDiagnostics: Bool
    @Binding var showAbout: Bool
    @Binding var showMicrophoneCheck: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var audioTest = AudioRouteTest()

    var body: some View {
        List {
            audioSection
            ownerSection
            firmwareSection
            toolsSection
            if g.connected || g.phaseBusy {
                disconnectSection
            }
            Section {
                EmptyView()
            } footer: {
                Text("GlassesLink \(BuildInfo.short)")
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: 声音

    private var outputLine: String {
        if let profile = g.audioMediaProfile {
            return "\(g.audioRouteName) · \(profile)"
        }
        return g.audioRouteName
    }

    private var audioSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("现在的播放设备")
                    Text(outputLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                AudioOutputPicker()
                    .frame(width: 44, height: 44)
            }
            glassesAudioStatus
            Button {
                if audioTest.isPlaying {
                    stopAudioTest()
                } else {
                    audioTest.start { g.readAudioOutput() }
                }
            } label: {
                Label(audioTest.isPlaying ? "停止测试音" : "播放测试音",
                      systemImage: audioTest.isPlaying ? "stop.circle" : "play.circle")
            }
            if let error = audioTest.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                stopAudioTest()
                showMicrophoneCheck = true
            } label: {
                Label("测试眼镜麦克风", systemImage: "mic")
            }
        } header: {
            Text("声音输出与麦克风")
        } footer: {
            Text(audioTest.isPlaying
                 ? "测试音持续 15 秒。可以打开控制中心，在播放卡片里选眼镜。"
                 : "拍摄和导入不受这里影响。播放视频或其他 App 的声音时，在控制中心的播放卡片里选眼镜。")
        }
    }

    /// Only a system Bluetooth pairing makes the glasses an iPhone headset, so this says which
    /// state iOS is in and, when needed, walks through the repair that fixed the 0.99 report.
    @ViewBuilder
    private var glassesAudioStatus: some View {
        switch g.glassesAudio {
        case .glasses(let profile):
            Label("眼镜音频已接通 · \(profile)", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassesTheme.accent)
        case .otherBluetooth(let other):
            Text("现在声音从「\(other)」播放。要用眼镜，点右边的按钮或在控制中心里选眼镜。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            VStack(alignment: .leading, spacing: 5) {
                Text("眼镜还不是 iPhone 的耳机，修复一次即可：")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
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

    // MARK: 主人身份、固件、工具

    private var ownerSection: some View {
        Section {
            OwnerStatusRow(g: g)
            Button("重新验证") {
                Haptics.tap()
                g.reconnectForOwnerVerification()
            }
            .disabled(g.phaseBusy)
            Button {
                g.route = .ownerSetup
            } label: {
                chevronLabel("管理主人身份", icon: "checkmark.shield")
            }
        } header: {
            Text("主人身份")
        } footer: {
            Text(g.ownerFingerprint)
        }
    }

    private var firmwareSection: some View {
        Section {
            Toggle("拦截固件升级", isOn: Binding(
                get: { Glasses.blockOTA },
                set: { enabled in
                    Glasses.blockOTA = enabled
                    g.showToast(enabled ? "已开启固件升级拦截" : "已关闭固件升级拦截")
                }
            ))
            .tint(GlassesTheme.accent)
        } header: {
            Text("固件")
        } footer: {
            Text("开启后 GlassesLink 会拒绝把新固件传给眼镜；改动在下次连接眼镜时生效。眼镜自己的自动更新开关在「眼镜设置」里。")
        }
    }

    private var toolsSection: some View {
        Section {
            Button {
                showDiagnostics = true
            } label: {
                chevronLabel("诊断与实验功能", icon: "wrench.and.screwdriver")
            }
            Button {
                showAbout = true
            } label: {
                chevronLabel("关于 · 许可 · 隐私", icon: "info.circle")
            }
        }
    }

    private var disconnectSection: some View {
        Section {
            Button(g.phaseBusy ? "取消连接" : "断开连接", role: .destructive) {
                stopAudioTest()
                g.disconnect()
                g.showToast("已断开连接")
                dismiss()
            }
        } footer: {
            Text("断开后不会自动重连。需要时回到「眼镜」页点「重新连接」。")
        }
    }

    private func chevronLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon).foregroundStyle(GlassesTheme.accent)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// One question, one answer: does the glasses accept the key this phone holds?
private struct OwnerStatusRow: View {
    @ObservedObject var g: Glasses

    private var title: String {
        switch g.ownerState {
        case .verified: return "已验证，这台 iPhone 是主人"
        case .rejected: return "眼镜没有接受这台 iPhone"
        case .unverified: return "还没有验证"
        default: return "还没连过眼镜"
        }
    }

    private var detail: String {
        switch g.ownerState {
        case .verified: return "可以拍摄、导入相册和修改设置。"
        case .rejected(let code): return Glasses.explain(LinkError.trustRejected(code))
        case .unverified: return "导入钥匙或完成注册后，点「重新验证」。"
        default: return "连一次眼镜就会知道结果。"
        }
    }

    private var color: Color {
        switch g.ownerState {
        case .verified: return Color.green
        case .rejected: return Color.red
        case .unverified: return Color.orange
        default: return Color.secondary
        }
    }

    private var symbol: String {
        switch g.ownerState {
        case .verified: return "checkmark.seal.fill"
        case .rejected: return "xmark.seal.fill"
        case .unverified: return "questionmark.circle"
        default: return "circle.dotted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let at = UserDefaults.standard.string(forKey: "ownerStateAt") {
                Text("上次验证：\(at)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
