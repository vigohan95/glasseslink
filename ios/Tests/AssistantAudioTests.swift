import Foundation
import XCTest
@testable import GlassesLink

final class AssistantAudioTests: XCTestCase {
    func testNetEventSupportsPlainAndZlibWrappedBodies() throws {
        let body = ThriftWriter().string(1, "test-wake-1").i32(2, 1).done()
        // Independent zlib fixture for the compact-Thrift body above.
        let compressed = Data([
            0x78, 0x9C, 0x93, 0xE0, 0x2E, 0x49, 0x2D, 0x2E, 0xD1, 0x2D, 0x4F, 0xCC,
            0x4E, 0xD5, 0x35, 0x14, 0x65, 0x62, 0x00, 0x00, 0x28, 0x3A, 0x04, 0x2E,
        ])
        let plainFields = try ThriftCompact.loads(ThriftWriter().i32(1, 289).binary(2, body).bool(3, false).done())
        let compressedFields = try ThriftCompact.loads(ThriftWriter().i32(1, 289).binary(2, compressed).bool(3, true).done())

        XCTAssertEqual(Assistant.netEventBody(plainFields), body)
        XCTAssertEqual(Assistant.netEventBody(compressedFields), body)

        var invalidChecksum = compressed
        invalidChecksum[invalidChecksum.count - 1] = 0
        XCTAssertNil(Assistant.netEventBody([2: invalidChecksum, 3: true]))
        XCTAssertNil(Assistant.netEventBody([2: compressed.dropLast(), 3: true]))
    }

    func testSpeechStartRequiresMatchingPlainTurnAndIsClaimedOnce() {
        var turn = Assistant.Turn(wakeID: "active-wake", relatedWakeID: "active-mic")
        XCTAssertNil(turn.claimSpeechStart([1: "other-wake", 2: 1]))
        XCTAssertNil(turn.claimSpeechStart([1: "active-wake", 2: 2]))
        XCTAssertNil(turn.claimSpeechStart([1: "active-wake"]))
        XCTAssertEqual(turn.claimSpeechStart([1: "active-mic", 2: 1]), "active-mic")
        XCTAssertNil(turn.claimSpeechStart([1: "active-mic", 2: 1]))

        var unsupported = Assistant.Turn(wakeID: "active-wake", supportsSpeech: false)
        XCTAssertNil(unsupported.claimSpeechStart([1: "active-wake", 2: 1]))
    }

    func testUntaggedMessagesInheritOnlyFromTheSameWireChannel() throws {
        let messages: UInt16 = 5
        let microphone: UInt16 = 6
        let transcript = try DataX.parse(DataX.message(messages, tags: [DataX.tag(2, 1010, last: true)]))
        let audio = try DataX.parse(DataX.message(microphone, tags: [DataX.tag(2, 5003, last: true)]))
        let implicitMessage = try DataX.parse(DataX.message(messages, tags: []))
        let implicitAudio = try DataX.parse(DataX.message(microphone, tags: []))
        let implicitMirror = try DataX.parse(DataX.message(messages ^ 0x8000, tags: []))
        let status = try DataX.parse(DataX.status(messages, AirShield.stSuccess))
        var cache = Assistant.IncomingTypes()

        XCTAssertNil(cache.resolve(implicitMessage))
        XCTAssertEqual(cache.resolve(transcript), 1010)
        XCTAssertEqual(cache.resolve(audio), 5003)
        XCTAssertNil(cache.resolve(status))
        XCTAssertNil(cache.resolve(implicitMirror))
        XCTAssertEqual(cache.resolve(implicitMessage), 1010)
        XCTAssertEqual(cache.resolve(implicitAudio), 5003)
    }

    func testMissingTranscriptNeedsAudioAndGraceAfterStreamEnd() {
        var stream = Assistant.MicrophoneStream()
        stream.noteAudio(bytes: 0)
        XCTAssertFalse(stream.shouldReportMissingTranscript(at: 11))

        stream.noteAudio(bytes: 50)
        XCTAssertFalse(stream.shouldReportMissingTranscript(at: 100))
        XCTAssertTrue(stream.finish(at: 12))
        XCTAssertFalse(stream.shouldReportMissingTranscript(at: 14.99))
        XCTAssertTrue(stream.shouldReportMissingTranscript(at: 15))

        stream.reportedMissingTranscript = true
        XCTAssertFalse(stream.shouldReportMissingTranscript(at: 20))
        XCTAssertFalse(stream.finish(at: 20))
        stream.noteAudio(bytes: 50)
        XCTAssertEqual(stream.frames, 1)
        XCTAssertEqual(stream.bytes, 50)
    }

    func testMicrophoneDiagnosticsRemainBoundedWithoutRetainingAudio() {
        var stream = Assistant.MicrophoneStream()
        for _ in 0..<5_000 { stream.noteAudio(bytes: 4_000) }

        XCTAssertEqual(stream.frames, 4_096)
        XCTAssertEqual(stream.bytes, 1_048_576)
    }

    func testEmptyStreamDoesNotReportUnrecognizedSpeech() {
        var stream = Assistant.MicrophoneStream()
        XCTAssertTrue(stream.finish(at: 10))
        XCTAssertFalse(stream.shouldReportMissingTranscript(at: 14))
    }

    func testCompactNestedPayloadReadsWithinTheAvailableSlice() throws {
        let body = ThriftWriter().string(1, "normal title").done()
        let event = ThriftWriter().structField(1, body).done()
        let storage = Data([0xFF]) + event
        let nested = try ThriftCompact.loads(storage.dropFirst()).structField(1)

        XCTAssertEqual(nested.text(1), "normal title")
        XCTAssertThrowsError(try ThriftCompact.loads(event.dropLast(4)))
    }

    func testCompactBooleanListConsumesEachEncodedElement() throws {
        let event = Data([0x19, 0x21, TC.tTrue, TC.tFalse, TC.stop])
        let fields = try ThriftCompact.loads(event)

        XCTAssertEqual(fields[1] as? [Bool], [true, false])
    }
}
