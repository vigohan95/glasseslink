import CoreImage
import Foundation
import simd

/// Stabilization on the phone for the clips the glasses leave alone: 1080p at 60 frames and 3K. At 30
/// frames the glasses steady the picture themselves and cut it to their stabilizer's output (1512×2016);
/// at the other two they keep the whole ultra-wide frame, unsteadied, which looks wide and bent at the
/// edges next to a normal clip (glasses log 35 and the user's samples: the lens itself is already
/// rectified, straight lines stay straight). The head's path from the motion log is smoothed, each frame
/// is turned onto it, and the picture is cut to a centred crop that every turned frame still covers.
///
/// A port of Visor's Steady.kt (the same pinhole model, focal length and crop sizes); the frame's moment
/// and the IMU's axes are the ones VideoLeveling already uses.
enum VideoSteady {
    static let enabledKey = "steadyWideVideos"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Focal length as a share of the video's width.
    static let focalShare = 0.78125
    /// A frame's moment is its mid-exposure plus this.
    static let lagNs: Int64 = 10_000_000
    static let rounds = 8

    /// The glasses' own stabilizer's output; any other size was not steadied on them.
    static func steadiedOnGlasses(width: Int, height: Int, outputs: [(Int, Int)] = [(1512, 2016)]) -> Bool {
        outputs.contains { min($0.0, $0.1) == min(width, height) && max($0.0, $0.1) == max(width, height) }
    }

    /// The share of each side kept and the seconds of smoothing, for eis_mode 1 strong, 3 light, else medium.
    static func cropAndSmoothing(_ steadiness: Int) -> (keep: Double, sigma: Double) {
        switch steadiness {
        case 1: return (0.8, 0.3)
        case 3: return (0.9, 0.12)
        default: return (0.85, 0.2)
        }
    }

    static func even(_ value: Double) -> Int { (Int(value) / 2) * 2 }

    /// Per frame, which input pixel each output pixel shows: column-major 3×3 matrices on pixels with y
    /// down, at the frames' times (seconds from the first frame).
    struct Warps {
        let inWidth: Int
        let inHeight: Int
        let outWidth: Int
        let outHeight: Int
        let times: [Double]
        let matrices: [[Double]]

        /// The warp of the frame nearest `time`.
        func matrix(at time: Double) -> [Double] {
            guard times.count > 1 else { return matrices[0] }
            var low = 0, high = times.count - 1
            if time <= times[low] { return matrices[low] }
            if time >= times[high] { return matrices[high] }
            while high - low > 1 {
                let mid = (low + high) / 2
                if times[mid] <= time { low = mid } else { high = mid }
            }
            return time - times[low] <= times[high] - time ? matrices[low] : matrices[high]
        }

        /// The largest turn any frame gets, in degrees, for the log.
        var largestTurnDegrees = 0.0
    }

    /// The warps for a `width`×`height` clip whose frames the motion log covers. Nil without a log.
    static func plan(width: Int, height: Int, imu: [IMUSample], frames: [FrameRecord], steadiness: Int) -> Warps? {
        guard width > 0, height > 0, imu.count > 1, frames.count > 2,
              let first = frames.first, let last = frames.last, last.timeNs > first.timeNs else { return nil }
        let (keep, sigma) = cropAndSmoothing(steadiness)
        let geometry = Geometry(w: Double(width), h: Double(height), ow: Double(even(Double(width) * keep)),
                                oh: Double(even(Double(height) * keep)), f: focalShare * Double(width))
        let path = Path(imu: imu, frames: frames)
        let turns = path.corrections(sigmaSeconds: sigma, geometry: geometry)
        var warps = Warps(inWidth: width, inHeight: height, outWidth: Int(geometry.ow), outHeight: Int(geometry.oh),
                          times: frames.map { Double($0.timeNs - first.timeNs) / 1e9 },
                          matrices: turns.map(geometry.matrix))
        warps.largestTurnDegrees = (turns.map { simd_length($0) }.max() ?? 0) * 180 / .pi
        return warps
    }

    // MARK: drawing a frame

