import AVFoundation
import CoreImage
import Foundation

/// Levels a clip taken with a tilted head before it goes to iPhone Photos. The glasses' own stabilization
/// removes shake but leaves the horizon where the head had it (glasses log 33's clip is at their
/// two-stage output size and still leans 2-3 degrees). The head's roll comes from the IMU log that
/// travels with each capture; Vision's horizon on a few frames checks its sign and removes whatever the
/// glasses already corrected. Without an IMU log, Vision alone is used. The original stays as it is.
///
/// Method after Gyroflow's horizon lock (gravity from fused gyro and accelerometer, roll only) with the
/// advice for footage that is already stabilized: correct only the slow part of the roll, zero-phase
/// smoothed, or the correction puts back the motion the stabilizer removed.
enum VideoLeveling {
    static let enabledKey = "levelVideosOnSave"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Below this nothing is worth a re-encode.
    static let minimumDegrees = 0.8
    /// The correction saturates here (zoom 1.18 on a 3:4 portrait frame)…
    static let maximumDegrees = 8.0
    /// …and a head tilted this far is taken as meant: the correction fades out toward it.
    static let deliberateDegrees = 25.0
    static let smoothingSeconds = 0.5
    /// A frame's moment is its mid-exposure plus this (Visor's Steady).
    static let frameLagNs: Int64 = 10_000_000

    // MARK: head roll from the IMU

    /// The direction of "up" in the IMU's axes for each sample: the gyroscope carries it between samples
    /// and the accelerometer pulls it back with time constant `accelTau`, but only while it reads close
    /// to 1 g. A walking turn adds ~1.3 m/s² sideways, about 7 degrees if the accelerometer were trusted alone.
    static func upVectors(_ imu: [IMUSample], gyroSign: Double = 1, accelTau: Double = 2) -> [SIMD3<Double>] {
        guard let first = imu.first else { return [] }
        var up = normalized(SIMD3(Double(first.ax), Double(first.ay), Double(first.az))) ?? SIMD3(0, 1, 0)
        var out: [SIMD3<Double>] = [up]
        out.reserveCapacity(imu.count)
        for k in 1 ..< imu.count {
            let a = imu[k - 1], b = imu[k]
            let dt = min(0.05, max(0, Double(b.timeNs - a.timeNs) / 1e9))
            let w = SIMD3(Double(a.gx + b.gx), Double(a.gy + b.gy), Double(a.gz + b.gz)) * (0.5 * gyroSign)
            // A world-fixed direction seen from a body turning at w: du/dt = -w x u.
            up -= cross(w, up) * dt
            let accel = SIMD3(Double(b.ax), Double(b.ay), Double(b.az))
            let g = length(accel)
            if abs(g - 9.81) < 1.5, let measured = normalized(accel) {
                up += (measured - up) * (dt / (accelTau + dt))
            }
            up = normalized(up) ?? out[k - 1]
            out.append(up)
        }
        return out
    }

    /// How well the gyroscope alone predicts where the accelerometer says "up" is, a quarter second
    /// ahead. The smaller of the two signs is the right one; this guards the axis convention.
    static func gyroPredictionError(_ imu: [IMUSample], gyroSign: Double) -> Double {
        guard imu.count > 600 else { return .infinity }
        let step = 240
        var total = 0.0
        var count = 0
        var index = 0
        while index + step < imu.count {
            let window = Array(imu[index ... index + step])
            let predicted = upVectors(window, gyroSign: gyroSign, accelTau: .infinity).last
            let end = window[step]
            if let predicted, let measured = normalized(SIMD3(Double(end.ax), Double(end.ay), Double(end.az))) {
                total += length(predicted - measured)
                count += 1
            }
            index += step
        }
        return count == 0 ? .infinity : total / Double(count)
    }

    /// Visor's convention: positive is the head tilted to its right. `weight` falls toward 0 as the head
    /// pitches toward straight up or down, where roll stops meaning anything.
    static func roll(of up: SIMD3<Double>) -> (radians: Double, weight: Double) {
        (atan2(-up.x, up.y), min(1, (up.x * up.x + up.y * up.y).squareRoot() / 0.5))
    }

