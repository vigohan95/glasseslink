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

    func testDeviceVolumeDistinguishesUnavailableFromMuted() {
        var state = GlassesState()
        Status.merge(bytes("ca0106080710011823"), into: &state)
        XCTAssertEqual(state.volumePercent, 35)
        XCTAssertEqual(state.volumeLevel, 7)
        XCTAssertEqual(state.volumeStream, "MEDIA")

        Status.merge(bytes("ca0108100318ffffffff0f"), into: &state)
        XCTAssertNil(state.volumePercent)
        XCTAssertNil(state.volumeLevel)
        XCTAssertEqual(state.volumeStream, "CURRENT")

        Status.merge(bytes("ca0106080010021800"), into: &state)
        XCTAssertEqual(state.volumePercent, 0)
        XCTAssertEqual(state.volumeLevel, 0)
        XCTAssertEqual(state.volumeStream, "TELEPHONY")
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

    private func mediaOffer(channel: UInt16, id: Data, size: UInt64) -> Data {
        let tags = [DataX.tag(1, UInt16(Session.svcAirship), last: false),
                    DataX.tag(2, Session.airOffer, last: true)]
        let payload = PB.bytes(1, id) + PB.uint(2, size) + PB.string(3, "namespace_media")
            + PB.string(4, "example.heic")
        return DataX.message(channel, tags: tags, payload: payload)
    }

    private struct EncryptedPeer {
        let stream: SDUStream
        let send: Direction
        let recv: Direction

        func write(_ frame: Data) throws { try stream.write(send.seal(frame)) }
        func nextFrame(timeout: TimeInterval) throws -> Data { try recv.open(stream.nextFrame(timeout: timeout)) }
    }

    private func encryptedLoopback() throws -> (Session, EncryptedPeer) {
        let (client, stream) = SDUStream.loopbackPair()
        let session = Session(stream: client, owner: OwnerMaterial(scalar: Data(repeating: 1, count: 32)))
        let owner = OwnerMaterial(scalar: Data(repeating: 2, count: 32))
        let challenge = Data(repeating: 3, count: 16)
        let seed = Data(repeating: 4, count: 32)
        let iv = Data(repeating: 5, count: 16)
        let base: UInt32 = 9

        // Preload the peer's plaintext offers so setup does not wait for the passive window.
        try stream.write(AirShield.requestEncryption(pubkey: owner.publicKeyXy, challenge: challenge))
        try stream.write(AirShield.enableEncryption(pubkey: owner.publicKeyXy, seed: seed, iv: iv, baseSeq: base))
        let ready = expectation(description: "The encrypted setup link opened")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { ready.fulfill() }
            do { try session.handshake(timeout: 4, trust: false) }
            catch { XCTFail("Encrypted test setup failed: \(error)") }
        }
        defer { wait(for: [ready], timeout: 5) }

        let request = try PB.parse(DataX.parse(stream.nextFrame(timeout: 4)).payload)
        let enable = try PB.parse(DataX.parse(stream.nextFrame(timeout: 4)).payload)
        let phonePublicKey = try XCTUnwrap(request[1]?.first as? Data)
        let phoneChallenge = try XCTUnwrap(request[2]?.first as? Data)
        let phoneSeed = try XCTUnwrap(enable[2]?.first as? Data)
        let phoneIV = try XCTUnwrap(enable[3]?.first as? Data)
        let phoneBase = try XCTUnwrap(UInt32(exactly: (enable[4]?.first as? Int) ?? -1))
        let shared = try owner.sharedSecret(peerPubkeyXy: phonePublicKey)
        let keys = try AirShield.sessionKeys(shared: shared, ownChallenge: challenge, ownSeed: seed,
                                             peerChallenge: phoneChallenge, peerSeed: phoneSeed,
                                             ownIV: iv, peerIV: phoneIV, peerBaseSeq: phoneBase,
                                             quirks: .none, multikey: true)
        keys.send.seq = base
        let peer = EncryptedPeer(stream: stream, send: keys.send, recv: keys.recv)
        let endSetup = try DataX.parse(peer.nextFrame(timeout: 4))
        XCTAssertTrue(Session.isEndLinkSetupRequest(endSetup))
        try peer.write(AirShield.endLinkStatus)
        return (session, peer)
    }

    func testHandshakePropagatesClosedTransportDuringPassiveWait() {
        let (client, _) = SDUStream.loopbackPair()
        client.close()
        let session = Session(stream: client, owner: OwnerMaterial(scalar: Data(repeating: 1, count: 32)))
        let returned = expectation(description: "Handshake exited after the data link closed")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { returned.fulfill() }
            do {
                try session.handshake(timeout: 1, trust: false)
                XCTFail("Handshake unexpectedly succeeded on a closed transport")
            } catch {
                XCTAssertEqual(String(describing: error), "io: stream closed")
            }
        }
        wait(for: [returned], timeout: 2)
    }

    func testCatalogDeclinesAnUnrequestedOfferOnItsMirror() throws {
        let (session, peer) = try encryptedLoopback()
        let id = bytes("00112233445546778999aabbccddeeff")
        try peer.write(mediaOffer(channel: 0x8006, id: id, size: 256))
        try peer.write(DataX.message(0x0002, tags: [DataX.tag(2, Session.capEnd, last: true)]))

        XCTAssertTrue(try session.captureList(timeout: 1).isEmpty)
        let request = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(request.type, Int(Session.capEnum))
        let reply = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(reply.channel, 0x0006)
        XCTAssertEqual(reply.type, Int(Session.airDrop))
        XCTAssertEqual(reply.payload, PB.bytes(1, id))
    }

    func testMediaImportAcceptsSelectedOfferBeforeTheAssetAcknowledgement() throws {
        let (session, peer) = try encryptedLoopback()
        let id = bytes("00112233445546778999aabbccddeeff")
        let content = Data("example".utf8)
        let offerChannel: UInt16 = 0x8008
        try session.requestAsset(handle: "capture-1", assetID: "00112233-4455-4677-8999-aabbccddeeff")
        let selected = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(selected.type, Int(Session.capRequestAsset))
        let route = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(route.type, Int(Session.capSetLink))
        XCTAssertEqual(route.payload, Data("capture-1:1".utf8))

        try peer.write(mediaOffer(channel: offerChannel, id: id, size: UInt64(content.count)))
        try peer.write(DataX.message(0x0002, tags: [DataX.tag(2, Session.capAssetQueued, last: true)]))
        try peer.write(DataX.message(offerChannel, tags: [DataX.tag(2, Session.airData, last: true)], payload: content))
        let completion = PB.uint(1, UInt64(content.count)) + PB.uint(2, UInt64(Session.adler32(content)))
        try peer.write(DataX.message(offerChannel, tags: [DataX.tag(2, Session.airComplete, last: true)], payload: completion))

        let result = try XCTUnwrap(session.receiveFile(timeout: 1))
        XCTAssertEqual(result.name, "example.heic")
        XCTAssertEqual(result.data, content)
        let cursor = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(cursor.channel, 0x0008)
        XCTAssertEqual(cursor.type, Int(Session.airCursor))
        XCTAssertEqual(cursor.payload, PB.uint(2, 1))
        let drop = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(drop.channel, 0x0008)
        XCTAssertEqual(drop.type, Int(Session.airDrop))
        XCTAssertEqual(drop.payload, PB.bytes(1, id))
    }

    func testShutterConfirmationUsesCameraEventsOnSubscriptionMirror() throws {
        let (session, peer) = try encryptedLoopback()
        let mirror = Session.chLocalFirst ^ 0x8000
        let snapshot = PB.bytes(1, PB.uint(3, 60)) + PB.bytes(21, PB.uint(1, 1024))
        try peer.write(DataX.message(mirror, tags: [DataX.tag(2, 2005, last: true)], payload: snapshot))
        _ = try session.subscribeStatus(timeout: 1)

        let start = PB.uint(3, UInt64(Status.photoStarted))
        let wrongChannel = [DataX.tag(1, UInt16(Status.service), last: false), DataX.tag(2, 2009, last: true)]
        try peer.write(DataX.message(mirror + 1, tags: wrongChannel, payload: start))
        try peer.write(DataX.message(mirror, tags: [DataX.tag(2, 2005, last: true)], payload: start))
        try peer.write(DataX.message(mirror, tags: [DataX.tag(2, 2009, last: true)]))
        let matched = start + PB.bytes(1, PB.uint(3, 61))
        try peer.write(DataX.message(mirror, tags: [], payload: matched))

        let state = try session.confirmedShutter(Shutter.photoPayload()) { $0 == Status.photoStarted }
        XCTAssertEqual(state.batteryPercent, 61)
        XCTAssertEqual(state.camera, Status.cameraName(Status.photoStarted))
    }

    func testSettingsReadMatchesRequestAndFinishesTheSyncOnEitherChannel() throws {
        let (session, peer) = try encryptedLoopback()
        let settingsPeer: UInt16 = 0x8009
        let key = "example_setting"
        let value = "true"
        let namespace = Drive.deviceSettings
        let answered = expectation(description: "The settings peer saw round two")

        DispatchQueue.global().async {
            defer { answered.fulfill() }
            do {
                let ask = try DataX.parse(peer.nextFrame(timeout: 2))
                let request = try XCTUnwrap(Drive.decode(ask.payload))
                XCTAssertEqual(request.round, 0)
                let named = [DataX.tag(1, UInt16(Drive.service), last: false),
                             DataX.tag(2, Drive.syncMessage, last: true)]
                let unrelated = Drive.build(namespace: namespace, requestID: "older-request", round: 1,
                                            types: [Drive.kv])
                try peer.write(DataX.message(settingsPeer, tags: named, payload: unrelated))

                let found = Drive.Object(uri: key, type: Drive.kv, data: value, deleted: false, raw: Data())
                let reply = Drive.build(namespace: namespace, requestID: request.requestID, round: 1,
                                        types: [Drive.kv], objects: [found])
                try peer.write(DataX.message(settingsPeer, tags: [], payload: reply))

                let sync = try DataX.parse(peer.nextFrame(timeout: 2))
                let roundTwo = try XCTUnwrap(Drive.decode(sync.payload))
                XCTAssertEqual(roundTwo.round, 2)
                XCTAssertEqual(roundTwo.requestID, request.requestID)
                let done = Drive.build(namespace: namespace, requestID: request.requestID, round: 3,
                                       types: [Drive.kv], terminated: true)
                try peer.write(DataX.message(ask.channel ^ 0x8000, tags: [], payload: done))
            } catch {
                XCTFail("Settings loopback failed: \(error)")
            }
        }

        defer { wait(for: [answered], timeout: 3) }
        let values = try session.driveObjects(types: [Drive.kv], timeout: 3)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.uri, key)
        XCTAssertEqual(values.first?.data, value)
    }
}
