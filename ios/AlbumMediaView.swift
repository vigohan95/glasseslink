import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

struct AlbumMediaSelection: Identifiable {
    let id: String
    let isPhoto: Bool
    let original: URL?
    let thumbnail: UIImage?
    var timestampNS: Int?
    /// The levelled or steadied copy, shown first when there is one.
    var processed: URL?

    var title: String { MediaNaming.title(isPhoto: isPhoto, timestampNS: timestampNS) }
}

struct AlbumMediaView: View {
    @ObservedObject var g: Glasses
    let media: AlbumMediaSelection
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var audioActive = false
    @State private var share: ShareBox?
    @State private var showOriginal = false
    @State private var processedNow: URL?
    @State private var processing = false

    private var processedCopy: URL? { processedNow ?? media.processed }
    /// What is on screen: the processed copy unless the original was asked for.
    private var shown: URL? { showOriginal ? media.original : (processedCopy ?? media.original) }

    /// Shares a copy named like "眼镜照片_2026-11-26_15-57-02.heic" instead of the stored hash name: the
    /// version on screen.
    private func shareOriginal() {
        guard let original = shown else { return }
        do {
            share = ShareBox(url: try MediaNaming.shareableCopy(of: original, isPhoto: media.isPhoto,
                                                                timestampNS: media.timestampNS))
        } catch {
            loadError = "无法准备分享的文件。"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if let photo {
                    ZoomableAlbumPhoto(image: photo)
                        .accessibilityLabel("原图")
                } else if media.original == nil || loadError != nil {
                    fallback
                } else {
                    ProgressView(media.isPhoto ? "正在打开原图…" : "正在打开视频…")
                        .tint(.white)
                }
            }
            .navigationTitle(media.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if media.original != nil {
                        Button { shareOriginal() } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel(processedCopy != nil && !showOriginal ? "分享处理后的版本" : "分享原件")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if processedCopy != nil {
                        Picker("显示", selection: $showOriginal) {
                            Text("处理后").tag(false)
                            Text("原片").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    } else if !media.isPhoto, media.original != nil {
                        Button {
                            processAgain()
                        } label: {
                            if processing {
                                ProgressView()
                            } else {
                                Label("防抖并摆正", systemImage: "wand.and.stars")
                            }
                        }
                        .disabled(processing)
                    }
                }
            }
            .sheet(item: $share) { box in ActivityView(url: box.url) }
            .safeAreaInset(edge: .bottom) {
                if player != nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("视频音频输出", systemImage: g.audioRouteUsesBluetooth ? "headphones" : "speaker.wave.2")
                                .font(.subheadline.weight(.semibold))
                            Text(g.audioRouteName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if !g.audioRouteUsesBluetooth {
                                Text("播放时可在 iPhone 控制中心的播放卡片中选择眼镜。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        AudioOutputPicker()
                            .frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: shown) { await loadOriginal() }
        .onDisappear { stopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: RunLoop.main)) { notice in
            guard let item = notice.object as? AVPlayerItem, item === player?.currentItem else { return }
            stopPlayback()
            loadError = "视频无法继续播放。"
        }
    }

    private func photoView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(media.isPhoto ? "照片" : "视频封面")
    }

    private var fallback: some View {
        VStack(spacing: 12) {
            if let thumbnail = media.thumbnail {
                photoView(thumbnail)
            } else {
                Image(systemName: media.isPhoto ? "photo" : "video")
                    .font(.system(size: 38, weight: .light))
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                if let loadError { Text(loadError).font(.footnote) }
                if media.thumbnail != nil {
                    Text(media.isPhoto ? "仅显示预览图" : "仅显示视频封面")
                        .font(.footnote.weight(.semibold))
                }
                if media.original == nil {
                    Text("原件尚未下载到 App。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
    }

    @MainActor
    private func loadOriginal() async {
        stopPlayback()
        photo = nil
        loadError = nil
        guard let url = shown else { return }
        if media.isPhoto {
            let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            guard !Task.isCancelled else { return }
            photo = image
            if image == nil { loadError = "无法打开原图。" }
            return
        }

        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else {
                loadError = "iPhone 无法播放这个视频文件。"
                return
            }
            try Task.checkCancellation()
            try g.beginVideoPlayback()
            audioActive = true
            let videoPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = videoPlayer
            videoPlayer.play()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "无法打开视频或启用播放音频。"
        }
    }

    /// A clip imported before the album kept processed copies: steadied and levelled now, from the motion
    /// log kept beside it.
    private func processAgain() {
        processing = true
        Task { @MainActor in
            defer { processing = false }
            if let made = await g.processStoredVideo(media.id) {
                processedNow = made
                showOriginal = false
            } else {
                loadError = "这段视频不需要处理，或没有可用的陀螺仪记录。"
            }
        }
    }

    @MainActor
    private func stopPlayback() {
        player?.pause()
        player = nil
        if audioActive {
            g.endVideoPlayback()
            audioActive = false
        }
    }
}

private struct ZoomableAlbumPhoto: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let imageView = context.coordinator.imageView
        guard imageView.image !== image else { return }
        scroll.setZoomScale(1, animated: false)
        imageView.image = image
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
