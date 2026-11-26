// CompatibilityTests.swift — the Swift encoders against vectors produced by an
// independent transcription of the same spec (`tools/golden.py`).
//
// The point is not "does it round-trip with itself" (the loopback test would cover that)
// but "did the Swift side and the Python side read the Kotlin sources the same way".
// A mismatch here would show up on the real device as a silent `service_not_found` or a
// rejected trust message, which is expensive to debug over Bluetooth.

import AVFoundation
import CoreImage
import CryptoKit
import XCTest
@testable import GlassesLink

/// What a background handshake ended with, read after the loopback helper has waited for it.
private final class HandshakeOutcome: @unchecked Sendable {
    var error: Error?
}

private final class ResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

final class CompatibilityTests: XCTestCase {
    /// Kept partial transfers are process-wide; no test may inherit another's.
    override func setUp() {
        super.setUp()
        Session.resetResumeState()
    }

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

    func testDiscoveryUsesSystemNameBeforeAnAdvertisingAlias() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001234"))
        let entry = ScanEntry(id: id, peripheralName: " 我的眼镜 ", verifiedName: "之前的名称",
                              advertisementName: "广播别名", rssi: -55, isGlasses: true, isVerified: true)
        XCTAssertEqual(entry.displayName, "我的眼镜")
        XCTAssertEqual(entry.nameSourceLabel, "蓝牙名称")

