import Foundation

/// One IMU sample, about 960 per second: monotonic nanoseconds, m/s², rad/s, in Android sensor axes
/// (x right, y up, z toward the wearer).
struct IMUSample: Equatable {
    let timeNs: Int64
    let ax: Float, ay: Float, az: Float
    let gx: Float, gy: Float, gz: Float
}

/// One camera frame on the IMU's clock: the camera's frame counter, when it was taken, and its exposure.
struct FrameRecord: Equatable {
    let frame: Int
    let timeNs: Int64
    let exposureNs: Int64

    /// The moment the frame shows: mid-exposure.
    var midExposureNs: Int64 { timeNs + exposureNs / 2 }
}

/// The two sensor logs that come with each capture (Visor's Sensors.kt): asset type 3 "SI" and type 4 "SF".
/// Two ASCII magic bytes and a uint16 version, then fixed little-endian records; a file that is not whole
/// records is refused.
enum MotionLog {
    static let imuAssetType = 3
    static let framesAssetType = 4
    private static let header = 4
    private static let imuRecord = 38
    private static let frameRecord = 18

    static func readIMU(_ data: Data) -> [IMUSample]? {
        guard let bytes = records(data, magic: "SI", size: imuRecord) else { return nil }
        return stride(from: header, to: bytes.count, by: imuRecord).map { o in
            IMUSample(timeNs: int64(bytes, o + 2),
                      ax: float(bytes, o + 10), ay: float(bytes, o + 14), az: float(bytes, o + 18),
                      gx: float(bytes, o + 22), gy: float(bytes, o + 26), gz: float(bytes, o + 30))
        }
    }

    static func readFrames(_ data: Data) -> [FrameRecord]? {
        guard let bytes = records(data, magic: "SF", size: frameRecord) else { return nil }
        return stride(from: header, to: bytes.count, by: frameRecord).map { o in
            FrameRecord(frame: Int(UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8),
                        timeNs: int64(bytes, o + 2), exposureNs: int64(bytes, o + 10))
        }
    }

    private static func records(_ data: Data, magic: String, size: Int) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= header, String(decoding: bytes[0 ..< 2], as: UTF8.self) == magic,
              (bytes.count - header) % size == 0 else { return nil }
        return bytes
    }

    private static func int64(_ b: [UInt8], _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for k in 0 ..< 8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        return Int64(bitPattern: v)
    }

    private static func float(_ b: [UInt8], _ o: Int) -> Float {
        let bits = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        return Float(bitPattern: bits)
    }
}
