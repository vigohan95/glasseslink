import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// The picture work iOS 26 can do for an imported clip, on the phone and offline: Apple's temporal noise
/// filter (the dense grain of the glasses' indoor and 60-frame clips) and its super-resolution scaler
/// (a 60-frame clip cut to the standard view is about 1000 pixels wide). Both are VideoToolbox frame
/// processors; neither exists before iOS 26 or in the simulator, and then the clip goes the old way.
enum VideoEnhance {
    static let enabledKey = "enhanceVideos"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The standard clip's size: a smaller cut is scaled up toward it.
    static let standardWidth = 1512
    static let standardHeight = 2016

    static var canDenoise: Bool {
        if #available(iOS 26.0, *) { return VTTemporalNoiseFilterConfiguration.isSupported }
        return false
    }

    static var canUpscale: Bool {
        if #available(iOS 26.0, *) { return VTSuperResolutionScalerConfiguration.isSupported }
        return false
    }

    /// What one clip gets, for the log.
    struct Report {
        var frames = 0
        var denoised = false
        var upscaled = false
        var note = ""
        var seconds = 0.0

        var line: String {
            var parts: [String] = []
            if denoised { parts.append("降噪") }
            if upscaled { parts.append("超分辨率") }
            let done = parts.isEmpty ? "未增强" : parts.joined(separator: "+")
            return String(format: "%@，%d 帧，用时 %.1f 秒", done, frames, seconds) + (note.isEmpty ? "" : "（\(note)）")
        }
    }

    /// The size the output has: the cut itself, or the standard size when the scaler doubles a cut that
    /// is too small and its double is not.
    static func outputSize(cutWidth: Int, cutHeight: Int, upscale: Bool) -> (width: Int, height: Int) {
        guard upscale, cutWidth < standardWidth, cutWidth * 2 >= standardWidth else { return (cutWidth, cutHeight) }
        let scale = Double(standardWidth) / Double(cutWidth)
        return (standardWidth, VideoSteady.even(Double(cutHeight) * scale))
    }

    // MARK: the export

    /// Reads `asset` frame by frame, denoises (when asked and possible), applies `transform` (the
    /// steadying and levelling, on Core Image), scales up (when asked and possible) and writes HEVC with
    /// the sound as it was. `cut` is the size `transform` produces.
    static func export(asset: AVAsset, to output: URL, cut: (width: Int, height: Int),
                       denoise: Bool, upscale: Bool,
                       transform: @escaping (CIImage, Double) -> CIImage) async throws -> Report {
        let started = Date()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LinkError.io("视频没有画面轨。")
        }
        let natural = try await videoTrack.load(.naturalSize)
        let sourceRate = try await videoTrack.load(.estimatedDataRate)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let width = Int(natural.width), height = Int(natural.height)