        let cached = ScanEntry(id: id, peripheralName: "?", verifiedName: "之前的名称",
                               advertisementName: "广播别名", rssi: -55, isGlasses: true, isVerified: true)
        XCTAssertEqual(cached.displayName, "之前的名称")
        XCTAssertEqual(cached.nameSourceLabel, "曾验证时的名称")
    }

    func testDiscoveryDoesNotMarkAnUnverifiedAliasAsAKnownDevice() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001234"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000005678"))
        let saved = ScanEntry(id: firstID, verifiedName: "同名设备", rssi: 0, isGlasses: true,
                              isVerified: true, source: .previouslySelected)
        let candidate = ScanEntry(id: secondID, verifiedName: "同名设备", advertisementName: "同名设备",
                                   rssi: -60, isGlasses: true)
        XCTAssertEqual(saved.displayName, candidate.displayName)
        XCTAssertNotEqual(saved.id, candidate.id)
        XCTAssertNil(candidate.verifiedName)
        XCTAssertEqual(candidate.nameSourceLabel, "广播名称")
        XCTAssertTrue(saved.isListedBefore(candidate))

        let unnamed = ScanEntry(id: secondID, peripheralName: secondID.uuidString, advertisementName: "?",
                                 rssi: -60, isGlasses: true)
        XCTAssertEqual(unnamed.displayName, "未命名设备 · 5678")
        XCTAssertNil(unnamed.nameSourceLabel)
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

    func testPartialDeviceReportKeepsReadingsAndClearsExplicitlyUnavailableVolume() {
        var current = GlassesState()
        let battery = PB.bytes(1, PB.uint(3, 74))
        let storage = PB.bytes(21, PB.uint(1, 19_000) + PB.uint(2, 21_000))
        Status.merge(battery + storage + bytes("ca0106080710011823"), into: &current)

        var push = GlassesState()
        Status.merge(bytes("ca0108100318ffffffff0f"), into: &push)
        current.mergeReported(from: push)

        XCTAssertEqual(current.batteryPercent, 74)
        XCTAssertEqual(current.storageFreeMb, 19_000)
        XCTAssertEqual(current.storageTotalMb, 21_000)
        XCTAssertNil(current.volumePercent)
        XCTAssertEqual(current.volumeStream, "CURRENT")
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

    /// `peerKey` is the glasses' handshake key, `identityKey` the key their EnableTrust names (the same
    /// one unless given). An `outcome` collects the handshake's error instead of failing the test.
    private func encryptedLoopback(trust: Bool = false, peerKey: UInt8 = 2, identityKey: UInt8? = nil,
                                   expectedIdentity: Data? = nil,
                                   outcome: HandshakeOutcome? = nil) throws -> (Session, EncryptedPeer) {
        let (client, stream) = SDUStream.loopbackPair()
        let session = Session(stream: client, owner: OwnerMaterial(scalar: Data(repeating: 1, count: 32)))
        let owner = OwnerMaterial(scalar: Data(repeating: peerKey, count: 32))
        let identity = identityKey.map { OwnerMaterial(scalar: Data(repeating: $0, count: 32)) } ?? owner
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
            do { try session.handshake(timeout: 10, trust: trust, expectedPeerIdentity: expectedIdentity) }
            catch {
                if let outcome { outcome.error = error } else { XCTFail("Encrypted test setup failed: \(error)") }
            }
        }
        defer { wait(for: [ready], timeout: 12) }

        let request = try PB.parse(DataX.parse(stream.nextFrame(timeout: 10)).payload)
        let enable = try PB.parse(DataX.parse(stream.nextFrame(timeout: 10)).payload)
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
        let endSetup = try DataX.parse(peer.nextFrame(timeout: 10))
        XCTAssertTrue(Session.isEndLinkSetupRequest(endSetup))
        try peer.write(AirShield.endLinkStatus)
        if trust {
            let ownerRequest = try DataX.parse(peer.nextFrame(timeout: 10))
            XCTAssertEqual(ownerRequest.service, AirShield.svcIdentity)
            XCTAssertEqual(ownerRequest.type, Int(AirShield.idEnableTrust))
            let binding = AirShield.channelBinding(glassesChallenge: challenge, glassesPubkey: owner.publicKeyXy,
                                                   seed: phoneSeed, phonePubkey: phonePublicKey)
            let fields = try PB.parse(ownerRequest.payload)
            let proof = try XCTUnwrap(fields[2]?.first as? Data)
            XCTAssertTrue(P256ECDSA.verify(digest: binding, signature: proof, publicKeyXy: phonePublicKey))
            let peerChannel: UInt16 = 0x8008
            let peerProof = try identity.signRaw(digest: binding)
            try peer.write(AirShield.trustMessage(channel: peerChannel, ownerPubkey: identity.publicKeyXy,
                                                 signatureRaw: peerProof))
            try peer.write(DataX.status(ownerRequest.channel ^ 0x8000, AirShield.stSuccess))
            let accepted = try DataX.parse(peer.nextFrame(timeout: 10))
            XCTAssertEqual(accepted.channel, peerChannel ^ 0x8000)
            XCTAssertEqual(accepted.error, Int(AirShield.stSuccess))
        }
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

    func testCaptureDeletionRequiresCompletedOwnerTrust() throws {
        let (session, peer) = try encryptedLoopback()
        XCTAssertThrowsError(try session.requestCaptureDeletion(handle: "test-capture", timeout: 0.1)) { error in
            guard case LinkError.unexpected("删除前需要验证眼镜主人身份") = error else {
                return XCTFail("Expected the owner trust check, got \(error)")
            }
        }
        XCTAssertThrowsError(try peer.nextFrame(timeout: 0.1))
    }

    func testCaptureDeletionAcceptsOnlyTheMatchingMirrorAndHandle() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let capturesChannel = Session.chLocalFirst + 1
        let mirror = capturesChannel ^ 0x8000
        let ok = DataX.tag(2, Session.capDeleteOK, last: true)
        let failure = DataX.tag(2, Session.capDeleteFailed, last: true)
        let first = Data("test-capture".utf8)
        try peer.write(DataX.message(mirror + 1, tags: [ok], payload: first))
        try peer.write(DataX.message(mirror, tags: [ok], payload: Data("other-capture".utf8)))
        try peer.write(DataX.message(mirror, tags: [failure], payload: first + Data(":refused".utf8)))
        XCTAssertThrowsError(try session.requestCaptureDeletion(handle: "test-capture", timeout: 1)) { error in
            guard case LinkError.unexpected("眼镜拒绝删除该素材") = error else {
                return XCTFail("Expected the scoped deletion failure, got \(error)")
            }
        }
        let sent = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(sent.channel, capturesChannel)
        XCTAssertEqual(sent.service, Session.svcCaptures)
        XCTAssertEqual(sent.type, Int(Session.capDelete))
        XCTAssertEqual(sent.payload, first)

        let second = Data("next-capture".utf8)
        try peer.write(DataX.message(mirror, tags: [ok], payload: second + Data([0])))
        try session.requestCaptureDeletion(handle: "next-capture", timeout: 1)
        let next = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(next.channel, capturesChannel)
        XCTAssertEqual(next.type, Int(Session.capDelete))
        XCTAssertEqual(next.payload, second)

        // A confirmation of the same type as the one before comes without its type (glasses log 35): a
        // batch of deletions stopped at the second item because of it.
        let third = Data("third-capture".utf8)
        try peer.write(DataX.message(mirror, tags: [], payload: third))
        try session.requestCaptureDeletion(handle: "third-capture", timeout: 1)
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

    func testMediaImportAllowsActiveTransfersBeyondOneIdleWindow() throws {
        let (session, peer) = try encryptedLoopback()
        let id = bytes("00112233445546778999aabbccddeeff")
        let channel: UInt16 = 0x8008
        let data = Data("first-second".utf8)
        try session.requestAsset(handle: "capture-1", assetID: "00112233-4455-4677-8999-aabbccddeeff")
        try peer.write(mediaOffer(channel: channel, id: id, size: UInt64(data.count)))

        let worker = DispatchQueue(label: "test.airship.active-transfer")
        let schedule = DispatchTime.now()
        let dataTag = [DataX.tag(2, Session.airData, last: true)]
        let completeTag = [DataX.tag(2, Session.airComplete, last: true)]
        let completed = expectation(description: "The peer sends chunks and completion")
        worker.asyncAfter(deadline: schedule + .milliseconds(300)) {
            do {
                try peer.write(DataX.message(channel, tags: dataTag, payload: Data(data.prefix(5))))
            } catch { XCTFail("First media chunk failed: \(error)") }
        }
        worker.asyncAfter(deadline: schedule + .milliseconds(650)) {
            do {
                try peer.write(DataX.message(channel, tags: dataTag, payload: Data(data.dropFirst(5))))
            } catch { XCTFail("Second media chunk failed: \(error)") }
        }
        worker.asyncAfter(deadline: schedule + .milliseconds(950)) {
            defer { completed.fulfill() }
            do {
                let result = PB.uint(1, UInt64(data.count)) + PB.uint(2, UInt64(Session.adler32(data)))
                try peer.write(DataX.message(channel, tags: completeTag, payload: result))
            } catch { XCTFail("Media completion failed: \(error)") }
        }

        let transfer = try? session.receiveFile(timeout: 0.8, maximumDuration: 3)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(transfer?.data, data)
    }

    func testMediaWiFiQueuesEachCaptureOnceAndRequestsDeliveredAssets() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let a = try XCTUnwrap(UUID(uuidString: "00112233-4455-4677-8999-aabbccddeeff"))
        let b = try XCTUnwrap(UUID(uuidString: "10112233-4455-4677-8999-aabbccddeeff"))
        let c = try XCTUnwrap(UUID(uuidString: "20112233-4455-4677-8999-aabbccddeeff"))
        try session.queueAssetsForMediaWiFi([
            .init(handle: "first", assetID: a, delivered: false),
            .init(handle: "second", assetID: b, delivered: false),
            .init(handle: "first", assetID: c, delivered: true),
        ])

        let files = try (0..<3).map { _ in try DataX.parse(peer.nextFrame(timeout: 1)) }
        XCTAssertEqual(files.map(\.type), [Int(Session.capRequestAsset), Int(Session.capSetLink), Int(Session.capSetLink)])
        XCTAssertEqual(files.map(\.payload), [Data("first:\(c.uuidString.lowercased())".utf8),
                                              Data("first:7".utf8), Data("second:7".utf8)])
    }

    func testDiskMediaBatchReceivesInterleavedSelectedAssetsOnSeparateChannels() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let a = try XCTUnwrap(UUID(uuidString: "00112233-4455-4677-8999-aabbccddeeff"))
        let b = try XCTUnwrap(UUID(uuidString: "10112233-4455-4677-8999-aabbccddeeff"))
        let foreign = bytes("20112233445546778999aabbccddeeff")
        let aID = withUnsafeBytes(of: a.uuid) { Data($0) }
        let bID = withUnsafeBytes(of: b.uuid) { Data($0) }
        let aBytes = Data("first capture".utf8)
        let bBytes = Data("second capture".utf8)
        let aChannel: UInt16 = 0x8010
        let bChannel: UInt16 = 0x8011
        try peer.write(mediaOffer(channel: bChannel, id: bID, size: UInt64(bBytes.count)))
        try peer.write(mediaOffer(channel: 0x8012, id: foreign, size: 1))
        try peer.write(mediaOffer(channel: aChannel, id: aID, size: UInt64(aBytes.count)))
        let dataTag = [DataX.tag(2, Session.airData, last: true)]
        try peer.write(DataX.message(bChannel, tags: dataTag, payload: Data(bBytes.prefix(3))))
        try peer.write(DataX.message(aChannel, tags: dataTag, payload: aBytes))
        try peer.write(DataX.message(bChannel, tags: [], payload: Data(bBytes.dropFirst(3))))
        let completeTag = [DataX.tag(2, Session.airComplete, last: true)]
        for (channel, data) in [(aChannel, aBytes), (bChannel, bBytes)] {
            let completion = PB.uint(1, UInt64(data.count)) + PB.uint(2, UInt64(Session.adler32(data)))
            try peer.write(DataX.message(channel, tags: completeTag, payload: completion))
        }

        var completed: [UUID] = []
        let batch = try session.receiveMediaFilesToDisk(expectedAssetIDs: [a, b], timeout: 1,
            onFileCompleted: { completed.append($0.assetID) })
        XCTAssertNil(batch.error)
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(completed, [a, b])
        let aFile = try XCTUnwrap(batch.files[a])
        let bFile = try XCTUnwrap(batch.files[b])
        XCTAssertEqual(try Data(contentsOf: aFile.url), aBytes)
        XCTAssertEqual(try Data(contentsOf: bFile.url), bBytes)
        let replies = try (0..<5).map { _ in try DataX.parse(peer.nextFrame(timeout: 1)) }
        XCTAssertEqual(replies.map(\.channel), [0x0011, 0x0012, 0x0010, 0x0010, 0x0011])
        XCTAssertEqual(replies.map(\.type), [Int(Session.airCursor), Int(Session.airDrop), Int(Session.airCursor),
                                            Int(Session.airDrop), Int(Session.airDrop)])
        aFile.discard()
        bFile.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: aFile.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bFile.url.path))
    }

    func testDiskMediaCancellationReturnsVerifiedPartialBatchAndLeavesLinkOpen() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let a = try XCTUnwrap(UUID(uuidString: "00112233-4455-4677-8999-aabbccddeeff"))
        let b = try XCTUnwrap(UUID(uuidString: "10112233-4455-4677-8999-aabbccddeeff"))
        let aID = withUnsafeBytes(of: a.uuid) { Data($0) }
        let bID = withUnsafeBytes(of: b.uuid) { Data($0) }
        let content = Data("first capture".utf8)
        try peer.write(mediaOffer(channel: 0x8010, id: aID, size: UInt64(content.count)))
        try peer.write(DataX.message(0x8010, tags: [DataX.tag(2, Session.airData, last: true)], payload: content))
        let completion = PB.uint(1, UInt64(content.count)) + PB.uint(2, UInt64(Session.adler32(content)))
        try peer.write(DataX.message(0x8010, tags: [DataX.tag(2, Session.airComplete, last: true)], payload: completion))
        try peer.write(mediaOffer(channel: 0x8011, id: bID, size: 1))

        var secondOfferAcceptedAt: TimeInterval?
        let batch = try session.receiveMediaFilesToDisk(expectedAssetIDs: [a, b], timeout: 10,
            onBytes: { id, _, _ in
                if id == b { secondOfferAcceptedAt = ProcessInfo.processInfo.systemUptime }
            }, isCancelled: {
                secondOfferAcceptedAt.map { ProcessInfo.processInfo.systemUptime - $0 >= 0.05 } ?? false
            })
        XCTAssertTrue(batch.error is CancellationError)
        XCTAssertTrue(batch.failures.isEmpty)
        let file = try XCTUnwrap(batch.files[a])
        XCTAssertEqual(try Data(contentsOf: file.url), content)
        XCTAssertNil(batch.files[b])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - (try XCTUnwrap(secondOfferAcceptedAt)), 1.5)
        let replies = try (0..<4).map { _ in try DataX.parse(peer.nextFrame(timeout: 1)) }
        XCTAssertEqual(replies.last?.channel, 0x0011)
        XCTAssertEqual(replies.last?.type, Int(Session.airDrop))
        try session.sendStatus(3, AirShield.stSuccess)
        XCTAssertEqual(try DataX.parse(peer.nextFrame(timeout: 1)).error, Int(AirShield.stSuccess))
    }

    func testDiskMediaRejectsUnverifiedSession() throws {
        let (session, _) = try encryptedLoopback()
        XCTAssertThrowsError(try session.receiveMediaFilesToDisk(expectedAssetIDs: [UUID()], timeout: 0.1))
    }

    func testDiskMediaKeepsVerifiedAssetWhenAnotherFailsChecksum() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let a = try XCTUnwrap(UUID(uuidString: "00112233-4455-4677-8999-aabbccddeeff"))
        let b = try XCTUnwrap(UUID(uuidString: "10112233-4455-4677-8999-aabbccddeeff"))
        let channel: UInt16 = 0x8010
        let content = Data("sample".utf8)
        let data = [DataX.tag(2, Session.airData, last: true)]
        let complete = [DataX.tag(2, Session.airComplete, last: true)]
        try peer.write(mediaOffer(channel: channel, id: withUnsafeBytes(of: a.uuid) { Data($0) },
                                  size: UInt64(content.count)))
        try peer.write(DataX.message(channel, tags: data, payload: content))
        let size = PB.uint(1, UInt64(content.count))
        let differentChecksum = Session.adler32(Data("differ".utf8))
        try peer.write(DataX.message(channel, tags: complete, payload: size + PB.uint(2, UInt64(differentChecksum))))
        let next = try DataX.parse(mediaOffer(channel: channel, id: withUnsafeBytes(of: b.uuid) { Data($0) },
                                               size: UInt64(content.count)))
        // Service 20 is already named on the channel. The next offer only changes the message type.
        try peer.write(DataX.message(channel, tags: [DataX.tag(2, Session.airOffer, last: true)], payload: next.payload))
        try peer.write(DataX.message(channel, tags: data, payload: content))
        try peer.write(DataX.message(channel, tags: complete,
                                     payload: size + PB.uint(2, UInt64(Session.adler32(content)))))

        let batch = try session.receiveMediaFilesToDisk(expectedAssetIDs: [a, b], timeout: 1)
        XCTAssertNil(batch.error)
        XCTAssertNotNil(batch.failures[a])
        XCTAssertNil(batch.files[a])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(batch.files[b]).url), content)
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

    func testDeviceStatusRequiresAReportOnTheSubscriptionMirror() throws {
        let (session, peer) = try encryptedLoopback()
        let mirror = Session.chLocalFirst ^ 0x8000
        let ack = DataX.tag(2, UInt16(Status.mtInitAck), last: true)
        let snapshot = PB.bytes(1, PB.uint(3, 74)) + PB.bytes(21, PB.uint(1, 19_000) + PB.uint(2, 21_000))
            + PB.bytes(25, PB.uint(2, 1) + PB.uint(3, 35))
        let report = DataX.tag(2, UInt16(Status.mtDeviceStateStart), last: true)
        try peer.write(DataX.message(mirror, tags: [ack]))
        let unrelated = [DataX.tag(1, UInt16(Status.service), last: false), report]
        try peer.write(DataX.message(mirror + 1, tags: unrelated, payload: snapshot))

        XCTAssertThrowsError(try session.subscribeStatus(timeout: 0.1)) { error in
            guard case LinkError.unexpected("眼镜没有返回设备状态") = error else {
                return XCTFail("Expected a missing report, got \(error)")
            }
        }
        let request = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(request.channel, Session.chLocalFirst)
        XCTAssertEqual(request.service, Status.service)
        XCTAssertEqual(request.type, Int(Status.mtInit))

        try peer.write(DataX.message(mirror, tags: [report], payload: snapshot))
        let state = try session.subscribeStatus(timeout: 1)
        XCTAssertEqual(state.batteryPercent, 74)
        XCTAssertEqual(state.storageFreeMb, 19_000)
        XCTAssertEqual(state.storageTotalMb, 21_000)
        XCTAssertEqual(state.volumePercent, 35)
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

    func testGlassesAudioStateNamesTheGlassesAndIgnoresOtherHeadsets() {
        let glasses = [AudioPortInfo(type: .bluetoothA2DP, name: "RB Meta 046N")]
        XCTAssertEqual(GlassesAudioState.from(outputs: glasses, inputs: [], glassesNames: []),
                       .glasses(profile: "蓝牙立体声 · A2DP"))
        XCTAssertEqual(GlassesAudioState.from(outputs: [AudioPortInfo(type: .bluetoothA2DP, name: "AirPods")],
                                              inputs: [], glassesNames: []), .otherBluetooth(name: "AirPods"))
        XCTAssertEqual(GlassesAudioState.from(outputs: [AudioPortInfo(type: .builtInSpeaker, name: "Speaker")],
                                              inputs: [AudioPortInfo(type: .bluetoothHFP, name: "My Specs")],
                                              glassesNames: ["My Specs"]), .glasses(profile: "眼镜麦克风可用"))
        XCTAssertEqual(GlassesAudioState.from(outputs: [AudioPortInfo(type: .builtInSpeaker, name: "Speaker")],
                                              inputs: [], glassesNames: []), .unavailable)
    }

    func testMetaAdvertisementReadsProductAndSkipsWristbands() {
        XCTAssertEqual(MetaAdvertisement.product(Data([0xAB, 0x01, 0x02, 0x01, 0x01])), 258)
        XCTAssertEqual(MetaAdvertisement.product(Data([0xAB, 0x01, 0x80, 0x06, 0x01, 0x00, 0x01])), 262)
        XCTAssertTrue(MetaAdvertisement.isGlassesCandidate(manufacturerData: Data([0xAB, 0x01, 0x80, 0x06, 0x01, 0x00, 0x01]),
                                                           hasMetaService: false))
        XCTAssertFalse(MetaAdvertisement.isGlassesCandidate(manufacturerData: Data([0xAB, 0x01, 0x80, 0x01, 0x06, 0x00, 0x00]),
                                                            hasMetaService: true))
        XCTAssertNil(MetaAdvertisement.product(Data([0x4C, 0x00, 0x10, 0x05, 0x01])))
        XCTAssertFalse(MetaAdvertisement.isGlassesCandidate(manufacturerData: Data([0x4C, 0x00, 0x10]), hasMetaService: false))
        XCTAssertTrue(MetaAdvertisement.isGlassesCandidate(manufacturerData: nil, hasMetaService: true))
    }

    /// 1.00 log 13:43:22: an offer that came before the capture channel was opened went unanswered and
    /// every later Bluetooth file waited behind it. A trusted link answers it whoever is reading.
    func testUnrequestedOfferIsAnsweredBeforeTheCaptureChannelOpens() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let id = Data(repeating: 7, count: 16)
        try peer.write(mediaOffer(channel: 0x8179, id: id, size: 10))
        try peer.write(DataX.message(0x8003, tags: [DataX.tag(2, 2005, last: true)], payload: Data([1])))
        XCTAssertEqual(try session.nextMessage(timeout: 1).channel, 0x8003)
        let reply = try DataX.parse(peer.nextFrame(timeout: 1))
        XCTAssertEqual(reply.channel, 0x0179)
        XCTAssertEqual(reply.type, Int(Session.airDrop))
        XCTAssertEqual(try PB.parse(reply.payload)[1]?.first as? Data, id)
    }

    func testOfferOnAnUnverifiedLinkIsLeftToTheCaller() throws {
        let (session, peer) = try encryptedLoopback()
        try peer.write(mediaOffer(channel: 0x8179, id: Data(repeating: 7, count: 16), size: 10))
        let message = try session.nextMessage(timeout: 1)
        XCTAssertEqual(message.channel, 0x8179)
        XCTAssertEqual(message.type, Int(Session.airOffer))
    }

    func testAssistantChannelsWaitForTheAssistantReader() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let tags = [DataX.tag(2, 1001, last: true)]
        session.routeToAssistant([0x0005, 0x8005])
        try peer.write(DataX.message(0x8005, tags: tags, payload: Data([1])))
        try peer.write(DataX.message(0x8003, tags: tags, payload: Data([2])))
        let other = try session.nextMessage(timeout: 1)
        XCTAssertEqual(other.channel, 0x8003)
        let parked = try session.nextMessage(timeout: 1, forAssistant: true)
        XCTAssertEqual(parked.channel, 0x8005)
        XCTAssertEqual(parked.payload, Data([1]))

        session.routeToAssistant([])
        try peer.write(DataX.message(0x8005, tags: tags, payload: Data([3])))
        XCTAssertEqual(try session.nextMessage(timeout: 1).channel, 0x8005)
    }

    func testOnlyAnIdleBluetoothTransferEarnsAFreshSession() {
        XCTAssertTrue(Glasses.isSilentTransfer(LinkError.unexpected("眼镜文件传输暂停过久，请重试。")))
        XCTAssertFalse(Glasses.isSilentTransfer(LinkError.unexpected("眼镜上已找不到这项素材。")))
        XCTAssertFalse(Glasses.isSilentTransfer(CancellationError()))
    }

    func testSpokenAnswerFollowsTheQuestionLanguage() {
        let prompt = Glasses.spokenAnswerPrompt("what is your name")
        XCTAssertTrue(prompt.hasPrefix("Answer in the same language as the question"))
        XCTAssertTrue(prompt.hasSuffix("Question: what is your name"))
        XCTAssertFalse(prompt.contains("请用"))
    }

    /// glasses log 31: the handshake key was new on every connection, so the Wi-Fi session compared
    /// against it could never pass. The identity in the glasses' EnableTrust is what stays the same.
    func testWiFiChecksTheGlassesTrustIdentityNotTheHandshakeKey() throws {
        let identity = OwnerMaterial(scalar: Data(repeating: 7, count: 32))
        let digest = Data(SHA256.hash(data: identity.publicKeyXy))
        let (first, _) = try encryptedLoopback(trust: true, peerKey: 2, identityKey: 7)
        let (second, _) = try encryptedLoopback(trust: true, peerKey: 3, identityKey: 7)
        XCTAssertEqual(first.verifiedPeerIdentity, digest)
        XCTAssertEqual(second.verifiedPeerIdentity, digest)

        let samePair = HandshakeOutcome()
        let (wifi, _) = try encryptedLoopback(trust: true, peerKey: 4, identityKey: 7,
                                              expectedIdentity: digest, outcome: samePair)
        XCTAssertNil(samePair.error)
        XCTAssertEqual(wifi.verifiedPeerIdentity, digest)

        let otherPair = HandshakeOutcome()
        let (stranger, _) = try encryptedLoopback(trust: true, peerKey: 5, identityKey: 8,
                                                  expectedIdentity: digest, outcome: otherPair)
        XCTAssertEqual(String(describing: try XCTUnwrap(otherPair.error)),
                       "unexpected: Wi-Fi 会话的眼镜身份与蓝牙会话不一致。")
        XCTAssertFalse(stranger.hasVerifiedOwner)
        XCTAssertNil(stranger.verifiedPeerIdentity)
    }

    func testDeviceInfoNamesTheScopedSettingsStores() throws {
        let uuid = "0F1E2D3C-4B5A-4967-8896-A5B4C3D2E1F0"
        let payload = PB.string(1, "Meta/greathammerhead/greathammerhead:14/1/2:user/release-keys")
            + PB.string(2, "1WMZ") + PB.string(4, uuid) + PB.string(8, "RB Meta")
        let info = try XCTUnwrap(Session.parsePeerDeviceInfo(payload))
        XCTAssertEqual(info.deviceUUID, uuid)
        XCTAssertEqual(info.serial, "1WMZ")
        XCTAssertEqual(info.model, "RB Meta")
        XCTAssertNil(Session.parsePeerDeviceInfo(PB.string(2, "1WMZ") + PB.string(4, "not-a-uuid"))?.deviceUUID)
        XCTAssertNil(Session.parsePeerDeviceInfo(Data()))

        XCTAssertEqual(Drive.settingsNamespaces(deviceUUID: uuid), [
            "\(uuid)@individual_device_settings", "\(uuid)@individual_device_sensitive_settings",
            "local_device_settings", "shared_settings_namespace_1",
        ])
        XCTAssertEqual(Drive.settingsNamespaces(deviceUUID: nil),
                       ["individual_device_settings", "local_device_settings", "shared_settings_namespace_1"])
        XCTAssertEqual(Drive.settingsNamespace("individual_device_settings", deviceUUID: uuid),
                       "\(uuid)@individual_device_settings")
        XCTAssertEqual(Drive.settingsNamespace("shared_settings_namespace_1", deviceUUID: uuid),
                       "shared_settings_namespace_1")
        XCTAssertEqual(Drive.settingsNamespace("individual_device_settings", deviceUUID: nil),
                       "individual_device_settings")
        XCTAssertEqual(Glasses.storeLabel("\(uuid)@individual_device_settings"), "individual_device_settings")
    }

    func testDeviceInfoIsAskedOnSvc100AndReadFromItsMirror() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let uuid = "0F1E2D3C-4B5A-4967-8896-A5B4C3D2E1F0"
        let result = ResultBox<Session.PeerDeviceInfo>()
        let answered = expectation(description: "svc100 answered")
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? session.requestPeerDeviceInfo(timeout: 3)
            answered.fulfill()
        }
        let ask = try DataX.parse(peer.nextFrame(timeout: 2))
        XCTAssertEqual(ask.service, Session.svcPeerBuildInfo)
        XCTAssertEqual(ask.type, Int(Session.mtPeerGetInfo))
        XCTAssertTrue(ask.payload.isEmpty)
        try peer.write(DataX.message(ask.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Session.mtPeerDeviceInfo), last: true)],
                                     payload: PB.string(2, "1WMZ") + PB.string(4, uuid)))
        wait(for: [answered], timeout: 4)
        XCTAssertEqual(result.value?.deviceUUID, uuid)
        // Asked once per session: the second call answers from memory without another frame.
        XCTAssertEqual(try session.requestPeerDeviceInfo(timeout: 0.2)?.deviceUUID, uuid)
        XCTAssertThrowsError(try peer.nextFrame(timeout: 0.2))
    }

    private func nextPhoneMessage(_ peer: EncryptedPeer, type: Int, timeout: TimeInterval = 4) throws -> DataX.Message {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try DataX.parse(peer.nextFrame(timeout: max(0.05, deadline.timeIntervalSinceNow)))
            if message.type == type { return message }
        }
    }

    /// glasses log 31, 15:57:02: Hey Meta during a Bluetooth import. The import held the link and the
    /// assistant only parked, so the glasses resent their envelope every second and the question died.
    func testPausedAssistantStillAnswersWhatTheOtherReaderParks() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let assistant = Assistant(session: session)
        let registered = expectation(description: "assistant registered")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try assistant.register(timeout: 4) } catch { XCTFail("registration failed: \(error)") }
            registered.fulfill()
        }
        let messages = try nextPhoneMessage(peer, type: Int(Assistant.MT.initMessageRequest))
        try peer.write(DataX.message(messages.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initMessageResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        let stream = try nextPhoneMessage(peer, type: Int(Assistant.MT.initStreamRequest))
        try peer.write(DataX.message(stream.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initStreamResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        wait(for: [registered], timeout: 6)
        XCTAssertTrue(assistant.registered)

        assistant.startLoop()
        defer { assistant.stop() }
        XCTAssertTrue(assistant.pauseReading(timeout: 3))
        try peer.write(DataX.message(messages.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.envelope), last: true)],
                                     payload: PB.uint(1, 42)))
        try peer.write(DataX.message(0x8040, tags: [DataX.tag(2, 1, last: true)], payload: Data([9])))
        // The import's own read: it gets its message and parks the assistant's on the way.
        XCTAssertEqual(try session.nextMessage(timeout: 2).channel, 0x8040)
        let ack = try nextPhoneMessage(peer, type: Int(Assistant.MT.envelopeAck), timeout: 3)
        XCTAssertEqual(ack.channel, messages.channel)
        XCTAssertEqual(try PB.parse(ack.payload)[1]?.first as? Int, 42)
        assistant.resumeReading()
    }

    func testParkedAssistantMessagesWaitUntilSomeoneReadsTheLink() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        session.routeToAssistant([0x0005, 0x8005], quiet: [0x0006, 0x8006])
        try peer.write(DataX.message(0x8005, tags: [DataX.tag(2, 1010, last: true)], payload: Data([1])))
        try peer.write(DataX.message(0x8003, tags: [DataX.tag(2, 1001, last: true)], payload: Data([2])))
        XCTAssertNil(session.takeParkedAssistantMessage())
        XCTAssertEqual(try session.nextMessage(timeout: 1).channel, 0x8003)
        XCTAssertEqual(session.takeParkedAssistantMessage()?.payload, Data([1]))
        XCTAssertNil(session.takeParkedAssistantMessage())
    }

    func testSettingsReadBackComparesValuesNotSpellings() {
        XCTAssertTrue(SettingsSchemaTable.same(kind: "bool", "1", "true"))
        XCTAssertTrue(SettingsSchemaTable.same(kind: "bool", "false", "0"))
        XCTAssertTrue(SettingsSchemaTable.same(kind: "int", "90", "90.0"))
        XCTAssertFalse(SettingsSchemaTable.same(kind: "int", "90", "91"))
        XCTAssertFalse(SettingsSchemaTable.same(kind: "bool", nil, "true"))
        XCTAssertTrue(SettingsSchemaTable.same(kind: "str", "what is the weather", "what is the weather"))
    }

    /// The settings page lists only what Ray-Ban Meta (Gen 2) has and the phone can write, all in Chinese.
    func testCuratedSettingsAreRealWritableGen2SettingsInChinese() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalogue = SettingsCatalog.decode(try Data(contentsOf: resources.appendingPathComponent("settings_ui.json")))
        let schema = SettingsSchemaTable.parse(try String(contentsOf: resources.appendingPathComponent("settings.tsv"),
                                                          encoding: .utf8))
        XCTAssertGreaterThan(catalogue.count, 300)
        let items = CuratedSettings.all
        XCTAssertGreaterThan(items.count, 18)
        XCTAssertEqual(Set(items.map(\.key)).count, items.count)
        for item in items {
            let info = try XCTUnwrap(catalogue.first { $0.key == item.key }, item.key)
            let row = try XCTUnwrap(schema[item.key], item.key)
            XCTAssertTrue(info.offeredOnGen2, item.key)
            XCTAssertTrue(row.writable, item.key)
            XCTAssertNotNil(item.title.range(of: "\\p{Han}", options: .regularExpression), item.key)
            XCTAssertNotNil(item.note.range(of: "\\p{Han}", options: .regularExpression), item.key)
            switch item.control {
            case .toggle:
                XCTAssertEqual(info.control.type, "toggle", item.key)
                XCTAssertEqual(row.kind, "bool", item.key)
            case .choice(let options):
                let known = Set((info.control.options ?? []).map(\.value))
                for option in options {
                    // The catalogue's choices, or the firmware's own default (the stock voice is not among
                    // the choices Meta's app offers).
                    XCTAssertTrue(known.contains(option.value) || option.value == row.defaultValue,
                                  "\(item.key)=\(option.value)")
                    XCTAssertFalse(option.label.isEmpty)
                }
            case .percent(let minimum, let maximum):
                XCTAssertEqual(info.control.min, minimum, item.key)
                XCTAssertEqual(info.control.max, maximum, item.key)
            }
        }
        XCTAssertEqual(CuratedSettings.percent(55, 55, 127), 0)
        XCTAssertEqual(CuratedSettings.percent(127, 55, 127), 100)
        XCTAssertFalse(catalogue.first { $0.key == "captouch_enabled" }?.offeredOnGen2 ?? true)
    }

    func testAlbumNamesSayWhatAndWhen() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let ns = 1_764_172_622_000_000_000   // 2025-11-26 15:57:02 UTC
        XCTAssertEqual(MediaNaming.fileName(isPhoto: true, timestampNS: ns, fileExtension: "HEIC", timeZone: utc),
                       "眼镜照片_2025-11-26_15-57-02.heic")
        XCTAssertEqual(MediaNaming.fileName(isPhoto: false, timestampNS: ns, fileExtension: ".mp4", timeZone: utc),
                       "眼镜视频_2025-11-26_15-57-02.mp4")
        XCTAssertTrue(MediaNaming.title(isPhoto: true, timestampNS: ns, timeZone: utc).hasPrefix("照片 · "))
        XCTAssertTrue(MediaNaming.title(isPhoto: false, timestampNS: ns, timeZone: utc).hasSuffix("15:57:02"))
        XCTAssertEqual(MediaNaming.title(isPhoto: false, timestampNS: nil), "视频")
        XCTAssertNil(MediaNaming.captureDate(0))
    }

    func testPhotoLevelingOnlyFixesAModestTilt() {
        XCTAssertFalse(PhotoLeveling.shouldLevel(degrees: 0.3))
        XCTAssertTrue(PhotoLeveling.shouldLevel(degrees: -4))
        XCTAssertTrue(PhotoLeveling.shouldLevel(degrees: 9.5))
        XCTAssertFalse(PhotoLeveling.shouldLevel(degrees: 30))
    }

    /// The row where the bright sky ends in column `x` of a rendered picture (row 0 is one edge; only
    /// differences between columns matter).
    private func skyEdge(_ image: CIImage, x: Int) throws -> Int {
        let frame = image.extent
        let width = Int(frame.width), height = Int(frame.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: frame, format: .RGBA8, colorSpace: space)
        let sky = (0 ..< height).map { pixels[($0 * width + x) * 4 + 2] > 128 }
        // The picture is half sky, half ground: the edge is where the column changes.
        return try XCTUnwrap((1 ..< height).first { sky[$0] != sky[$0 - 1] })
    }

    /// Vision's sign convention decides whether a photo is straightened or tilted twice as far; the first
    /// CI run showed the angle comes back as the correction, not the tilt. Vision does not find a horizon
    /// again in the turned pictures, so the proof is in the pixels: after straightening by the detected
    /// angle the sky ends at the same height left and right, and turned the other way the slope doubles.
    func testStraighteningByTheDetectedAngleLevelsTheHorizon() throws {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.75, blue: 0.95)).cropped(to: frame)
        let tilt = 6.0 * Double.pi / 180
        let ground = CIImage(color: CIColor(red: 0.25, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: -3000, y: -3000, width: 6000, height: 3000))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(tilt)))
            .transformed(by: CGAffineTransform(translationX: frame.midX, y: frame.midY))
        let scene = ground.composited(over: sky).cropped(to: frame)
        let slope = { (image: CIImage) in abs(try self.skyEdge(image, x: 1000) - self.skyEdge(image, x: 200)) }
        XCTAssertEqual(Double(try slope(scene)), 800 * tan(tilt), accuracy: 6)   // 84 rows over 800 columns

        // The geometry on its own: turning by minus the tilt levels it, and the frame stays covered.
        let byHand = PhotoLeveling.straightened(scene, by: -tilt)
        XCTAssertEqual(byHand.extent, frame)
        XCTAssertLessThanOrEqual(try slope(byHand), 3)
        XCTAssertEqual(PhotoLeveling.zoom(width: 1512, height: 2016, angle: 3 * Double.pi / 180), 1.068, accuracy: 0.002)
        XCTAssertEqual(PhotoLeveling.zoom(width: 1512, height: 2016, angle: 0), 1, accuracy: 1e-9)

        guard let horizon = PhotoLeveling.detectedHorizon(of: scene) else {
            throw XCTSkip("Vision found no horizon in the synthetic scene here")
        }
        let correction = horizon.angle
        XCTAssertEqual(correction * 180 / Double.pi, -6, accuracy: 2.5)
        if horizon.confidence >= PhotoLeveling.minimumConfidence {
            XCTAssertEqual(PhotoLeveling.levelingAngle(of: scene), correction)
        } else {
            XCTAssertNil(PhotoLeveling.levelingAngle(of: scene))
        }
        XCTAssertLessThanOrEqual(try slope(PhotoLeveling.straightened(scene, by: correction)), 40)
        XCTAssertGreaterThan(try slope(PhotoLeveling.straightened(scene, by: -correction)), 130)
    }

    /// The ack of a svc31 write comes back on the mirror channel. Waiting on the phone's own channel
    /// number never matched, and on an idle link the wait threw, so every settings write looked failed.
    func testSettingsWriteTakesItsAckFromTheMirrorChannel() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let schema = SettingSchema(key: "wakeword_sound_enabled", field: 37, kind: "bool", defaultValue: "true",
                                   namespace: "individual_device_settings", parsed: true)
        let result = ResultBox<Bool>()
        let done = expectation(description: "write returned")
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? session.writeSettingsField(schema, value: "false", timeout: 8)
            done.fulfill()
        }
        let write = try DataX.parse(peer.nextFrame(timeout: 5))
        XCTAssertEqual(write.service, Session.svcSettings)
        XCTAssertEqual(write.type, Int(Session.mtSyncData))
        XCTAssertEqual(write.payload, PB.uint(37, 0))
        try peer.write(DataX.message(write.channel ^ 0x8000, tags: [DataX.tag(2, Session.mtAck, last: true)]))
        wait(for: [done], timeout: 9)
        XCTAssertEqual(result.value, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 7, "returned on the ack, not on the timeout")

        // Without any ack the write still counts as sent; the caller's read-back decides.
        XCTAssertEqual(try session.writeSettingsField(schema, value: "true", timeout: 0.3), true)
    }

    func testSettingValuesAreCheckedAgainstTheirKind() {
        let toggle = SettingSchema(key: "wakeword_sound_enabled", field: 37, kind: "bool", defaultValue: "true",
                                   namespace: "individual_device_settings", parsed: true)
        XCTAssertTrue(toggle.accepts("1"))
        XCTAssertTrue(toggle.accepts("false"))
        XCTAssertFalse(toggle.accepts("maybe"))
        let number = SettingSchema(key: "video_fps", field: 1, kind: "int", defaultValue: "30",
                                   namespace: "individual_device_settings", parsed: true)
        XCTAssertTrue(number.accepts(" 30 "))
        XCTAssertFalse(number.accepts("30fps"))
        let ratio = SettingSchema(key: "audio_balance", field: 225, kind: "float", defaultValue: "0.0",
                                  namespace: "individual_device_settings", parsed: true)
        XCTAssertTrue(ratio.accepts("-0.4"))
        XCTAssertFalse(ratio.accepts("nan"))
        XCTAssertFalse(SettingSchema(key: "x", field: nil, kind: "other", defaultValue: nil,
                                     namespace: "individual_device_settings", parsed: false).accepts("1"))
    }

    // MARK: resuming an interrupted transfer

    private func resumableAsset() throws -> (asset: UUID, id: Data, content: Data) {
        let asset = try XCTUnwrap(UUID(uuidString: "20112233-4455-4677-8999-aabbccddeeff"))
        let content = Data((0 ..< 5000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        return (asset, withUnsafeBytes(of: asset.uuid) { Data($0) }, content)
    }

    /// A first session that gets `count` bytes of the file and then stops, as a dropped link would.
    private func interruptTransfer(of file: (asset: UUID, id: Data, content: Data), after count: Int) throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        try peer.write(mediaOffer(channel: 0x8010, id: file.id, size: UInt64(file.content.count)))
        try peer.write(DataX.message(0x8010, tags: [DataX.tag(2, Session.airData, last: true)],
                                     payload: Data(file.content.prefix(count))))
        var got = 0
        let broken = try session.receiveMediaFilesToDisk(expectedAssetIDs: [file.asset], timeout: 5,
            onBytes: { _, received, _ in got = received }, isCancelled: { got >= count })
        XCTAssertTrue(broken.error is CancellationError)
        XCTAssertNil(broken.files[file.asset])
    }

    /// glasses log 33: a 26 MB video dropped at 16 MB and again at 25 MB, restarting from zero each time.
    /// What arrived now stays on the phone, and the next offer is answered with a cursor at its end.
    func testInterruptedFileContinuesFromWhatArrived() throws {
        let file = try resumableAsset()
        try interruptTransfer(of: file, after: 2000)

        let (session, peer) = try encryptedLoopback(trust: true)
        try peer.write(mediaOffer(channel: 0x8020, id: file.id, size: UInt64(file.content.count)))
        let result = ResultBox<Session.StagedMediaBatch>()
        let firstProgress = ResultBox<Int>()
        let finished = expectation(description: "second session finished")
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? session.receiveMediaFilesToDisk(expectedAssetIDs: [file.asset], timeout: 8,
                onBytes: { _, received, _ in if firstProgress.value == nil { firstProgress.value = received } })
            finished.fulfill()
        }
        let cursor = try DataX.parse(peer.nextFrame(timeout: 5))
        XCTAssertEqual(cursor.channel, 0x0020)
        XCTAssertEqual(cursor.type, Int(Session.airCursor))
        let fields = try PB.parse(cursor.payload)
        XCTAssertEqual(fields[1]?.first as? Int, 2000)
        XCTAssertEqual(fields[2]?.first as? Int, Int(Session.adler32(Data(file.content.prefix(2000)))))

        // The sender goes on from the cursor, checks once, and completes.
        try peer.write(DataX.message(0x8020, tags: [DataX.tag(2, Session.airData, last: true)],
                                     payload: Data(file.content.dropFirst(2000))))
        let whole = PB.uint(1, UInt64(file.content.count)) + PB.uint(2, UInt64(Session.adler32(file.content)))
        try peer.write(DataX.message(0x8020, tags: [DataX.tag(2, Session.airCheck, last: true)], payload: whole))
        try peer.write(DataX.message(0x8020, tags: [DataX.tag(2, Session.airComplete, last: true)], payload: whole))
        wait(for: [finished], timeout: 10)
        let batch = try XCTUnwrap(result.value)
        XCTAssertNil(batch.error)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(batch.files[file.asset]).url), file.content)
        XCTAssertEqual(firstProgress.value, 2000)
        XCTAssertTrue(Session.resumeAllowed)
    }

    /// Glasses that do not honour the cursor send the file from its start again. The first check shows
    /// the two sides out of step: the file starts over, and later transfers no longer try to resume.
    func testASenderThatIgnoresTheResumeCursorStartsTheFileOver() throws {
        let file = try resumableAsset()
        try interruptTransfer(of: file, after: 2000)

        let (session, peer) = try encryptedLoopback(trust: true)
        try peer.write(mediaOffer(channel: 0x8020, id: file.id, size: UInt64(file.content.count)))
        let result = ResultBox<Session.StagedMediaBatch>()
        let finished = expectation(description: "second session finished")
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? session.receiveMediaFilesToDisk(expectedAssetIDs: [file.asset], timeout: 8)
            finished.fulfill()
        }
        XCTAssertEqual(try PB.parse(DataX.parse(peer.nextFrame(timeout: 5)).payload)[1]?.first as? Int, 2000)

        // From zero, as if no cursor had been sent: 1500 bytes, then the check that gives it away.
        let dataTag = [DataX.tag(2, Session.airData, last: true)]
        let head = Data(file.content.prefix(1500))
        try peer.write(DataX.message(0x8020, tags: dataTag, payload: head))
        try peer.write(DataX.message(0x8020, tags: [DataX.tag(2, Session.airCheck, last: true)],
                                     payload: PB.uint(1, 1500) + PB.uint(2, UInt64(Session.adler32(head)))))
        let rewind = try DataX.parse(peer.nextFrame(timeout: 5))
        XCTAssertEqual(rewind.type, Int(Session.airCursor))
        let asked = try PB.parse(rewind.payload)
        XCTAssertNil(asked[1])                                   // offset 0
        XCTAssertEqual(asked[2]?.first as? Int, 1)               // the checksum of nothing

        // Sealed frames carry at most 4 KB of plaintext.
        try peer.write(DataX.message(0x8020, tags: dataTag, payload: Data(file.content.prefix(2500))))
        try peer.write(DataX.message(0x8020, tags: dataTag, payload: Data(file.content.dropFirst(2500))))
        let whole = PB.uint(1, UInt64(file.content.count)) + PB.uint(2, UInt64(Session.adler32(file.content)))
        try peer.write(DataX.message(0x8020, tags: [DataX.tag(2, Session.airComplete, last: true)], payload: whole))
        wait(for: [finished], timeout: 10)
        let batch = try XCTUnwrap(result.value)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(batch.files[file.asset]).url), file.content)
        XCTAssertFalse(Session.resumeAllowed)
        Session.resetResumeState()
    }

    func testSenderChecksAreReadAsOffsetAndChecksum() {
        let cursor = Session.airshipCursor(PB.uint(1, 65_536) + PB.uint(2, 7))
        XCTAssertEqual(cursor?.offset, 65_536)
        XCTAssertEqual(cursor?.checksum, 7)
        XCTAssertEqual(Session.airshipCursor(PB.uint(2, 1))?.offset, 0)
        XCTAssertNil(Session.airshipCursor(Data()))
        XCTAssertTrue(Glasses.isLinkLoss(LinkError.io("stream closed")))
        XCTAssertTrue(Glasses.isLinkLoss(LinkError.unexpected("眼镜文件传输暂停过久，请重试。")))
        XCTAssertFalse(Glasses.isLinkLoss(LinkError.unexpected("眼镜上已找不到这项素材。")))
    }

    // MARK: Hey Meta

    /// The glasses announce a wake with a fulfillment request of its own (intent IN:WAKE_WORD) and send
    /// the words in a second one. Treating the first as "no question" closed the turn and put its id on
    /// the done list, so the real question was dropped without a trace.
    func testTheWakeEventDoesNotCostTheQuestionThatFollows() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let assistant = Assistant(session: session)
        assistant.transcribesOnPhone = { false }
        let heard = expectation(description: "the question reached the app")
        let question = ResultBox<String>()
        assistant.onTranscript = { text, _ in
            question.value = text
            heard.fulfill()
        }
        let registered = expectation(description: "assistant registered")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try assistant.register(timeout: 8) } catch { XCTFail("registration failed: \(error)") }
            registered.fulfill()
        }
        let messages = try nextPhoneMessage(peer, type: Int(Assistant.MT.initMessageRequest), timeout: 8)
        try peer.write(DataX.message(messages.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initMessageResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        let stream = try nextPhoneMessage(peer, type: Int(Assistant.MT.initStreamRequest), timeout: 8)
        try peer.write(DataX.message(stream.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initStreamResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        wait(for: [registered], timeout: 10)
        assistant.startLoop()
        defer { assistant.stop() }

        let mirror = messages.channel ^ 0x8000
        func send(_ type: Int32, _ payload: Data) throws {
            try peer.write(DataX.message(mirror, tags: [DataX.tag(2, UInt16(type), last: true)], payload: payload))
        }
        try send(Assistant.MT.startInteraction, ThriftWriter().string(1, "turn-9").done())
        let wake = ThriftWriter().string(1, "turn-9").string(23, "IN:WAKE_WORD").done()
        try send(Assistant.MT.netEvent, assistant.netEvent(Assistant.EV.fulfillmentRequest, wake))
        let words = ThriftWriter().structField(1, ThriftWriter().string(1, "what is your name").done()).done()
        let request = ThriftWriter().string(1, "turn-9").structField(2, words).done()
        try send(Assistant.MT.netEvent, assistant.netEvent(Assistant.EV.fulfillmentRequest, request))
        wait(for: [heard], timeout: 5)
        XCTAssertEqual(question.value, "what is your name")
    }

    // MARK: video levelling

    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// An IMU log of a head held still at `roll` (positive: tilted to its right), 960 samples a second.
    private func stillIMU(rollDegrees: Double, seconds: Double) -> [IMUSample] {
        let roll = rollDegrees * Double.pi / 180
        return (0 ..< Int(seconds * 960)).map { index in
            IMUSample(timeNs: Int64(index) * 1_041_667, ax: Float(-9.81 * sin(roll)), ay: Float(9.81 * cos(roll)), az: 0,
                      gx: 0, gy: 0, gz: 0)
        }
    }

    func testSensorLogsAreReadAsFixedLittleEndianRecords() throws {
        var imu = Data("SI".utf8) + le(UInt16(1))
        imu += Data([0, 0]) + le(Int64(1_000_000_000))
        for value in [Float(0.5), 9.7, -0.25, 0.01, -0.02, 0.03, 31.5] { imu += le(value.bitPattern) }
        let sample = try XCTUnwrap(MotionLog.readIMU(imu)).first
        XCTAssertEqual(sample, IMUSample(timeNs: 1_000_000_000, ax: 0.5, ay: 9.7, az: -0.25, gx: 0.01, gy: -0.02, gz: 0.03))
        XCTAssertNil(MotionLog.readIMU(imu.dropLast()))
        XCTAssertNil(MotionLog.readIMU(Data("SF".utf8) + imu.dropFirst(2)))

        let frames = Data("SF".utf8) + le(UInt16(1)) + le(UInt16(7)) + le(Int64(2_000_000_000)) + le(Int64(8_000_000))
        let record = try XCTUnwrap(MotionLog.readFrames(frames)).first
        XCTAssertEqual(record, FrameRecord(frame: 7, timeNs: 2_000_000_000, exposureNs: 8_000_000))
        XCTAssertEqual(record?.midExposureNs, 2_004_000_000)
    }

    func testHeadRollComesOutOfTheIMULogWithVisorsSign() throws {
        let imu = stillIMU(rollDegrees: 5, seconds: 2)
        let frames = (0 ..< 45).map { FrameRecord(frame: $0, timeNs: 200_000_000 + Int64($0) * 33_333_333, exposureNs: 8_000_000) }
        let rolls = try XCTUnwrap(VideoLeveling.frameRolls(imu: imu, frames: frames))
        XCTAssertEqual(rolls.count, frames.count)
        for roll in rolls {
            XCTAssertEqual(roll.radians * 180 / Double.pi, 5, accuracy: 0.05)
            XCTAssertEqual(roll.weight, 1, accuracy: 1e-9)
        }
        // Looking straight down there is no roll to speak of.
        XCTAssertLessThan(VideoLeveling.roll(of: SIMD3(0.05, 0.05, 1)).weight, 0.2)
        // Frames outside what the log covers: no answer rather than a guess.
        let late = frames.map { FrameRecord(frame: $0.frame, timeNs: $0.timeNs + 5_000_000_000, exposureNs: 0) }
        XCTAssertNil(VideoLeveling.frameRolls(imu: imu, frames: late))
    }

    func testAHeadTurningDoesNotFoolTheGravityEstimate() {
        // The head rolls from 0 to 10 degrees to the right over one second while a sideways push of
        // 2 m/s^2 (a walking turn) leans the accelerometer the other way.
        var imu: [IMUSample] = []
        for index in 0 ..< 1920 {
            let t = Double(index) / 960
            let roll = min(t, 1) * 10 * Double.pi / 180
            // Rolling right about the forward axis: the IMU's z points at the wearer, so the rate is on -z.
            let rate = t < 1 ? Float(-10 * Double.pi / 180) : 0
            let push = t > 1 ? 2.0 : 0
            imu.append(IMUSample(timeNs: Int64(index) * 1_041_667, ax: Float(-9.81 * sin(roll) + push),
                                 ay: Float(9.81 * cos(roll)), az: 0, gx: 0, gy: 0, gz: rate))
        }
        let sign: Double = VideoLeveling.gyroPredictionError(imu, gyroSign: -1) < VideoLeveling.gyroPredictionError(imu, gyroSign: 1) ? -1 : 1
        let ups = VideoLeveling.upVectors(imu, gyroSign: sign)
        // Right after the turn the gyro has carried "up" to 10 degrees; the push has had no time to drag it.
        XCTAssertEqual(VideoLeveling.roll(of: ups[1000]).radians * 180 / Double.pi, 10, accuracy: 1.0)
        // The accelerometer alone would read 10 degrees minus atan(2 / 9.66), about -1.7.
        XCTAssertGreaterThan(VideoLeveling.roll(of: ups[1400]).radians * 180 / Double.pi, 6)
    }

    func testLevellingPlanFollowsTheIMUAndIsCheckedByThePicture() throws {
        let degree = Double.pi / 180
        let times = (0 ..< 90).map { Double($0) / 30 }
        let tilted = [(radians: Double, weight: Double)](repeating: (5 * degree, 1), count: times.count)

        // IMU alone: a head tilted 5 degrees to the right is corrected by -5 (Vision's sign for the same picture).
        let alone = try XCTUnwrap(VideoLeveling.plan(frameTimes: times, imuRolls: tilted, vision: [], fps: 30, width: 1512, height: 2016))
        XCTAssertEqual(alone.angle(at: 1.5) / degree, -5, accuracy: 0.01)
        XCTAssertEqual(alone.zoom, PhotoLeveling.zoom(width: 1512, height: 2016, angle: 5 * degree), accuracy: 1e-9)

        // The picture agrees: no change.
        let agree = (0 ..< 5).map { (time: Double($0) * 0.6, angle: -5 * degree) }
        let confirmed = try XCTUnwrap(VideoLeveling.plan(frameTimes: times, imuRolls: tilted, vision: agree, fps: 30, width: 1512, height: 2016))
        XCTAssertEqual(confirmed.angle(at: 1.5) / degree, -5, accuracy: 0.05)

        // The picture says the opposite: the IMU's sign was wrong for this clip, and the picture wins.
        let opposite = agree.map { (time: $0.time, angle: 5 * degree) }
        let turned = try XCTUnwrap(VideoLeveling.plan(frameTimes: times, imuRolls: tilted, vision: opposite, fps: 30, width: 1512, height: 2016))
        XCTAssertEqual(turned.angle(at: 1.5) / degree, 5, accuracy: 0.05)

        // The picture is already level (the glasses corrected it): nothing to do.
        let level = agree.map { (time: $0.time, angle: 0.0) }
        XCTAssertNil(VideoLeveling.plan(frameTimes: times, imuRolls: tilted, vision: level, fps: 30, width: 1512, height: 2016))

        // No IMU log: enough frames with a horizon carry the clip; too few do not.
        let pictureOnly = try XCTUnwrap(VideoLeveling.plan(frameTimes: times, imuRolls: nil, vision: agree, fps: 30, width: 1512, height: 2016))
        XCTAssertEqual(pictureOnly.angle(at: 1.5) / degree, -5, accuracy: 0.1)
        XCTAssertNil(VideoLeveling.plan(frameTimes: times, imuRolls: nil, vision: Array(agree.prefix(2)), fps: 30, width: 1512, height: 2016))
    }

    func testLevellingCorrectionIsCappedAndLetsGoOfADeliberateTilt() {
        let degree = Double.pi / 180
        XCTAssertEqual(VideoLeveling.limited(3 * degree), 3 * degree, accuracy: 1e-12)
        XCTAssertEqual(VideoLeveling.limited(-8 * degree), -8 * degree, accuracy: 1e-12)
        XCTAssertLessThan(abs(VideoLeveling.limited(15 * degree)), 8 * degree)
        XCTAssertEqual(VideoLeveling.limited(30 * degree), 0, accuracy: 1e-12)
        XCTAssertEqual(VideoLeveling.zeroPhaseSmooth([2, 2, 2, 2], tauFrames: 15), [2, 2, 2, 2])
        let step = VideoLeveling.zeroPhaseSmooth([Double](repeating: 0, count: 60) + [Double](repeating: 1, count: 60), tauFrames: 15)
        XCTAssertEqual(step[60], 0.5, accuracy: 0.1)   // no lag: the step is centred where it happened
        XCTAssertEqual(VideoLeveling.median([3, 1, 2]), 2)
        XCTAssertEqual(VideoLeveling.median([4, 1, 2, 3]), 2.5)
    }

    // MARK: Hey Meta in Chinese

    func testMicrophoneChunksAreSplitIntoOpusPackets() {
        let a = Data([0x08, 1, 2, 3]), b = Data([0x08, 9, 8, 7, 6])
        func be(_ n: Int) -> Data { Data([0, 0, 0, UInt8(n)]) }
        func leBytes(_ n: Int) -> Data { Data([UInt8(n), 0, 0, 0]) }
        XCTAssertEqual(OpusFraming.packets(in: be(a.count) + a + be(b.count) + b), [a, b])
        // The assistant stream's own record: length and milliseconds little-endian, then the Opus length big-endian.
        let record = leBytes(12 + a.count) + leBytes(40) + be(a.count) + Data([0, 0, 0, 0]) + a
        XCTAssertEqual(OpusFraming.packets(in: record), [a])
        XCTAssertEqual(OpusFraming.packets(in: a), [a])
        XCTAssertTrue(OpusFraming.packets(in: Data()).isEmpty)
        // TOC: config 1 is SILK narrowband 20 ms, one frame; config 3 is 60 ms; code 3 names its frame count.
        XCTAssertEqual(OpusFraming.duration(of: Data([0x08])), 0.020, accuracy: 1e-9)
        XCTAssertEqual(OpusFraming.duration(of: Data([0x18])), 0.060, accuracy: 1e-9)
        XCTAssertEqual(OpusFraming.duration(of: Data([0x0B, 0x03])), 0.060, accuracy: 1e-9)
    }

    /// The chunks of glasses log 35, which 1.04 took for bare packets: a length, the encoder's final
    /// range, then the packet, whose first byte 0x48 is SILK wideband, 20 ms, mono.
    func testMicrophoneChunksOfThisFirmwareCarryALengthAndARange() {
        let packet = Data([0x48, 0x01, 0x1d, 0x23]) + Data(repeating: 0x5a, count: 36)
        let chunk = Data([0, 0, 0, 0x28, 0x0d, 0x0b, 0x40, 0x8d]) + packet
        let split = OpusFraming.split(chunk)
        XCTAssertEqual(split.layout, .ranged)
        XCTAssertEqual(split.packets, [packet])
        XCTAssertEqual(OpusFraming.duration(of: split.packets[0]), 0.020, accuracy: 1e-9)
        // Two in one chunk, and a frame the encoder left out between them.
        let second = Data([0x48, 0x80, 0xf3, 0x8f, 0x11])
        let more = chunk + Data([0, 0, 0, 0, 1, 2, 3, 4]) + Data([0, 0, 0, 5, 0x70, 0xd0, 0xb8, 0x00]) + second
        XCTAssertEqual(OpusFraming.split(more).layout, .ranged)
        XCTAssertEqual(OpusFraming.packets(in: more), [packet, second])
        // Visor's layouts are still told apart from it.
        XCTAssertEqual(OpusFraming.split(Data([0, 0, 0, 2, 0x08, 1])).layout, .lengths)
        XCTAssertEqual(OpusFraming.split(Data([0x08, 1, 2, 3])).layout, .bare)
    }

    func testQuestionsAboutWhatIsSeenAreToldFromTheRest() {
        for question in ["帮我看看这是什么", "我面前是什么东西", "这上面写着什么", "what am I looking at?",
                         "Can you read this sign", "describe the room"] {
            XCTAssertTrue(VisualQuestion.sounds(question), question)
        }
        for question in ["今天天气怎么样", "讲个笑话", "what time is it", "it seems late", "who are you"] {
            XCTAssertFalse(VisualQuestion.sounds(question), question)
        }
        XCTAssertTrue(Glasses.spokenAnswerPrompt("这是什么", picture: true).contains("attached picture"))
        XCTAssertTrue(Glasses.spokenAnswerPrompt("这是什么", picture: false).contains("no picture arrived"))
        XCTAssertNil(VisualQuestion.modelPicture(Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }

    /// The glasses' picture for a question arrives on svc53 when they took it themselves, and as an
    /// Airship file outside the media namespace when the phone asked for it; whoever reads the link then.
    func testThePictureForAQuestionIsTakenFromEitherRoute() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let got = ResultBox<[String]>()
        got.value = []
        let pictures = ResultBox<[Data]>()
        pictures.value = []
        session.onAssistantPicture = { bytes, source in
            pictures.value?.append(bytes)
            got.value?.append(source)
        }

        // svc53: opened with the picture's id, pieces without a type after the first, then closed.
        let photoChannel: UInt16 = 0x8031
        let open = [DataX.tag(1, UInt16(Session.svcGlassesPhoto), last: false), DataX.tag(2, 1, last: true)]
        try peer.write(DataX.message(photoChannel, tags: open, payload: PB.bytes(1, Data(repeating: 7, count: 16))))
        try peer.write(DataX.message(photoChannel, tags: [DataX.tag(2, 2, last: true)], payload: Data("first-".utf8)))
        try peer.write(DataX.message(photoChannel, tags: [], payload: Data("second".utf8)))
        try peer.write(DataX.message(photoChannel, tags: [DataX.tag(2, 3, last: true)]))

        // Airship: an offer in another namespace is the picture only while one is waited for.
        let id = bytes("00112233445546778999aabbccddeeff")
        let content = Data("a picture".utf8)
        let offerChannel: UInt16 = 0x8032
        let offer = [DataX.tag(1, UInt16(Session.svcAirship), last: false), DataX.tag(2, Session.airOffer, last: true)]
        let named = PB.bytes(1, id) + PB.uint(2, UInt64(content.count)) + PB.string(3, "assistant") + PB.string(4, "p.heic")
        session.wantAssistantPicture(for: 5)
        try peer.write(DataX.message(offerChannel, tags: offer, payload: named))
        try peer.write(DataX.message(offerChannel, tags: [DataX.tag(2, Session.airData, last: true)], payload: content))
        let completion = PB.uint(1, UInt64(content.count)) + PB.uint(2, UInt64(Session.adler32(content)))
        try peer.write(DataX.message(offerChannel, tags: [DataX.tag(2, Session.airComplete, last: true)], payload: completion))

        // Any read of the link carries them along: here a deletion that is never confirmed.
        XCTAssertThrowsError(try session.requestCaptureDeletion(handle: "nothing", timeout: 0.6))
        XCTAssertEqual(pictures.value, [Data("first-second".utf8), content])
        XCTAssertEqual(got.value, ["svc53", "airship assistant"])
        XCTAssertFalse(session.assistantPictureArriving)

        var sent: [DataX.Message] = []
        while let frame = try? peer.nextFrame(timeout: 0.2) { sent.append(try DataX.parse(frame)) }
        let replies = sent.filter { $0.channel == offerChannel ^ 0x8000 }
        XCTAssertEqual(replies.map { $0.type ?? -1 }, [Int(Session.airCursor), Int(Session.airDrop)])
        XCTAssertEqual(replies.first?.payload, PB.uint(2, 1))
    }

    /// The bundled voice reads Chinese with numbers and English words in it, and the result goes to the
    /// glasses' 48 kHz Opus like the iPhone's voice did.
    func testTheBundledVoiceReadsChinese() async throws {
        guard NeuralVoice.isAvailable else { throw XCTSkip("this build has no bundled voice model") }
        XCTAssertEqual(NeuralVoice.speakers.count, 103)
        XCTAssertEqual(NeuralVoice.speakers[NeuralVoice.defaultSpeaker], "zf_001")
        XCTAssertEqual(NeuralVoice.offered.count, 12)
        let made = try XCTUnwrap(await NeuralVoice.shared.speak("你好，今天是 11 月 26 日，我是你的 AI 助手。",
                                                               speaker: NeuralVoice.defaultSpeaker))
        XCTAssertEqual(made.rate, 24_000)
        let seconds = Double(made.samples.count) / made.rate
        XCTAssertGreaterThan(seconds, 1.5)
        XCTAssertLessThan(seconds, 12)
        XCTAssertGreaterThan(made.samples.map(abs).max() ?? 0, 0.05)
        let upsampled = try XCTUnwrap(PhoneVoice.resample(made.samples, from: made.rate, to: 48_000))
        XCTAssertEqual(Double(upsampled.count), Double(made.samples.count) * 2, accuracy: 2_400)
        XCTAssertEqual(PhoneVoice.neuralSpeaker(for: "zh-CN"), NeuralVoice.defaultSpeaker)
        XCTAssertNil(PhoneVoice.neuralSpeaker(for: "zh-HK"))     // Cantonese is the iPhone's
        XCTAssertNil(PhoneVoice.neuralSpeaker(for: "en-US"))
    }

    /// Chinese is the phone's to hear and English the glasses': which of the two transcripts is the question.
    func testChineseComesFromThePhoneAndEnglishFromTheGlasses() {
        func asked(_ phone: String, _ glasses: String, _ tag: String = "zh-CN") -> String {
            Assistant.question(phone: phone, glasses: glasses, phoneTag: tag)
        }
        XCTAssertEqual(asked("今天天气怎么样", "can you tell me"), "今天天气怎么样")
        XCTAssertEqual(asked("what time is it now please", "What time is it?"), "What time is it?")
        XCTAssertEqual(asked("", "What time is it?"), "What time is it?")
        XCTAssertEqual(asked("现在几点", ""), "现在几点")
        XCTAssertEqual(asked("", ""), "")
        // Any language the phone listens for, not Chinese alone.
        XCTAssertEqual(asked("今日の天気はどうですか", "kyoto tenki", "ja-JP"), "今日の天気はどうですか")
        XCTAssertEqual(asked("Quel temps fait-il aujourd'hui à Paris ?", "kel tom fay til", "fr-FR"),
                       "Quel temps fait-il aujourd'hui à Paris ?")

        // A new user's iPhone language picks the starting point; one not offered leaves it to the glasses.
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "zh-Hans-CN"), "zh-CN")
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "zh-Hant-HK"), "zh-HK")
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "ja-JP"), "ja-JP")
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "en-GB"), HeyMetaLanguage.glasses)
        XCTAssertEqual(HeyMetaLanguage.tag(forPreferred: "sv-SE"), HeyMetaLanguage.glasses)
    }

    /// Chinese to glasses that recognise English: they hear nothing, ask nothing and close the turn, and
    /// the phone's words for it are a question the app answers itself. A turn the glasses understood and
    /// dealt with ("take a photo") is not.
    func testAQuestionTheGlassesDidNotAskAboutIsHandedToTheApp() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let assistant = Assistant(session: session)
        assistant.transcribesOnPhone = { true }
        assistant.onTranscript = { _, _ in XCTFail("the glasses asked nothing") }
        let wake = ResultBox<String>()
        let streamEnded = ResultBox<XCTestExpectation>()
        let closed = ResultBox<XCTestExpectation>()
        assistant.onMicrophoneEnded = { id in
            wake.value = id
            streamEnded.value?.fulfill()
        }
        assistant.onTurnEnded = { _ in closed.value?.fulfill() }
        let handed = expectation(description: "the question reached the app")
        let question = ResultBox<String>()
        assistant.onUnclaimedQuestion = { words, _ in
            question.value = words
            handed.fulfill()
        }
        let registered = expectation(description: "assistant registered")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try assistant.register(timeout: 8) } catch { XCTFail("registration failed: \(error)") }
            registered.fulfill()
        }
        let messages = try nextPhoneMessage(peer, type: Int(Assistant.MT.initMessageRequest), timeout: 8)
        try peer.write(DataX.message(messages.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initMessageResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        let stream = try nextPhoneMessage(peer, type: Int(Assistant.MT.initStreamRequest), timeout: 8)
        try peer.write(DataX.message(stream.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initStreamResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        wait(for: [registered], timeout: 10)
        assistant.startLoop()
        defer { assistant.stop() }

        func send(_ channel: UInt16, _ type: Int32?, _ payload: Data) throws {
            let tags = type.map { [DataX.tag(2, UInt16($0), last: true)] } ?? []
            try peer.write(DataX.message(channel ^ 0x8000, tags: tags, payload: payload))
        }
        /// One turn: wake, a microphone stream, and the glasses closing it with `words` of their own.
        func turn(_ id: String, glassesHeard words: String) throws {
            let ended = expectation(description: "\(id): the microphone stream ended")
            let over = expectation(description: "\(id): the glasses closed the turn")
            streamEnded.value = ended
            closed.value = over
            try send(messages.channel, Assistant.MT.startInteraction, ThriftWriter().string(1, id).done())
            try send(stream.channel, Assistant.MT.streamHeader, PB.string(1, "stream-0123456789") + PB.string(2, id))
            try send(stream.channel, Assistant.MT.streamAudio, Data([0, 0, 0, 1, 0, 0, 0, 0, 0x48]))
            try send(stream.channel, Assistant.MT.streamEnd, Data())
            wait(for: [ended], timeout: 5)
            let close = ThriftWriter().string(1, id).structField(2, ThriftWriter().string(3, words).done()).done()
            try send(messages.channel, Assistant.MT.netEvent, assistant.netEvent(Assistant.EV.interactionClosed, close))
            wait(for: [over], timeout: 5)
        }

        // The glasses understood this one and did it themselves; the phone's words for it are not a question.
        try turn("turn-en", glassesHeard: "take a photo")
        assistant.submitPhoneTranscript("take a photo", wakeID: try XCTUnwrap(wake.value))
        // This one they closed without a word of their own, before the phone was done recognising.
        try turn("turn-zh", glassesHeard: "")
        assistant.submitPhoneTranscript("今天天气怎么样", wakeID: try XCTUnwrap(wake.value))
        wait(for: [handed], timeout: 5)
        XCTAssertEqual(question.value, "今天天气怎么样")
    }

    /// How many times a second the signal changes sign: twice its frequency for a tone.
    private func signChanges(_ buffers: [AVAudioPCMBuffer]) -> (changes: Int, frames: Int) {
        var changes = 0, frames = 0
        var wasPositive = false
        for buffer in buffers {
            guard let samples = buffer.floatChannelData?[0] else { continue }
            for index in 0 ..< Int(buffer.frameLength) {
                let positive = samples[index] >= 0
                if frames > 0, positive != wasPositive { changes += 1 }
                wasPositive = positive
                frames += 1
            }
        }
        return (changes, frames)
    }

    /// The glasses' microphone is 16 kHz speech, which Opus carries in its SILK mode; the answer voice is
    /// 48 kHz. A decoder that only gave the right number of samples would leave the recogniser deaf
    /// (glasses log 34: 221 packets decoded, 0 characters heard), so the tone itself has to come back.
    func testSpeechPacketsDecodeToTheSoundThatWentIn() throws {
        let rate = 16_000.0
        let pcmFormat = try XCTUnwrap(OpusCodec.pcmFormat(sampleRate: rate))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(rate)))
        pcm.frameLength = AVAudioFrameCount(rate)
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0 ..< Int(rate) { samples[index] = Float(sin(Double(index) * 2 * Double.pi * 440 / rate) * 0.4) }
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: 320, mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let speech = AVAudioFormat(streamDescription: &description),
              let encoder = AVAudioConverter(from: pcmFormat, to: speech) else {
            throw XCTSkip("no 16 kHz Opus encoder in this simulator")
        }
        if encoder.applicableEncodeBitRates?.contains(16_000) == true { encoder.bitRate = 16_000 }
        var packets: [Data] = []
        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: speech, packetCapacity: 64,
                                              maximumPacketSize: max(1_500, encoder.maximumOutputPacketSize))
            var failure: NSError?
            let status = encoder.convert(to: out, error: &failure) { _, state in
                if fed {
                    state.pointee = .endOfStream
                    return nil
                }
                fed = true
                state.pointee = .haveData
                return pcm
            }
            if status == .error { break }
            if let sizes = out.packetDescriptions {
                for index in 0 ..< Int(out.packetCount) where sizes[index].mDataByteSize > 0 {
                    packets.append(Data(bytes: out.data.advanced(by: Int(sizes[index].mStartOffset)),
                                        count: Int(sizes[index].mDataByteSize)))
                }
            }
            if status == .endOfStream || out.packetCount == 0 { break }
        }
        guard packets.count > 20 else { throw XCTSkip("the simulator's Opus encoder gave no 16 kHz packets") }
        let modes = Set(packets.map { Int(($0.first ?? 0) >> 3) }).sorted()
        let decoder = try XCTUnwrap(OpusCodec.Decoder())
        let decoded = packets.compactMap { decoder.decode($0) }
        let heard = signChanges(decoded)
        guard heard.frames > 0 else { throw XCTSkip("no Opus decoder in this simulator") }
        XCTAssertEqual(Double(heard.frames), rate, accuracy: rate * 0.15, "Opus configurations \(modes)")
        // 440 Hz changes sign 880 times a second.
        let perSecond = Double(heard.changes) / (Double(heard.frames) / rate)
        XCTAssertEqual(perSecond, 880, accuracy: 130, "Opus configurations \(modes)")
    }

    /// The recogniser's text can start over after a pause and its last result can be empty.
    func testWordsAlreadyHeardSurviveAnEmptyLastResult() {
        var words = SpokenWords()
        words.take("今天")
        words.take("今天天气")
        words.take("今天天气怎么样")
        words.take("")
        XCTAssertEqual(words.text, "今天天气怎么样")
        words.take("明天呢")                       // after a pause: a new start, much shorter
        XCTAssertEqual(words.text, "今天天气怎么样明天呢")
        words.take("明天呢？")
        XCTAssertEqual(words.text, "今天天气怎么样明天呢？")

        var revised = SpokenWords()
        revised.take("what is the weather today")
        revised.take("What's the weather today?")   // a revision of the same sentence replaces it
        XCTAssertEqual(revised.text, "What's the weather today?")
        revised.take("And")
        XCTAssertEqual(revised.text, "What's the weather today? And")
    }

    func testTheWakeWordIsNotPartOfTheQuestion() {
        XCTAssertEqual(WakeWord.strip("Hey Meta，今天天气怎么样"), "今天天气怎么样")
        XCTAssertEqual(WakeWord.strip("嘿 Meta 你是谁？"), "你是谁？")
        XCTAssertEqual(WakeWord.strip("hey麦塔。现在几点"), "现在几点")
        XCTAssertEqual(WakeWord.strip("Hey Meta."), "")
        XCTAssertEqual(WakeWord.strip("meta"), "")
        // Without the greeting it is the subject of a question.
        XCTAssertEqual(WakeWord.strip("Meta 公司的总部在哪里"), "Meta 公司的总部在哪里")
        XCTAssertEqual(WakeWord.strip("今天天气怎么样"), "今天天气怎么样")
    }

    /// An English answer read by a Chinese voice was part of why 1.03 sounded stiff.
    func testTheAnswerIsReadInTheLanguageItIsWrittenIn() {
        XCTAssertEqual(PhoneVoice.languageTag(of: "我是 Claude，由 Anthropic 开发的 AI 助手。", preferred: "zh-CN"), "zh-CN")
        XCTAssertEqual(PhoneVoice.languageTag(of: "我係 Claude，有咩可以幫到你？", preferred: "zh-HK"), "zh-HK")
        XCTAssertEqual(PhoneVoice.languageTag(of: "今天天气不错。", preferred: "en-US"), "zh-CN")
        XCTAssertEqual(PhoneVoice.languageTag(of: "I'm Claude, an AI assistant made by Anthropic. How can I help you today?",
                                              preferred: "zh-CN"), "en-US")
        XCTAssertEqual(PhoneVoice.speakable("**好的**，`现在`是 # 三点。"), "好的，现在是  三点。")
    }

    func testWhatTheGlassesPlayedIsReadFromTheirStreamStatus() {
        XCTAssertEqual(Assistant.playbackReport(Data("7f3a9c1e22_0b6d-41aa_516480_5400".utf8)),
                       "assistant: the glasses played 5380 ms of 5400 ms")
        XCTAssertEqual(Assistant.playbackReport(Data([1, 2, 3])), "assistant: answer stream status, 3 bytes")
    }

    /// Why the phone heard nothing is told only when the phone's set-up is why.
    func testTheReasonForHearingNothingIsOneTheUserCanActOn() {
        XCTAssertNotNil(GlassesEars.problem(authorized: false, hasRecognizer: true, seconds: 4, peak: 0.3, failures: []))
        let dictation = GlassesEars.problem(authorized: true, hasRecognizer: true, seconds: 4, peak: 0.3,
                                            failures: ["kLSRErrorDomain 201 Siri and Dictation are disabled"])
        XCTAssertEqual(dictation?.contains("听写"), true)
        XCTAssertEqual(GlassesEars.problem(authorized: true, hasRecognizer: true, seconds: 4, peak: 0.0001,
                                           failures: [])?.contains("没有声音"), true)
        // Nobody spoke: no fault, nothing to tell.
        XCTAssertNil(GlassesEars.problem(authorized: true, hasRecognizer: true, seconds: 4, peak: 0.3,
                                         failures: ["kAFAssistantErrorDomain 1110 No speech detected"]))
        XCTAssertNil(GlassesEars.problem(authorized: true, hasRecognizer: true, seconds: 0.1, peak: 0, failures: []))
    }

    /// The answer voice needs the system Opus encoder, and the recogniser its decoder.
    func testOpusRoundTripThroughTheSystemCodec() throws {
        let format = try XCTUnwrap(OpusCodec.pcmFormat(sampleRate: 48_000))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        pcm.frameLength = 48_000
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0 ..< 48_000 { samples[index] = Float(sin(Double(index) * 2 * Double.pi * 440 / 48_000) * 0.4) }
        guard let packets = OpusCodec.encode(pcm) else {
            throw XCTSkip("no Opus encoder in this simulator")
        }
        // One second in 20 ms packets, each well under a kilobyte at 32 kbit/s.
        XCTAssertEqual(Double(packets.count), 50, accuracy: 4)
        XCTAssertLessThan(packets.map(\.count).max() ?? 0, 600)
        XCTAssertEqual(OpusFraming.duration(of: packets[packets.count / 2]), 0.020, accuracy: 1e-9)
        let decoder = try XCTUnwrap(OpusCodec.Decoder())
        let heard = signChanges(packets.compactMap { decoder.decode($0) })
        guard heard.frames > 0 else { throw XCTSkip("no Opus decoder in this simulator") }
        XCTAssertEqual(Double(heard.frames), 16_000, accuracy: 1_600)   // one second at 16 kHz for the recogniser
        XCTAssertEqual(Double(heard.changes), 880, accuracy: 130)      // and it is the 440 Hz tone that went in
    }

    /// Chinese is not recognised on the glasses: the request arrives without words, the microphone
    /// stream goes to the phone, and what the phone heard is answered under the id of that request.
    func testWordsFromThePhoneAnswerTheRequestFromTheGlasses() throws {
        let (session, peer) = try encryptedLoopback(trust: true)
        let assistant = Assistant(session: session)
        assistant.transcribesOnPhone = { true }
        let heard = expectation(description: "the question reached the app")
        let question = ResultBox<String>()
        let turn = ResultBox<String>()
        assistant.onTranscript = { text, interaction in
            question.value = text
            turn.value = interaction
            heard.fulfill()
        }
        let streamEnded = expectation(description: "the microphone stream ended")
        let chunks = ResultBox<Int>()
        chunks.value = 0
        assistant.onMicrophoneAudio = { _ in chunks.value = (chunks.value ?? 0) + 1 }
        assistant.onMicrophoneEnded = { wake in
            assistant.submitPhoneTranscript("今天天气怎么样", wakeID: wake)
            streamEnded.fulfill()
        }
        let registered = expectation(description: "assistant registered")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try assistant.register(timeout: 8) } catch { XCTFail("registration failed: \(error)") }
            registered.fulfill()
        }
        let messages = try nextPhoneMessage(peer, type: Int(Assistant.MT.initMessageRequest), timeout: 8)
        try peer.write(DataX.message(messages.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initMessageResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        let stream = try nextPhoneMessage(peer, type: Int(Assistant.MT.initStreamRequest), timeout: 8)
        try peer.write(DataX.message(stream.channel ^ 0x8000,
                                     tags: [DataX.tag(2, UInt16(Assistant.MT.initStreamResponse), last: true)],
                                     payload: PB.uint(1, 5)))
        wait(for: [registered], timeout: 10)
        assistant.startLoop()
        defer { assistant.stop() }

        func send(_ channel: UInt16, _ type: Int32?, _ payload: Data) throws {
            let tags = type.map { [DataX.tag(2, UInt16($0), last: true)] } ?? []
            try peer.write(DataX.message(channel ^ 0x8000, tags: tags, payload: payload))
        }
        try send(messages.channel, Assistant.MT.startInteraction, ThriftWriter().string(1, "turn-zh").done())
        try send(stream.channel, Assistant.MT.streamHeader, PB.string(1, "stream-0123456789") + PB.string(2, "turn-zh"))
        try send(stream.channel, Assistant.MT.streamAudio, Data([0, 0, 0, 2, 0x08, 1]))
        try send(stream.channel, nil, Data([0, 0, 0, 2, 0x08, 2]))
        try send(stream.channel, Assistant.MT.streamEnd, Data())
        wait(for: [streamEnded], timeout: 5)
        XCTAssertEqual(chunks.value, 2)
        // The request from the glasses: a turn id, no usable words.
        let request = ThriftWriter().string(1, "turn-zh").structField(2, ThriftWriter().done()).done()
        try send(messages.channel, Assistant.MT.netEvent, assistant.netEvent(Assistant.EV.fulfillmentRequest, request))
        wait(for: [heard], timeout: 5)
        XCTAssertEqual(question.value, "今天天气怎么样")
        XCTAssertEqual(turn.value, "turn-zh")
    }
}