    /// `source` (extent 0,0,width,height) turned by the warp `m` and cut to the output size.
    static func warped(_ source: CIImage, by m: [Double], outWidth: Int, outHeight: Int) -> CIImage {
        guard let forward = inverse(m) else { return source }
        let w = Double(source.extent.width), h = Double(source.extent.height)
        func place(_ x: Double, _ y: Double) -> CIVector? {
            let z = forward[2] * x + forward[5] * y + forward[8]
            guard z > 1e-9 else { return nil }
            let u = (forward[0] * x + forward[3] * y + forward[6]) / z
            let v = (forward[1] * x + forward[4] * y + forward[7]) / z
            // Pixels with y down to Core Image's y up.
            return CIVector(x: u, y: Double(outHeight) - v)
        }
        guard let topLeft = place(0, 0), let topRight = place(w, 0), let bottomRight = place(w, h),
              let bottomLeft = place(0, h) else { return source }
        let turned = source.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": topLeft, "inputTopRight": topRight,
            "inputBottomRight": bottomRight, "inputBottomLeft": bottomLeft,
        ])
        return turned.cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
    }

    /// The inverse of a column-major 3×3 matrix.
    static func inverse(_ m: [Double]) -> [Double]? {
        guard m.count == 9 else { return nil }
        // Rows first for the algebra: a = [[m0, m3, m6], [m1, m4, m7], [m2, m5, m8]].
        let a00 = m[0], a01 = m[3], a02 = m[6]
        let a10 = m[1], a11 = m[4], a12 = m[7]
        let a20 = m[2], a21 = m[5], a22 = m[8]
        let c00 = a11 * a22 - a12 * a21, c01 = a02 * a21 - a01 * a22, c02 = a01 * a12 - a02 * a11
        let c10 = a12 * a20 - a10 * a22, c11 = a00 * a22 - a02 * a20, c12 = a02 * a10 - a00 * a12
        let c20 = a10 * a21 - a11 * a20, c21 = a01 * a20 - a00 * a21, c22 = a00 * a11 - a01 * a10
        let det = a00 * c00 + a01 * c10 + a02 * c20
        guard abs(det) > 1e-12 else { return nil }
        let r = [[c00, c01, c02], [c10, c11, c12], [c20, c21, c22]].map { $0.map { $0 / det } }
        // Back to column-major.
        return [r[0][0], r[1][0], r[2][0], r[0][1], r[1][1], r[2][1], r[0][2], r[1][2], r[2][2]]
    }

    // MARK: the model

    /// Pinhole cameras sharing a focal length: the video and the centred crop the output is.
    struct Geometry {
        let w: Double, h: Double, ow: Double, oh: Double, f: Double

        /// Output pixel to input pixel, for the camera turned by rotation vector `r`: K_in R K_out⁻¹.
        func matrix(_ r: SIMD3<Double>) -> [Double] {
            let m = VideoSteady.rotation(r)
            var a = [[Double]](repeating: [0, 0, 0], count: 3)
            for row in 0 ..< 3 {
                a[row][0] = m[row][0] / f
                a[row][1] = m[row][1] / f
                a[row][2] = m[row][2] - m[row][0] * ow / 2 / f - m[row][1] * oh / 2 / f
            }
            let k = [[f, 0, w / 2], [0, f, h / 2], [0, 0, 1]]
            var out = [Double](repeating: 0, count: 9)
            for row in 0 ..< 3 {
                for col in 0 ..< 3 {
                    out[col * 3 + row] = k[row][0] * a[0][col] + k[row][1] * a[1][col] + k[row][2] * a[2][col]
                }
            }
            return out
        }

        /// Whether every edge of the output, turned by `r`, still falls inside the video.
        func covered(_ r: SIMD3<Double>) -> Bool {
            let m = matrix(r)
            for x in [0, ow / 2, ow] {
                for y in [0, oh / 2, oh] {
                    let z = m[2] * x + m[5] * y + m[8]
                    if z <= 0 { return false }
                    let u = (m[0] * x + m[3] * y + m[6]) / z
                    let v = (m[1] * x + m[4] * y + m[7]) / z
                    if u < 0 || u > w || v < 0 || v > h { return false }
                }
            }
            return true
        }
    }

    /// The head's rotation at each frame, from the motion log, in the camera's axes (x right, y down, z ahead).
    struct Path {
        let at: [SIMD4<Double>]
        let fps: Double

        init(imu: [IMUSample], frames: [FrameRecord]) {
            var q: [SIMD4<Double>] = [SIMD4(1, 0, 0, 0)]
            q.reserveCapacity(imu.count)
            for k in 1 ..< imu.count {
                let dt = Double(imu[k].timeNs - imu[k - 1].timeNs) / 1e9
                let a = imu[k - 1], b = imu[k]
                // The IMU's axes are Android's: x right, y up, z toward the wearer.
                let step = SIMD3(Double(a.gx + b.gx) / 2 * dt, -Double(a.gy + b.gy) / 2 * dt, -Double(a.gz + b.gz) / 2 * dt)
                q.append(VideoSteady.normalize(VideoSteady.multiply(q[k - 1], VideoSteady.quaternion(step))))
            }
            let times = imu.map(\.timeNs)
            at = frames.map { frame in
                let t = frame.timeNs + frame.exposureNs / 2 + VideoSteady.lagNs
                var low = 0, high = times.count
                while low < high {
                    let mid = (low + high) / 2
                    if times[mid] < t { low = mid + 1 } else { high = mid }
                }
                let i = min(max(low, 1), times.count - 1)
                let span = max(times[i] - times[i - 1], 1)
                let share = min(max(Double(t - times[i - 1]) / Double(span), 0), 1)
                let next = VideoSteady.aligned(q[i - 1], q[i])
                return VideoSteady.normalize(q[i - 1] * (1 - share) + next * share)
            }
            let span = Double(max(frames[frames.count - 1].timeNs - frames[0].timeNs, 1))
            fps = Double(frames.count - 1) / (span / 1e9)
        }

        /// Per frame, the turn onto the smoothed path; where it would leave the crop, the path is pulled
        /// toward the head and smoothed again.
        func corrections(sigmaSeconds: Double, geometry: Geometry) -> [SIMD3<Double>] {
            let sigma = max(sigmaSeconds * fps, 1)
            var path = smooth(at, sigma: sigma)
            for _ in 0 ..< VideoSteady.rounds {
                let fits = at.indices.map { fit(geometry, turn($0, path)) }
                if fits.allSatisfy({ $0 >= 1 }) { return at.indices.map { turn($0, path) } }
                let pulled = at.indices.map { i in
                    VideoSteady.normalize(VideoSteady.multiply(at[i], VideoSteady.quaternion(turn(i, path) * fits[i])))
                }
                path = smooth(pulled, sigma: max(sigma / 4, 1))
            }
            return at.indices.map { i in
                let r = turn(i, path)
                return r * fit(geometry, r)
            }
        }

        private func turn(_ i: Int, _ path: [SIMD4<Double>]) -> SIMD3<Double> {
            VideoSteady.vector(VideoSteady.multiply(VideoSteady.conjugate(at[i]), path[i]))
        }

        private func fit(_ geometry: Geometry, _ turn: SIMD3<Double>) -> Double {
            if geometry.covered(turn) { return 1 }
            var low = 0.0, high = 1.0
            for _ in 0 ..< 12 {
                let mid = (low + high) / 2
                if geometry.covered(turn * mid) { low = mid } else { high = mid }
            }
            return low
        }

        /// `qs` averaged over a Gaussian `sigma` frames wide.
        private func smooth(_ qs: [SIMD4<Double>], sigma: Double) -> [SIMD4<Double>] {
            let reach = Int(3 * sigma)
            let weights = (0 ... 2 * reach).map { exp(-Double(($0 - reach) * ($0 - reach)) / (2 * sigma * sigma)) }
            let n = qs.count
            return (0 ..< n).map { i in
                var sum = SIMD4<Double>(0, 0, 0, 0)
                for k in -reach ... reach {
                    sum += VideoSteady.aligned(qs[i], qs[min(max(i + k, 0), n - 1)]) * weights[k + reach]
                }
                return VideoSteady.normalize(sum)
            }
        }
    }

    // MARK: quaternions (w, x, y, z)

    static func multiply(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
              a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
              a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
              a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0])
    }

    static func conjugate(_ q: SIMD4<Double>) -> SIMD4<Double> { SIMD4(q[0], -q[1], -q[2], -q[3]) }

    static func normalize(_ q: SIMD4<Double>) -> SIMD4<Double> {
        let n = (q * q).sum().squareRoot()
        return n > 0 ? q / n : SIMD4(1, 0, 0, 0)
    }

    /// `q`, or its negative, whichever is on `reference`'s side: the same rotation, fit to average with it.
    static func aligned(_ reference: SIMD4<Double>, _ q: SIMD4<Double>) -> SIMD4<Double> {
        (reference * q).sum() < 0 ? -q : q
    }

    /// The unit quaternion turning by rotation vector `r`.
    static func quaternion(_ r: SIMD3<Double>) -> SIMD4<Double> {
        let angle = simd_length(r)
        if angle < 1e-12 { return SIMD4(1, r.x / 2, r.y / 2, r.z / 2) }
        let s = sin(angle / 2) / angle
        return SIMD4(cos(angle / 2), r.x * s, r.y * s, r.z * s)
    }

    /// The rotation vector of unit quaternion `q`, the shorter way round.
    static func vector(_ q: SIMD4<Double>) -> SIMD3<Double> {
        let p = q[0] < 0 ? -q : q
        let v = (p[1] * p[1] + p[2] * p[2] + p[3] * p[3]).squareRoot()
        if v < 1e-12 { return SIMD3(2 * p[1], 2 * p[2], 2 * p[3]) }
        let angle = 2 * atan2(v, p[0])
        return SIMD3(p[1] / v * angle, p[2] / v * angle, p[3] / v * angle)
    }

    /// The rotation matrix of rotation vector `r`, rows first.
    static func rotation(_ r: SIMD3<Double>) -> [[Double]] {
        let q = quaternion(r)
        let w = q[0], x = q[1], y = q[2], z = q[3]
        return [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    }
}
