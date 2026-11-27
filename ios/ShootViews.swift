import SwiftUI
import UIKit

// MARK: - 拍摄

/// The remote shutter: what the camera is doing, the last picture that came back, and one big button.
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

    init(g: Glasses, openDevice: @escaping () -> Void, openAlbum: @escaping () -> Void) {
        self.g = g
        self.openDevice = openDevice
        self.openAlbum = openAlbum
    }

    /// An import keeps the camera usable: what is pressed is queued and runs when the import ends.
    private var ready: Bool { g.canUseGlasses || g.mediaImportInProgress }

    private var cameraActionBlocked: Bool {
        if g.assistantRegistering || g.queuedGlassesActionText != nil { return true }
        return g.mediaImportInProgress ? g.recording : g.busy
    }

    private var stageTitle: String {
        if g.recording { return "正在录像" }
        if g.mediaImportInProgress { return "正在导入，拍摄会排队" }
        if g.canUseGlasses { return "可以拍摄" }
        return g.connected ? "需要先验证主人身份" : "眼镜未连接"
    }

    private var stageColor: Color {
        if g.recording { return Color.red }
        if g.mediaImportInProgress { return Color.orange }
        return g.canUseGlasses ? Color.green : Color.secondary
    }

    private var shutterTitle: String {
        if g.recording { return "停止录像" }
        if g.queuedGlassesActionText != nil { return "已排队" }
        return mode == .photo ? "拍照" : "开始录像"
    }

    private var lastReceivedPhoto: UIImage? {
        g.captures.lazy.filter(\.isPhoto).compactMap { g.thumbs[$0.id] }.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GlassesTheme.sectionSpacing) {
                    if !ready {
                        ConnectHintCard(g: g, purpose: "连接眼镜后，就能在这里拍照和录像。", openDevice: openDevice)
                    }
                    stage
                    statusLine
                }
                .padding(.horizontal, GlassesTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableColumn()
            }
            .glassesPage()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if ready {
                    controls
                }
            }
            .navigationTitle("拍摄")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showLive) { LiveView(g: g) }
            .onChange(of: g.recording, initial: true) { _, recording in
                if recording { mode = .video }
            }
        }
    }

    // MARK: 画面

    private var stage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stageColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(stageTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                if g.recording, let deadline = g.recordDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timerText(deadline, now: context.date))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.red)
                            .accessibilityLabel("剩余 \(timerText(deadline, now: context.date))")
                    }
                }
            }
            lastShot
        }
        .glassesCard()
    }

    @ViewBuilder
    private var lastShot: some View {
        if let photo = lastReceivedPhoto {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { bounds in
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: bounds.size.width, height: bounds.size.height)
                            .clipped()
                    }
                }
                .clipShape(GlassesTheme.control)
                .overlay(alignment: .bottomLeading) {
                    Text("最近导入的照片")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("最近导入的照片")
        } else {
            VStack(spacing: 8) {
                Image(systemName: g.recording ? "video" : "camera")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("拍下的照片导入后，会显示在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(GlassesTheme.fill, in: GlassesTheme.control)
        }
    }

    /// What the glasses answered to the last press.
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

    // MARK: 快门

    private var controls: some View {
        VStack(spacing: 14) {
            queueLine
            Picker("拍摄模式", selection: $mode) {
                ForEach(CaptureMode.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(cameraActionBlocked || g.recording)

            if mode == .video {
                durationRow
            }

            HStack(alignment: .center, spacing: 12) {
                sideButton("相册", icon: "photo.on.rectangle.angled", action: openAlbum)
                shutterButton
                sideButton("实时取景", icon: "viewfinder") {
                    showLive = true
                }
                .disabled(g.busy || g.mediaImportInProgress || g.recording || g.assistantRegistering)
            }
        }
        .padding(.horizontal, GlassesTheme.pagePadding)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .readableColumn()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var queueLine: some View {
        if let queued = g.queuedGlassesActionText {
            HStack(alignment: .center, spacing: 8) {
                Label(queued, systemImage: "clock")
                    .font(.footnote)
                Spacer(minLength: 4)
                Button("取消排队") {
                    g.cancelQueuedGlassesAction()
                    g.showToast("已取消排队")
                }
                .buttonStyle(SecondaryButtonStyle(fillsWidth: false))
            }
        } else if g.mediaImportInProgress && !cameraActionBlocked {
            Label("正在导入。现在按下的拍摄会排队，导入结束后执行。", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var durationRow: some View {
        HStack(spacing: 8) {
            Text("录像时长")
                .font(.subheadline)
            Spacer(minLength: 8)
            Picker("录像时长", selection: $g.maxRecordSeconds) {
                Text("手动停止").tag(0)
                Text("30 秒").tag(30)
                Text("1 分钟").tag(60)
                Text("3 分钟").tag(180)
                Text("5 分钟").tag(300)
            }
            .pickerStyle(.menu)
            .disabled(cameraActionBlocked || g.recording)
        }
        .frame(minHeight: 44)
    }

    private func sideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
    }

    private var shutterButton: some View {
        let filming = mode == .video || g.recording
        let color: Color = filming ? Color.red : GlassesTheme.accent
        return Button {
            Haptics.tap()
            if g.recording || mode == .video {
                g.toggleRecording()
            } else {
                g.snap()
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(color, lineWidth: 3)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: g.recording ? 7 : 31, style: .continuous)
                        .fill(color)
                        .frame(width: g.recording ? 30 : 62, height: g.recording ? 30 : 62)
                }
                .accessibilityHidden(true)
                Text(shutterTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .disabled(cameraActionBlocked)
        .animation(.easeInOut(duration: 0.2), value: g.recording)
    }

    private func timerText(_ deadline: Date, now: Date) -> String {
        let left = max(0, Int(deadline.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}