        var report = Report()
        var denoiser: AnyObject?
        if denoise, #available(iOS 26.0, *) {
            denoiser = Denoiser(width: width, height: height)
            if denoiser == nil { report.note = "这台 iPhone 不支持降噪" }
        }
        var scaler: AnyObject?
        if upscale, cut.width * 2 >= standardWidth, cut.width < standardWidth, #available(iOS 26.0, *) {
            switch await Upscaler.make(width: cut.width, height: cut.height) {
            case .ready(let made): scaler = made
            case .unavailable(let why): report.note = report.note.isEmpty ? why : report.note + "；" + why
            }
        }
        let size = outputSize(cutWidth: cut.width, cutHeight: cut.height, upscale: scaler != nil)

        // Reading.
        let reader = try AVAssetReader(asset: asset)
        var format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if #available(iOS 26.0, *), let made = denoiser as? Denoiser { format = made.format }
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw LinkError.io("无法读取视频画面。") }
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let made = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(made) {
                reader.add(made)
                audioOut = made
            }
        }

        // Writing.
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let share = Double(size.width * size.height) / Double(max(width * height, 1))
        let bitRate = max(6_000_000, Double(sourceRate) * max(share, 0.6))
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(bitRate)],
        ]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoIn) else { throw LinkError.io("无法写入视频。") }
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil, let audioTrack {
            let hint = try await audioTrack.load(.formatDescriptions).first
            let made = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            made.expectsMediaDataInRealTime = false
            if writer.canAdd(made) {
                writer.add(made)
                audioIn = made
            }
        }

        guard reader.startReading() else { throw reader.error ?? LinkError.io("无法开始读取视频。") }
        guard writer.startWriting() else { throw writer.error ?? LinkError.io("无法开始写入视频。") }
        // The session starts at the first frame's own time, so the sound keeps its own times too.
        var sessionStarted = false
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        var firstTime: CMTime?
        var pendingAudio: CMSampleBuffer?
        var audioDone = audioOut == nil

        /// Sound up to `time`, so the writer gets both tracks interleaved and never waits on the other.
        func feedAudio(upTo time: CMTime) async throws {
            guard let audioOut, let audioIn else { return }
            while !audioDone {
                if pendingAudio == nil { pendingAudio = audioOut.copyNextSampleBuffer() }
                guard let sample = pendingAudio else {
                    audioDone = true
                    audioIn.markAsFinished()
                    return
                }
                let at = CMSampleBufferGetPresentationTimeStamp(sample)
                if time.isValid, at > time { return }
                while !audioIn.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                audioIn.append(sample)
                pendingAudio = nil
            }
        }

        /// One finished frame to the writer.
        func write(_ image: CIImage, at time: CMTime) async throws {
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            try await feedAudio(upTo: time + CMTime(seconds: 0.5, preferredTimescale: 600))
            while !videoIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw LinkError.io("无法准备视频帧。") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw LinkError.io("无法准备视频帧。") }
            context.render(image, to: buffer)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? LinkError.io("视频帧写入失败。")
            }
            report.frames += 1
        }

        /// A decoded (and perhaps denoised) frame through the transform and the scaler.
        func finish(_ pixels: CVPixelBuffer, at time: CMTime) async throws {
            let seconds = (time - (firstTime ?? .zero)).seconds
            var image = transform(CIImage(cvPixelBuffer: pixels), seconds)
            if #available(iOS 26.0, *), let made = scaler as? Upscaler {
                image = try await made.scale(image, context: context, to: size, at: time)
                report.upscaled = true
            }
            if image.extent.origin != .zero {
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            try await write(image.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height)), at: time)
        }

        if #available(iOS 26.0, *), let made = denoiser as? Denoiser {
            // The filter looks a few frames ahead: a frame is finished once its next ones are read.
            var window: [(VTFrameProcessorFrame, CMTime)] = []
            var index = 0
            var ended = false
            while !ended || index < window.count {
                if !ended {
                    if let sample = videoOut.copyNextSampleBuffer(), let decoded = CMSampleBufferGetImageBuffer(sample) {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if firstTime == nil { firstTime = time }
                        guard let kept = made.keep(decoded, at: time) else { throw LinkError.io("无法复制视频帧。") }
                        window.append((kept, time))
                    } else {
                        ended = true
                    }
                }
                while index < window.count, ended || window.count - index - 1 >= made.nextCount {
                    let previous = window[max(0, index - made.previousCount) ..< index].map(\.0)
                    let next = window[(index + 1) ..< min(window.count, index + 1 + made.nextCount)].map(\.0)
                    let clean = try await made.filter(window[index].0, previous: previous, next: next,
                                                      first: index == 0 && report.frames == 0)
                    try await finish(clean, at: window[index].1)
                    index += 1
                    // Only the frames still needed as references stay.
                    let drop = index - made.previousCount
                    if drop > 0 {
                        window.removeFirst(drop)
                        index -= drop
                    }
                }
            }
            report.denoised = report.frames > 0
            made.end()
        } else {
            while let sample = videoOut.copyNextSampleBuffer() {
                guard let decoded = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstTime == nil { firstTime = time }
                try await finish(decoded, at: time)
            }
        }
        if #available(iOS 26.0, *), let made = scaler as? Upscaler { made.end() }

        if reader.status == .failed { throw reader.error ?? LinkError.io("读取视频失败。") }
        guard sessionStarted else { throw LinkError.io("视频里没有读到画面。") }
        videoIn.markAsFinished()
        try await feedAudio(upTo: .invalid)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? LinkError.io("视频写入没有完成。")
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    /// Runs one frame through a processor and waits for it.
    @available(iOS 26.0, *)
    static func run(_ processor: VTFrameProcessor, _ parameters: any VTFrameProcessorParameters) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    static func pool(_ attributes: [String: Any]) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }

    static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// `source` copied plane by plane into a buffer from `pool` of the same size and format.
    static func copy(_ source: CVPixelBuffer, into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        guard let out = buffer(from: pool), CVPixelBufferGetWidth(out) == CVPixelBufferGetWidth(source),
              CVPixelBufferGetHeight(out) == CVPixelBufferGetHeight(source),
              CVPixelBufferGetPixelFormatType(out) == CVPixelBufferGetPixelFormatType(source) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = max(CVPixelBufferGetPlaneCount(source), 1)
        for plane in 0 ..< planes {
            let planar = CVPixelBufferGetPlaneCount(source) > 0
            guard let from = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = planar ? CVPixelBufferGetBaseAddressOfPlane(out, plane) : CVPixelBufferGetBaseAddress(out) else {
                return nil
            }
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let fromRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(out, plane) : CVPixelBufferGetBytesPerRow(out)
            let length = min(fromRow, toRow)
            for row in 0 ..< rows {
                memcpy(to.advanced(by: row * toRow), from.advanced(by: row * fromRow), length)
            }
        }
        CVBufferPropagateAttachments(source, out)
        return out
    }
}

