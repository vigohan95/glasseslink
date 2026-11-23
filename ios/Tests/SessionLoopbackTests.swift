// SessionLoopbackTests.swift — the handshake, svc18 and svc20 against a fake peer.
//
// The loopback pipe needs no run loop: writes land straight in the peer's buffer, so the
// fake peer runs on a background queue while the test drives the session on its own
// thread. Every step has an explicit timeout, so a protocol mismatch fails with a message
// instead of hanging the test runner.

import XCTest
@testable import GlassesLink

final class SessionLoopbackTests: XCTestCase {
    func testFullHandshakeCaptureListAndTransfer() throws {
        let owner = OwnerMaterial.generate()
        let (phoneStream, glassStream) = SDUStream.loopbackPair()

        let record = FlatBuild.captureRecord(handle: "cap-1", kind: 3073,
                                            timestampNS: 1_700_000_000_000_000_000,
                                            assets: [("asset-a", 2, 2_730_026)])
        let payload = Data((0 ..< 5120).map { UInt8($0 % 256) })
        let peer = FakeGlasses(stream: glassStream, records: [record],
                               file: ("Visor_20261123_110000.jpg", payload),
                               log: { NSLog("glass: %@", $0) })
        peer.start()

        let session = Session(stream: phoneStream, owner: owner,
                              log: { NSLog("phone: %@", $0) })

        try session.handshake(timeout: 15)

        let caps = try session.captureList(timeout: 15)
        XCTAssertEqual(caps.count, 1)
        XCTAssertEqual(caps.first?.handle, "cap-1")
        XCTAssertTrue(caps.first?.isPhoto ?? false)
        XCTAssertEqual(caps.first?.stills.first?.size, 2_730_026)

        try session.requestAsset(handle: "cap-1", assetID: "asset-a")
        let transfer = try session.receiveFile(timeout: 15)
        XCTAssertEqual(transfer?.name, "Visor_20261123_110000.jpg")
        XCTAssertEqual(transfer?.data.count, payload.count)
        XCTAssertEqual(transfer?.data, payload, "transferred bytes differ")

        XCTAssertNil(peer.failure, "fake peer rejected something: \(peer.failure ?? "")")
        XCTAssertTrue(peer.sawTrust, "the peer never verified our trust signature")
        XCTAssertTrue(peer.sawEndLinkStatus, "EndLinkSetup was not acknowledged")
        XCTAssertTrue(peer.gotDrop, "the peer never received the mandatory type 7 drop")
    }

    /// The provisioning link skips trust entirely: the glasses do not know our key yet,
    /// which is exactly why the owner can be moved onto a new device without Meta.
    func testHandshakeWithoutTrust() throws {
        let owner = OwnerMaterial.generate()
        let (phoneStream, glassStream) = SDUStream.loopbackPair()
        let peer = FakeGlasses(stream: glassStream, records: [],
                               file: ("unused", Data()), expectTrust: false,
                               log: { NSLog("glass: %@", $0) })
        peer.start()

        let session = Session(stream: phoneStream, owner: owner,
                              log: { NSLog("phone: %@", $0) })
        try session.handshake(timeout: 15, trust: false)
        XCTAssertNil(peer.failure, "fake peer rejected the setup link: \(peer.failure ?? "")")
        XCTAssertTrue(peer.sawEndLinkStatus, "EndLinkSetup was not acknowledged")
    }
}
