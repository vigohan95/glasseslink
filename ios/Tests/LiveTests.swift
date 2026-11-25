import CoreMedia
import Foundation
import XCTest
@testable import GlassesLink

final class LiveTests: XCTestCase {
    func testAnnexBWithMixedStartCodesPreservesVideoNALUnits() {
        let keyframe = Data([0x26, 0x01, 0xB0])
        let predicted = Data([0x02, 0x01, 0xD0])
        let frame = Data([0, 0, 0, 1]) + keyframe + Data([0, 0, 1]) + predicted
        let units = LiveStream.annexBUnits(frame)

        XCTAssertEqual(units, [keyframe, predicted])
        XCTAssertEqual(units.compactMap(LiveStream.hevcNALType), [19, 1])
    }

    func testPreviewSampleCopiesLengthPrefixedNALsAndDisplaysImmediately() throws {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
            width: 360, height: 640, extensions: nil, formatDescriptionOut: &description), noErr)
        let format = try XCTUnwrap(description)
        let pts = CMTime(value: 1_234_567, timescale: 1_000_000)
        let sample = try XCTUnwrap(LiveStream.sampleBuffer(units: [Data([0x02, 0x01, 0xD0])], format: format,
            pts: pts, isSync: false))

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), pts)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var copied = Data(count: 7)
        let status = copied.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count, destination: buffer.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        XCTAssertEqual(copied, Data([0, 0, 0, 3, 0x02, 0x01, 0xD0]))

        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false))
        XCTAssertEqual(CFArrayGetCount(attachments), 1)
        let first = try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(first).takeUnretainedValue()
        for key in [kCMSampleAttachmentKey_DisplayImmediately, kCMSampleAttachmentKey_NotSync] {
            let value = try XCTUnwrap(CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()))
            XCTAssertTrue(CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue()))
        }
    }
}
