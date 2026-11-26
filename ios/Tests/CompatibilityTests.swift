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
            do { try session.handshake(timeout: 4, trust: trust, expectedPeerIdentity: expectedIdentity) }
            catch {
                if let outcome { outcome.error = error } else { XCTFail("Encrypted test setup failed: \(error)") }
            }
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
        if trust {
            let ownerRequest = try DataX.parse(peer.nextFrame(timeout: 4))
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
            let accepted = try DataX.parse(peer.nextFrame(timeout: 4))
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
        XCTAssertGreaterThan(items.count, 20)
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
                    XCTAssertTrue(known.contains(option.value), "\(item.key)=\(option.value)")
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
        XCTAssertTrue(PhotoLeveling.shouldLevel(degrees: 11.5))
        XCTAssertFalse(PhotoLeveling.shouldLevel(degrees: 30))
    }

    /// Vision's sign convention decides whether a photo is straightened or tilted twice as far; the first
    /// CI run of this test showed the angle comes back as the correction, not the tilt. So check the
    /// whole round trip: straighten by the detected angle and the horizon must read level afterwards.
    func testStraighteningByTheDetectedAngleLevelsTheHorizon() throws {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.75, blue: 0.95)).cropped(to: frame)
        let tilt = 6.0 * Double.pi / 180
        let ground = CIImage(color: CIColor(red: 0.25, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: -3000, y: -3000, width: 6000, height: 3000))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(tilt)))
            .transformed(by: CGAffineTransform(translationX: frame.midX, y: frame.midY))
        let scene = ground.composited(over: sky).cropped(to: frame)
        guard let correction = PhotoLeveling.detectedHorizon(of: scene) else {
            throw XCTSkip("Vision found no horizon in the synthetic scene here")
        }
        XCTAssertEqual(correction * 180 / Double.pi, -6, accuracy: 2.5)
        XCTAssertEqual(PhotoLeveling.levelingAngle(of: scene), correction)

        let level = PhotoLeveling.straightened(scene, by: correction)
        let residual = try XCTUnwrap(PhotoLeveling.detectedHorizon(of: level))
        XCTAssertLessThan(abs(residual * 180 / Double.pi), 1.5)
        XCTAssertNil(PhotoLeveling.levelingAngle(of: level))
    }
}
