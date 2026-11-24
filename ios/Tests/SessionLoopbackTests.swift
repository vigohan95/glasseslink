// SessionLoopbackTests.swift — the handshake, svc18 and svc20 against a fake peer.
//
// The loopback pipe needs no run loop: writes land straight in the peer's buffer, so the
// fake peer runs on a background queue while the test drives the session on its own
// thread. Every step has an explicit timeout, so a protocol mismatch fails with a message
// instead of hanging the test runner.

import XCTest
@testable import GlassesLink

final class SessionLoopbackTests: XCTestCase {
    /// The two sides must agree on x(S) for ECDH; this is the same arithmetic the glasses
    /// do, so a here-failure means the packing helpers are wrong, not the transport.
    func testEcdhAgreesBothWays() throws {
        let a = OwnerMaterial(scalar: Data((0 ..< 32).map { UInt8($0 + 1) }))
        let b = OwnerMaterial(scalar: Data(repeating: 1, count: 32))
        print("[ecdh] a.xy=\(a.publicKeyXy.count) b.xy=\(b.publicKeyXy.count) b.head=\(b.publicKeyXy.prefix(4).hexShort)")
        print("[ecdh] pkcs8=\(Provisioner.pkcs8(from: a).count) sec1 ok")
        print("[ecdh] import style=\(OwnerMaterial.importStyle ?? "none")")
        let ab = try a.sharedSecret(peerPubkeyXy: b.publicKeyXy)
        let ba = try b.sharedSecret(peerPubkeyXy: a.publicKeyXy)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.count, 32)
    }
    /// Cheap canary: these two calls happen at the top of `Session.handshake`, so if the
    /// loopback test hangs before its first frame, one of them is the reason.
    func testOwnerMaterialBasics() throws {
        let owner = OwnerMaterial(scalar: Data((0 ..< 32).map { UInt8($0 + 1) }))
        print("[m] scalar ok")
        let xy = owner.publicKeyXy
        print("[m] publicKeyXy \(xy.count)")
        print("[m] random \(Data.random(16).count)/\(Data.random(32).count)")
        XCTAssertEqual(xy.count, 64)
        // and it must match what the glasses will hash: 0x04 || x || y
        XCTAssertEqual(owner.publicKey65.count, 65)
    }
    func testFullHandshakeCaptureListAndTransfer() throws {
        // The fake peer still does not complete its side of the link; the signer it uses is
        // now verified, so what remains is the peer's own setup path.

        let owner = OwnerMaterial(scalar: Data((0 ..< 32).map { UInt8($0 + 1) }))

        let (phoneStream, glassStream) = SDUStream.loopbackPair()

        let record = FlatBuild.captureRecord(handle: "cap-1", kind: 3073,
                                            timestampNS: 1_700_000_000_000_000_000,
                                            assets: [("asset-a", 2, 2_730_026)])
        let payload = Data((0 ..< 5120).map { UInt8($0 % 256) })
        print("[loop] A owner+pair+record built")
        let peer = FakeGlasses(stream: glassStream, records: [record],
                               file: ("Visor_20261123_110000.jpg", payload),
                               log: { print("[glass] \($0)") })
        peer.start()
        print("[loop] B peer started")

        let session = Session(stream: phoneStream, owner: owner,
                              log: { print("[phone] \($0)") })
        print("[loop] C session built, handshaking")

        try session.handshake(timeout: 15)
        print("[loop] D handshake returned")

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
        let owner = OwnerMaterial(scalar: Data((0 ..< 32).map { UInt8($0 + 1) }))
        let (phoneStream, glassStream) = SDUStream.loopbackPair()
        // KNOWN ISSUE (2026-11-23): the setup-only link still hangs against the fake peer
        // while the trusted link gets no further than its first frame, so the fake peer is
        // not yet a faithful server. Tracked in PROGRESS.md; skipping keeps CI meaningful.
        print("[loop] no-trust variant starts")
        let peer = FakeGlasses(stream: glassStream, records: [],
                               file: ("unused", Data()), expectTrust: false,
                               log: { print("[glass] \($0)") })
        peer.start()

        let session = Session(stream: phoneStream, owner: owner,
                              log: { print("[phone] \($0)") })
        try session.handshake(timeout: 15, trust: false)
        XCTAssertNil(peer.failure, "fake peer rejected the setup link: \(peer.failure ?? "")")
        XCTAssertTrue(peer.sawEndLinkStatus, "EndLinkSetup was not acknowledged")
    }
}
