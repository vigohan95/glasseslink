// SessionLoopbackTests.swift — the handshake, svc18 and svc20 against a fake peer.
//
// Everything here runs in-process over bound streams: no glasses, no Bluetooth, no
// simulator privileges. If these pass, the only remaining unknowns on real hardware are
// the PSM handshake and the glasses' own opinions.

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
                               log: { print("glass: \($0)") })
        peer.start()

        let session = Session(stream: phoneStream, owner: owner, log: { print("phone: \($0)") })

        // the phone side has to run off the main thread: the stream callbacks are
        // scheduled on the main run loop, which `wait(for:)` keeps spinning.
        let done = expectation(description: "loopback session")
        var captured: [String: Any] = [:]
        var failure: String?

        let worker = Thread {
            do {
                try session.handshake(timeout: 10)
                captured["handshake"] = true

                let caps = try session.captureList(timeout: 10)
                captured["captures"] = caps.count
                captured["handle"] = caps.first?.handle
                captured["size"] = caps.first?.stills.first?.size

                try session.requestAsset(handle: "cap-1", assetID: "asset-a")
                let transfer = try session.receiveFile(timeout: 10)
                captured["file"] = transfer?.name
                captured["bytes"] = transfer?.data
                captured["count"] = transfer?.data.count
            } catch {
                failure = "\(error)"
            }
            done.fulfill()
        }
        worker.name = "loopback-phone"
        worker.start()

        wait(for: [done], timeout: 45)

        if let failure {
            XCTFail("session failed: \(failure)")
        }
        XCTAssertNil(peer.failure, "fake peer rejected something: \(peer.failure ?? "")")
        XCTAssertTrue(peer.sawTrust, "the peer never verified our trust signature")
        XCTAssertTrue(peer.sawEndLinkStatus, "EndLinkSetup was not acknowledged")
        XCTAssertTrue(peer.gotDrop, "the peer never received the mandatory type 7 drop")
        XCTAssertEqual(captured["captures"] as? Int, 1)
        XCTAssertEqual(captured["handle"] as? String, "cap-1")
        XCTAssertEqual(captured["size"] as? Int, 2_730_026)
        XCTAssertEqual(captured["file"] as? String, "Visor_20261123_110000.jpg")
        XCTAssertEqual((captured["bytes"] as? Data)?.count, payload.count)
        XCTAssertEqual(captured["bytes"] as? Data, payload, "transferred bytes differ")
    }

    /// The provisioning link skips trust entirely: the glasses do not know our key yet,
    /// which is exactly why the owner can be moved onto a new device without Meta.
    func testHandshakeWithoutTrust() throws {
        let owner = OwnerMaterial.generate()
        let (phoneStream, glassStream) = SDUStream.loopbackPair()
        let peer = FakeGlasses(stream: glassStream, records: [],
                               file: ("unused", Data()), expectTrust: false,
                               log: { print("glass: \($0)") })
        peer.start()

        let session = Session(stream: phoneStream, owner: owner, log: { print("phone: \($0)") })
        let done = expectation(description: "setup-only handshake")
        var failure: String?
        let worker = Thread {
            do {
                try session.handshake(timeout: 10, trust: false)
            } catch {
                failure = "\(error)"
            }
            done.fulfill()
        }
        worker.start()
        wait(for: [done], timeout: 30)
        if let failure { XCTFail("setup handshake failed: \(failure)") }
    }
}
