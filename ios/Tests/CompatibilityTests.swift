// CompatibilityTests.swift — the Swift encoders against vectors produced by an
// independent transcription of the same spec (`tools/golden.py`).
//
// The point is not "does it round-trip with itself" (the loopback test would cover that)
// but "did the Swift side and the Python side read the Kotlin sources the same way".
// A mismatch here would show up on the real device as a silent `service_not_found` or a
// rejected trust message, which is expensive to debug over Bluetooth.

import XCTest
@testable import GlassesLink

final class CompatibilityTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func bytes(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i ..< j], radix: 16)!)
            i = j
        }
        return out
    }

    /// svc36 EnableTrust on the first locally allocated application channel.
    func testTrustFrameMatchesTheReferenceTranscription() {
        let pub = Data((0 ..< 64).map { UInt8($0) })
        let sig = Data((0 ..< 64).map { UInt8($0) })
        let expected = "806e80028100002402001000"
            + "0a20fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"
            + "1240000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
            + "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f1802"
        XCTAssertEqual(try hex(AirShield.trustMessage(channel: Session.chLocalFirst, ownerPubkey: pub, signatureRaw: sig)), expected)
    }

    /// EndLinkSetup is exactly 46 bytes and the two UUIDs must be RFC 4122 v4.
    func testEndLinkSetupMatchesTheReferenceTranscription() throws {
        let stream = bytes("00112233445546778999aabbccddeeff")
        let link = bytes("0f1e2d3c4b5a49678896a5b4c3d2e1f0")
        let frame = try AirShield.endLinkSetup(streamUUID: stream, linkUUID: link)
        XCTAssertEqual(frame.count, 46)
        XCTAssertEqual(hex(frame), "802a8001020010000801121000112233445546778999aabbccddeeff1a100f1e2d3c4b5a49678896a5b4c3d2e1f0")
    }

    /// svc31 carries a single field, so these are the three payload shapes that matter.
    func testSettingsFieldPayloadsMatchTheReferenceTranscription() {
        XCTAssertEqual(hex(PB.uint(2, 1)), "1001")
        XCTAssertEqual(hex(PB.uint(5, 90)), "285a")
        XCTAssertEqual(hex(PB.uint(14, 3)), "7003")
        XCTAssertEqual(hex(PB.string(1, "abc")), "0a03616263")
    }

    func testStatusFrameMatchesTheReferenceTranscription() {
        XCTAssertEqual(hex(DataX.status(DataX.chSetupMirror, 0x1000)), "8004000103001000")
    }

    func testNativeCaptureRecordReadsWrappedFields() throws {
        // The root points to the capture table, which points to an asset vector and 64-bit metadata.
        let payload = bytes("0c00000006000800040000000800000014000000"
            + "0e0014000400000008000c00100000001000000010000000010c00001400000050000000"
            + "050000006361702d310000000100000014000000"
            + "0e00100004000800000000000c000000100000000c000000020010002aa82900"
            + "0700000061737365742d3100"
            + "06000c0004000000000000000c00000015cd853dfe9c9717")
        let capture = try XCTUnwrap(Session.parseCapture(payload))
        XCTAssertEqual(capture.handle, "cap-1")
        XCTAssertEqual(capture.kind, 3073)
        XCTAssertEqual(capture.timestampNS, 1_700_000_000_123_456_789)
        XCTAssertEqual(capture.assets.count, 1)

        let still = try XCTUnwrap(capture.stills.first)
        XCTAssertEqual(still.uuid, "asset-1")
        XCTAssertEqual(still.size, 2_730_026)
        XCTAssertTrue(still.delivered)
    }
}
