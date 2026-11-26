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

    func testCompactMapOfStringToStructListParsesAndLaterFieldsSurvive() throws {
        let slot = ThriftWriter().string(4, "Beijing").done()
        var event = Data([0x0B, 0x34])                 // field 26 (long form), type map
        event += [0x01, 0x89]                           // one entry, key binary, value list
        event += Data([0x08]) + Data("location".utf8)
        event += Data([0x1C]) + slot                    // list of one struct
        event += Data([0x18, 0x05]) + Data("after".utf8) // field 27 binary
        event += [TC.stop]
        let fields = try ThriftCompact.loads(event)

        let slots = fields.mapField(26)["location"] as? [Any]
        XCTAssertEqual((slots?.first as? [Int: Any])?.text(4), "Beijing")
        XCTAssertEqual(fields.text(27), "after")
    }

    func testCompactBoolMapEmptyMapFloatAndDouble() throws {
        var event = Data([0x1B, 0x02, 0x81, 0x01, 0x61, 0x01, 0x01, 0x62, 0x02]) // 1: {"a": true, "b": false}
        event += [0x1B, 0x00]                                                    // 2: {}
        event += [0x1D, 0x3F, 0xC0, 0x00, 0x00]                                  // 3: float 1.5 (big-endian)
        event += [0x17, 0, 0, 0, 0, 0, 0, 0x02, 0x40]                            // 4: double 2.25 (little-endian)
        event += [0x15, 0x0E, TC.stop]                                           // 5: i32 7
        let fields = try ThriftCompact.loads(event)

        XCTAssertEqual(fields.mapField(1)["a"] as? Bool, true)
        XCTAssertEqual(fields.mapField(1)["b"] as? Bool, false)
        XCTAssertTrue(fields.mapField(2).isEmpty)
        XCTAssertEqual(fields[3] as? Double, 1.5)
        XCTAssertEqual(fields[4] as? Double, 2.25)
        XCTAssertEqual(fields.int(5), 7)
        XCTAssertThrowsError(try ThriftCompact.loads(Data([0x1B, 0x05, 0x88, 0x01, 0x61])))
    }

    func testFulfillmentRequestWithSlotMapYieldsTheGlassesTranscript() throws {
        let asr = ThriftWriter().string(1, "今天天气怎么样").done()
        let understanding = ThriftWriter().structField(1, asr).done()
        var body = Data(ThriftWriter().string(1, "turn-1").structField(2, understanding).done().dropLast())
        body += Data([0x0B, 0x34, 0x01, 0x89, 0x04]) + Data("city".utf8)
        body += Data([0x1C]) + ThriftWriter().string(4, "北京").done()
        body += [TC.stop]
        let request = Assistant.spokenRequest(try ThriftCompact.loads(body))

        XCTAssertEqual(request?.interaction, "turn-1")
        XCTAssertEqual(request?.transcript, "今天天气怎么样")
    }

    func testUndecodableEventReportsInflateAndThriftFailures() {
        let broken = Assistant.describeUndecodableEvent([1: Int64(57), 2: Data([0x78, 0x9C, 0x01, 0x02, 0x03, 0x04, 0x05]), 3: true])
        XCTAssertTrue(broken.contains("inflate failed"), broken)
        let unknownType = Assistant.describeUndecodableEvent([1: Int64(57), 2: Data([0x1E, 0x00]), 3: false])
        XCTAssertTrue(unknownType.contains("bad compact type 14"), unknownType)
        XCTAssertTrue(unknownType.contains("decoded=2B"), unknownType)
    }
}