    /// Head roll at each frame's moment, or nil when the logs do not cover the clip.
    static func frameRolls(imu: [IMUSample], frames: [FrameRecord]) -> [(radians: Double, weight: Double)]? {
        guard imu.count > 100, frames.count > 2,
              let start = imu.first?.timeNs, let end = imu.last?.timeNs,
              let firstFrame = frames.first?.midExposureNs, let lastFrame = frames.last?.midExposureNs,
              firstFrame >= start - 200_000_000, lastFrame <= end + 200_000_000 else { return nil }
        let sign: Double = gyroPredictionError(imu, gyroSign: -1) + 0.002 < gyroPredictionError(imu, gyroSign: 1) ? -1 : 1
        let ups = upVectors(imu, gyroSign: sign)
        var cursor = 0
        return frames.map { frame in
            let t = frame.midExposureNs + frameLagNs
            while cursor + 1 < imu.count, imu[cursor + 1].timeNs <= t { cursor += 1 }
            return roll(of: ups[cursor])
        }
    }

    // MARK: from roll to a correction per frame

    /// A one-pole low-pass run forward and then backward: smooth without lag.
    static func zeroPhaseSmooth(_ values: [Double], tauFrames: Double) -> [Double] {
        guard values.count > 1, tauFrames > 0 else { return values }
        let alpha = 1 / (tauFrames + 1)
        var out = values
        for i in 1 ..< out.count { out[i] = out[i - 1] + alpha * (out[i] - out[i - 1]) }
        for i in stride(from: out.count - 2, through: 0, by: -1) { out[i] = out[i + 1] + alpha * (out[i] - out[i + 1]) }
        return out
    }

    /// Unchanged up to `maximumDegrees`, held there beyond it, and let go as the tilt nears one that
    /// looks deliberate.
    static func limited(_ radians: Double) -> Double {
        let cap = maximumDegrees * .pi / 180
        let deliberate = deliberateDegrees * .pi / 180
        let size = abs(radians)
        guard size > cap else { return radians }
        let fade = max(0, (deliberate - size) / (deliberate - cap))
        return (radians < 0 ? -cap : cap) * fade
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    struct Plan: Equatable {
        /// Seconds from the first frame, ascending, and the rotation to apply at each (Core Image radians).
        let times: [Double]
        let angles: [Double]
        let zoom: Double
        /// For the log.
        let source: String

        func angle(at time: Double) -> Double {
            guard let first = times.first, let last = times.last else { return 0 }
            if time <= first { return angles[0] }
            if time >= last { return angles[angles.count - 1] }
            var low = 0, high = times.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if times[mid] <= time { low = mid } else { high = mid }
            }
            let span = times[high] - times[low]
            let share = span > 0 ? (time - times[low]) / span : 0
            return angles[low] + (angles[high] - angles[low]) * share
        }

        var maximumDegrees: Double { (angles.map(abs).max() ?? 0) * 180 / .pi }
    }

    /// The per-frame corrections. `imuRolls` are head rolls at `frameTimes` (Visor's sign); `vision` are
    /// Vision's levelling angles at their times. Vision's angle already is the correction; the IMU's is
    /// minus the roll (both verified signs: a head tilted right raises the horizon on the right, which
    /// Vision reports as a negative angle).
    static func plan(frameTimes: [Double], imuRolls: [(radians: Double, weight: Double)]?,
                     vision: [(time: Double, angle: Double)], fps: Double, width: Double, height: Double) -> Plan? {
        guard frameTimes.count > 2, fps > 1 else { return nil }
        var angles: [Double]
        var source: String
        if let imuRolls, imuRolls.count == frameTimes.count {
            let smooth = zeroPhaseSmooth(imuRolls.map(\.radians), tauFrames: smoothingSeconds * fps)
            angles = smooth.map { -$0 }
            source = "IMU"
            if vision.count >= 3 {
                let probe = Plan(times: frameTimes, angles: angles, zoom: 1, source: "")
                let predicted = vision.map { probe.angle(at: $0.time) }
                let same = median(zip(vision, predicted).map { abs($0.0.angle - $0.1) })
                let flipped = median(zip(vision, predicted).map { abs($0.0.angle + $0.1) })
                let degree = Double.pi / 180
                if flipped + degree < same, median(predicted.map(abs)) > 1.5 * degree {
                    angles = angles.map { -$0 }
                    source = "IMU（方向按画面校正）"
                }
                let checked = Plan(times: frameTimes, angles: angles, zoom: 1, source: "")
                // What the glasses already levelled, or how the camera sits against the IMU: one offset per clip.
                let offset = median(vision.map { $0.angle - checked.angle(at: $0.time) })
                let bounded = max(-6 * degree, min(6 * degree, offset))
                angles = angles.map { $0 + bounded }
                source += String(format: " + 画面校验 %d 处，偏移 %.1f°", vision.count, bounded / degree)
            }
            angles = zip(angles, imuRolls).map { limited($0.0) * $0.1.weight }
        } else {
            // Vision alone: enough frames must agree that there is a horizon at all.
            guard vision.count >= 4, let first = vision.first, let last = vision.last,
                  last.time - first.time > 0.5 * ((frameTimes.last ?? 0) - (frameTimes.first ?? 0)) else { return nil }
            let coarse = Plan(times: vision.map(\.time), angles: vision.map(\.angle), zoom: 1, source: "")
            let sampled = frameTimes.map { coarse.angle(at: $0) }
            angles = zeroPhaseSmooth(sampled, tauFrames: 2 * smoothingSeconds * fps).map(limited)
            source = "画面水平线 \(vision.count) 处"
        }
        let largest = angles.map(abs).max() ?? 0
        guard largest >= minimumDegrees * .pi / 180 else { return nil }
        return Plan(times: frameTimes, angles: angles,
                    zoom: PhotoLeveling.zoom(width: width, height: height, angle: largest), source: source)
    }

