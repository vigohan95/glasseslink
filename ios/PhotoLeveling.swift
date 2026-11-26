import CoreImage
import Foundation
import ImageIO
import Vision

/// Straightens a photo taken with a tilted head before it goes to iPhone Photos. The glasses keep an
/// "auto level" switch (media_auto_leveling_enabled), but nothing on them reads it: the Meta app levels
/// photos on the phone. This does the same with Vision's horizon detection. The original stays as it is.
enum PhotoLeveling {
    static let enabledKey = "levelPhotosOnSave"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Below this a correction is not visible; above it the "horizon" is more likely a slanted roof or desk.
    static let minimumDegrees = 0.8
    static let maximumDegrees = 12.0

    static func shouldLevel(degrees: Double) -> Bool {
        abs(degrees) >= minimumDegrees && abs(degrees) <= maximumDegrees
    }

    /// The tilt Vision sees, in radians, counter-clockwise positive; nil when there is none to fix.
    static func horizonAngle(of image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        let angle = Double(observation.angle)
        return shouldLevel(degrees: angle * 180 / .pi) ? angle : nil
    }

    /// A level HEIC copy at the original size, or nil when the photo is already level (or unreadable).
    static func leveledCopy(of url: URL) -> (url: URL, degrees: Double)? {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let angle = horizonAngle(of: source) else { return nil }
        let extent = source.extent
        // Rotating by the opposite angle levels the horizon; the filter enlarges and crops to the original size.
        let straightened = source.applyingFilter("CIStraightenFilter", parameters: [kCIInputAngleKey: -angle])
            .cropped(to: extent)
        var properties = source.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let image = straightened.settingProperties(properties)
        guard let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID().uuidString).heic")
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        do {
            try CIContext().writeHEIFRepresentation(of: image, to: output, format: .RGBA8, colorSpace: space,
                                                    options: [quality: 0.92])
        } catch {
            return nil
        }
        return (output, angle * 180 / .pi)
    }
}