// MARK: - the noise filter

@available(iOS 26.0, *)
final class Denoiser {
    let processor: VTFrameProcessor
    let format: OSType
    let previousCount: Int
    let nextCount: Int
    private let sources: CVPixelBufferPool
    private let destinations: CVPixelBufferPool
    /// Moderate: the glasses' grain goes, faces keep their skin.
    static let strength: Float = 0.5

    init?(width: Int, height: Int) {
        guard VTTemporalNoiseFilterConfiguration.isSupported else { return nil }
        let low = VTTemporalNoiseFilterConfiguration.minimumDimensions
        let high = VTTemporalNoiseFilterConfiguration.maximumDimensions
        guard width >= Int(low.width), height >= Int(low.height), width <= Int(high.width), height <= Int(high.height) else {
            return nil
        }
        let formats = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats
        let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let chosen = formats.contains(wanted) ? wanted : formats.first,
              let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                                                                      sourcePixelFormat: chosen),
              let sources = VideoEnhance.pool(configuration.sourcePixelBufferAttributes),
              let destinations = VideoEnhance.pool(configuration.destinationPixelBufferAttributes) else { return nil }
        let session = VTFrameProcessor()
        do { try session.startSession(configuration: configuration) } catch { return nil }
        processor = session
        format = chosen
        previousCount = max(0, configuration.previousFrameCount)
        nextCount = max(0, configuration.nextFrameCount)
        self.sources = sources
        self.destinations = destinations
    }

    /// The reader's frame in a buffer of the filter's own, so the reader can reuse its buffer.
    func keep(_ decoded: CVPixelBuffer, at time: CMTime) -> VTFrameProcessorFrame? {
        guard let copy = VideoEnhance.copy(decoded, into: sources) else { return nil }
        return VTFrameProcessorFrame(buffer: copy, presentationTimeStamp: time)
    }

    func filter(_ source: VTFrameProcessorFrame, previous: [VTFrameProcessorFrame], next: [VTFrameProcessorFrame],
                first: Bool) async throws -> CVPixelBuffer {
        guard let out = VideoEnhance.buffer(from: destinations),
              let destination = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: source.presentationTimeStamp),
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: source, nextFrames: next, previousFrames: previous,
                                                                destinationFrame: destination,
                                                                filterStrength: Self.strength, hasDiscontinuity: first)
        else { throw LinkError.io("降噪参数无效。") }
        try await VideoEnhance.run(processor, parameters)
        return destination.buffer
    }

    func end() { processor.endSession() }
}