    // MARK: the clip

    enum Outcome {
        case leveled(URL, Plan)
        /// Nothing to do, or nothing to go by; the string says which, for the log.
        case unchanged(String)
    }

    /// A levelled HEVC copy in the temporary folder, or why there is none.
    static func leveledCopy(of url: URL, imu imuFile: URL?, frames framesFile: URL?) async -> Outcome {
        let asset = AVURLAsset(url: url)
        let imu = imuFile.flatMap { try? Data(contentsOf: $0) }
        let frames = framesFile.flatMap { try? Data(contentsOf: $0) }
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .unchanged("没有视频轨") }
            let (size, transform, rate, duration) = try await (track.load(.naturalSize), track.load(.preferredTransform),
                                                              track.load(.nominalFrameRate), asset.load(.duration))
            // The glasses write upright frames with no rotation; anything else is not theirs to turn.
            guard transform.isIdentity, size.width > 0, size.height > 0 else { return .unchanged("视频带旋转标记") }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0.5 else { return .unchanged("视频太短") }
            let fps = Double(rate) > 1 ? Double(rate) : 30

            let records = frames.flatMap(MotionLog.readFrames)
            let samples = imu.flatMap(MotionLog.readIMU)
            let frameTimes: [Double]
            let rolls: [(radians: Double, weight: Double)]?
            if let records, records.count > 2, let samples, let found = frameRolls(imu: samples, frames: records) {
                let zero = records[0].timeNs
                frameTimes = records.map { Double($0.timeNs - zero) / 1e9 }
                rolls = found
            } else {
                frameTimes = stride(from: 0, to: seconds, by: 1 / fps).map { $0 }
                rolls = nil
            }
            let vision = await horizonSamples(asset: asset, seconds: seconds)
            guard let plan = Self.plan(frameTimes: frameTimes, imuRolls: rolls, vision: vision, fps: fps,
                                       width: Double(size.width), height: Double(size.height)) else {
                return .unchanged(rolls == nil && vision.count < 4 ? "没有传感器记录，画面里也找不到水平线" : "已经是平的")
            }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID().uuidString).mp4")
            try await export(asset: asset, plan: plan, to: output)
            return .leveled(output, plan)
        } catch {
            return .unchanged("处理失败：\(error.localizedDescription)")
        }
    }

    /// Vision's levelling angle on about two frames a second (at most 40), where it is sure of a horizon.
    static func horizonSamples(asset: AVAsset, seconds: Double) async -> [(time: Double, angle: Double)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let count = max(4, min(40, Int(seconds * 2)))
        var out: [(time: Double, angle: Double)] = []
        for index in 0 ..< count {
            let time = seconds * (Double(index) + 0.5) / Double(count)
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { continue }
            guard let horizon = PhotoLeveling.detectedHorizon(of: CIImage(cgImage: frame.image)),
                  horizon.confidence >= PhotoLeveling.minimumConfidence,
                  abs(horizon.angle) <= 15 * .pi / 180 else { continue }
            out.append((frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time, horizon.angle))
        }
        return out
    }

    private static func export(asset: AVAsset, plan: Plan, to output: URL) async throws {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let angle = plan.angle(at: request.compositionTime.seconds)
            request.finish(with: PhotoLeveling.straightened(request.sourceImage, by: angle, zoom: plan.zoom), context: nil)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw LinkError.io("这台 iPhone 不能导出 HEVC 视频。")
        }
        session.videoComposition = composition
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? LinkError.io("视频导出没有完成。")
        }
    }

    // MARK: small vector helpers

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }

    private static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let l = length(v)
        return l > 1e-9 ? v / l : nil
    }
}
