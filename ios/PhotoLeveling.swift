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

    /// Vision's horizon angle in radians. CI showed it is the rotation that levels the picture, in Core
    /// Image's counter-clockwise convention: a horizon rising 6° to the right reads as about -6°.
    static func detectedHorizon(of image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        return Double(observation.angle)
    }

    /// The correction to apply, or nil when there is none worth making.
    static func levelingAngle(of image: CIImage) -> Double? {
        guard let angle = detectedHorizon(of: image), shouldLevel(degrees: angle * 180 / .pi) else { return nil }
        return angle
    }

    /// Rotated by `angle` (Vision's value as it comes), enlarged and cropped back to the original size.
    static func straightened(_ image: CIImage, by angle: Double) -> CIImage {
        image.applyingFilter("CIStraightenFilter", parameters: [kCIInputAngleKey: angle]).cropped(to: image.extent)
    }

    /// A level HEIC copy at the original size, or nil when the photo is already level (or unreadable).
    static func leveledCopy(of url: URL) -> (url: URL, degrees: Double)? {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let angle = levelingAngle(of: source) else { return nil }
        let level = straightened(source, by: angle)
        var properties = source.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let image = level.settingProperties(properties)
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