// MARK: - the scaler

/// Apple's super-resolution scaler takes video frames up to 1440×1080, landscape: a portrait cut is
/// turned on its side, doubled, turned back and brought to the output size.
@available(iOS 26.0, *)
final class Upscaler {
    enum Made {
        case ready(Upscaler)
        case unavailable(String)
    }

    let processor: VTFrameProcessor
    private let sources: CVPixelBufferPool
    private let destinations: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private var previous: (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame)?

    private init(processor configuration: VTSuperResolutionScalerConfiguration, width: Int, height: Int,
                 sources: CVPixelBufferPool, destinations: CVPixelBufferPool) throws {
        let session = VTFrameProcessor()
        try session.startSession(configuration: configuration)
        processor = session
        self.width = width
        self.height = height
        self.sources = sources
        self.destinations = destinations
    }

    /// `width`×`height` is the portrait cut.
    static func make(width: Int, height: Int) async -> Made {
        guard VTSuperResolutionScalerConfiguration.isSupported else { return .unavailable("这台 iPhone 不支持超分辨率") }
        guard VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(2) else {
            return .unavailable("超分辨率不支持 2 倍")
        }
        // On its side: the cut's height becomes the scaler's width.
        let sideWidth = height, sideHeight = width
        guard sideWidth <= 1440, sideHeight <= 1080,
              let configuration = VTSuperResolutionScalerConfiguration(
                frameWidth: sideWidth, frameHeight: sideHeight, scaleFactor: 2, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision) else {
            return .unavailable("画面尺寸超出超分辨率的范围")
        }
        switch configuration.configurationModelStatus {
        case .ready:
            break
        case .downloadRequired:
            // The system fetches the model once; this clip goes without, the next ones get it.
            configuration.downloadConfigurationModel { _ in }
            return .unavailable("超分辨率模型正在下载，下一段视频起生效")
        case .downloading:
            return .unavailable("超分辨率模型还在下载")
        @unknown default:
            return .unavailable("超分辨率模型状态未知")
        }
        guard let sources = VideoEnhance.pool(configuration.sourcePixelBufferAttributes),
              let destinations = VideoEnhance.pool(configuration.destinationPixelBufferAttributes) else {
            return .unavailable("无法准备超分辨率的缓冲区")
        }
        do {
            return .ready(try Upscaler(processor: configuration, width: sideWidth, height: sideHeight,
                                       sources: sources, destinations: destinations))
        } catch {
            return .unavailable("超分辨率无法启动：\(error.localizedDescription)")
        }
    }

    /// `image` (the portrait cut, at the origin) doubled and brought to `size`.
    func scale(_ image: CIImage, context: CIContext, to size: (width: Int, height: Int),
               at time: CMTime) async throws -> CIImage {
        // Turned a quarter clockwise: portrait w×h becomes landscape h×w.
        let side = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let placed = side.transformed(by: CGAffineTransform(translationX: -side.extent.minX, y: -side.extent.minY))
        guard let input = VideoEnhance.buffer(from: sources), let output = VideoEnhance.buffer(from: destinations) else {
            throw LinkError.io("超分辨率缓冲区不足。")
        }
        context.render(placed.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: input)
        guard let source = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: time),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: source, previousFrame: previous?.source, previousOutputFrame: previous?.output,
                opticalFlow: nil, submissionMode: previous == nil ? .random : .sequential, destinationFrame: destination)
        else { throw LinkError.io("超分辨率参数无效。") }
        try await VideoEnhance.run(processor, parameters)
        previous = (source, destination)
        // Back upright, then to the output size.
        let doubled = CIImage(cvPixelBuffer: output)
        let upright = doubled.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        let origin = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let scaleX = CGFloat(size.width) / origin.extent.width
        let scaleY = CGFloat(size.height) / origin.extent.height
        return origin.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    func end() { processor.endSession() }
}
