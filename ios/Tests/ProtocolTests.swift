import XCTest
@testable import GlassesLink

/// Golden vectors come from the Python reference stack in `meta-gen2/pi/`, which is itself
/// checked against the published protocol notes, so a failure here means the Swift port drifted.
final class ProtocolTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func bytes(_ range: Range<Int>) -> Data { Data(range.map { UInt8($0) }) }

    func testClaudeAndCompatibleModelRequestsUseTheirOwnAuthentication() throws {
        let claude = ModelClient(baseURL: "https://api.anthropic.com/v1/messages/",
                                 model: "demo-claude", apiKey: "test-claude")
        let direct = try claude.completionRequest(question: "hello", image: nil, maxTokens: 64)
        XCTAssertEqual(direct.url?.path, "/v1/messages")
        XCTAssertEqual(direct.value(forHTTPHeaderField: "x-api-key"), "test-claude")
        XCTAssertEqual(direct.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(direct.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(direct.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "hello")

        let router = ModelClient(baseURL: "https://openrouter.ai/api/v1", model: "example/model", apiKey: "test-router")
        let routed = try router.completionRequest(question: "hello", image: nil, maxTokens: 64)
        XCTAssertEqual(routed.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(routed.value(forHTTPHeaderField: "Authorization"), "Bearer test-router")
        XCTAssertNil(routed.value(forHTTPHeaderField: "x-api-key"))
    }

    // MARK: - varint

    func testProtobufLengthDelimitedFieldAtBufferBoundary() throws {
        let payload = Data(repeating: 0x5A, count: 128)
        let encoded = PB.bytes(1, payload) + PB.bytes(2, Data())
        let fields = try PB.parse(encoded)

        XCTAssertEqual(fields[1]?.first as? Data, payload)
        XCTAssertEqual(fields[2]?.first as? Data, Data())
        XCTAssertThrowsError(try PB.parse(Data(PB.bytes(1, payload).dropLast()))) { error in
            guard case LinkError.shortBuffer = error else {
                return XCTFail("Expected shortBuffer, got \(error)")
            }
        }
    }

    /// The glasses verify svc36 with NONEwithECDSA, so the channel binding must be signed
    /// verbatim. tools/p256_ref.py is the executable spec: it produces r||s for the same
    /// digest with a fixed nonce and checks it with `cryptography`'s prehashed verifier.
    func testSignsTheDigestVerbatim() throws {


        // tools/p256_ref.py produced this r||s for exactly these inputs and confirmed with
        // `cryptography`'s Prehashed verifier that it is a NONEwithECDSA signature.
        let scalar = Data(hex: "0a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526272829")
        let digest = Data((0 ..< 32).map { UInt8($0) })
        let nonce = Data(hex: "1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30")
        let expected = "4c6336e3b8b3de771b613a1c7a1734834cd69c1a4f5ffecb240c63bc0ddb1574"
            + "03bf8bb6c07d98211266b44f2c126e24cdb99572444e0d01d35b15d04433a4e2"
        let owner = OwnerMaterial(scalar: scalar)
        let sig = try owner.signRaw(digest: digest, nonce: nonce)
        XCTAssertEqual(sig.hexFull, expected)
        XCTAssertTrue(P256ECDSA.verify(digest: digest, signature: sig,
                                       publicKeyXy: owner.publicKeyXy))
        var tampered = sig
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertFalse(P256ECDSA.verify(digest: digest, signature: tampered,
                                        publicKeyXy: owner.publicKeyXy))
        XCTAssertEqual(owner.publicKeyXy.hexFull,
                       "24ac923b7211ddd1da58d1a1bac605dc9060b4da5542c8432f1bd42c45953271"
                       + "6a81b1e71d07038e36f4100fb1d7bc5a0e5df22cbb25cc98c0791c04d3c5ac86")
    }

    func testSignsWithARandomNonceAndIsStableAcrossCalls() throws {

        let owner = OwnerMaterial(scalar: Data((1 ... 32).map { UInt8($0) }))
        let digest = Data((0 ..< 32).map { UInt8($0) })
        let a = try owner.signRaw(digest: digest)
        let b = try owner.signRaw(digest: digest)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(b.count, 64)
        XCTAssertNotEqual(a, b, "a fixed nonce would leak the key")
        // r||s must stay inside the group order, and s must be the low half.
        for sig in [a, b] {
            let s = [UInt8](sig[32...])
            XCTAssertTrue(s[0] < 0x80, "s is not normalised to the low half")
        }
    }
    /// Pinpoints which primitive is wrong when signing diverges from tools/p256_ref.py.
    func testFieldAndPointPrimitives() throws {
        typealias F = P256Field
        func plainMul(_ a: UInt64, _ b: UInt64) -> UInt64 {
            func m(_ v: UInt64) -> F.Word {
                var w = F.zero
                w[0] = UInt32(v & 0xFFFF_FFFF)
                w[1] = UInt32(v >> 32)
                return w
            }
            let x = F.toMont(m(a), F.p, F.n0p, F.r2p)
            let y = F.toMont(m(b), F.p, F.n0p, F.r2p)
            return UInt64(F.fromMont(F.mulModP(x, y), F.p, F.n0p)[0])
        }
        XCTAssertEqual(plainMul(3, 5), 15)
        // 2G must match the textbook point doubling (7cf27b18… is its x coordinate)
        let two = P256ECDSA.mulG([2, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(F.data(F.fromMont(two.x, F.p, F.n0p)).hexFull,
                       "7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978")
        // the hex helper must round-trip, or every pin below is meaningless
        let nonceHex = "1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30"
        XCTAssertEqual(F.data(F.words(Data(hex: nonceHex))).hexFull, nonceHex)

        // walk a few small multiples: 3G needs the affine add path, 255G needs both
        for (k, x) in [(3, "5ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c"),
                       (15, "f0454dc6971abae7adfb378999888265ae03af92de3a0ef163668c63e59b9d5f"),
                       (255, "f44b39759a2e6db723a6f90249972dfd08e95380f1fca470eacd1d03e5edf214"),
                       (65535, "f249104d0e6f8f29e6016277780cda84dc84b83bc3d899dfb736ca0831fbe8cf")] {
            var kw = F.zero
            kw[0] = UInt32(k & 0xFFFF_FFFF)
            kw[1] = UInt32(UInt64(k) >> 32)
            let p = P256ECDSA.mulG(kw)
            XCTAssertEqual(F.data(F.fromMont(p.x, F.p, F.n0p)).hexFull, x, "\(k)G.x")
        }        // k*G for the nonce pinned in tools/p256_ref.py
        let k = F.words(Data(hex: "1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30"))
        let kg = P256ECDSA.mulG(k)
        XCTAssertEqual(F.data(F.fromMont(kg.x, F.p, F.n0p)).hexFull,
                       "4c6336e3b8b3de771b613a1c7a1734834cd69c1a4f5ffecb240c63bc0ddb1574")
        XCTAssertEqual(F.data(F.fromMont(kg.y, F.p, F.n0p)).hexFull,
                       "f6896c5d14ca44e0037791c2300333259a71b901e5258575d107e5b8ac48b424")
        // and the scalar inverse the signing step depends on
        let oneN = F.toMont(F.one, F.n, F.n0n, F.r2n)
        XCTAssertEqual(F.data(F.fromMont(F.invN(oneN), F.n, F.n0n)).hexFull,
                       "0000000000000000000000000000000000000000000000000000000000000001")
    }
    func testVarintRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_384, 1 << 32, UInt64.max >> 1] {
            let encoded = Varint.encode(value)
            let (decoded, next) = try Varint.decode(encoded, 0)
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(next, encoded.count)
        }
    }

    // MARK: - DataX

    func testDataXDecodesConsecutiveMessagesFromSlice() throws {
        let first = DataX.message(0x0007, tags: [DataX.tag(2, 6, last: true)],
                                  payload: Data([0x20, 0x30]))
        let second = DataX.status(0x0006, AirShield.stSuccess)
        let prefix = Data(repeating: 0, count: 16)
        let frame = (prefix + first + second).dropFirst(prefix.count)
        XCTAssertGreaterThan(frame.startIndex, 0)

        let messages = try DataX.parseMessages(frame, requireComplete: true)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.channel), [0x0007, 0x0006])
        XCTAssertEqual(messages.map(\.consumed), [first.count, second.count])
        XCTAssertEqual(messages.first?.type, 6)
        XCTAssertEqual(messages.first?.payload, Data([0x20, 0x30]))
        XCTAssertEqual(messages.last?.error, Int(AirShield.stSuccess))
    }

    func testDataXKeepsCompleteMessageBeforePartialTail() throws {
        let first = DataX.status(0x0007, AirShield.stSuccess)
        let second = DataX.status(0x0006, AirShield.stSuccess)
        let frame = first + second.dropLast()

        let messages = try DataX.parseMessages(frame)
        XCTAssertEqual(messages.map(\.channel), [0x0007])
        XCTAssertThrowsError(try DataX.parseMessages(frame, requireComplete: true))
    }

    func testDataXReassemblesSplitHeaderAndBody() {
        let status = DataX.status(0x0006, AirShield.stSuccess)
        let body = Data(repeating: 0x31, count: 32)
        let record = DataX.message(0x0007, tags: [DataX.tag(2, 6, last: true)], payload: body)

        for boundary in [2, 10] {
            var carry = Data()
            let first = DataX.splitMessages(status + record.prefix(boundary), carry: &carry)
            XCTAssertEqual(first.map { $0.message.channel }, [0x0006])
            XCTAssertEqual(carry, record.prefix(boundary))

            let second = DataX.splitMessages(Data(record.dropFirst(boundary)) + status, carry: &carry)
            XCTAssertEqual(second.map { $0.message.channel }, [0x0007, 0x0006])
            XCTAssertEqual(second.first?.message.payload, body)
            XCTAssertTrue(carry.isEmpty)
        }
    }

    func testDataXFrameMatchesReference() {
        // pi: dx_message(0x8002, [dx_tag(1, 31, False), dx_tag(2, 2, True)])
        let frame = DataX.message(0x8002, tags: [DataX.tag(1, 31, last: false),
                                                 DataX.tag(2, 2, last: true)])
        XCTAssertEqual(frame, hex("800880028100001f02000002"))
    }

    func testDataXParse() throws {
        let msg = try DataX.parse(hex("800880028100001f02000002"))
        XCTAssertEqual(msg.channel, 0x8002)
        XCTAssertEqual(msg.service, 31)
        XCTAssertEqual(msg.type, 2)
        XCTAssertNil(msg.error)
        XCTAssertEqual(msg.consumed, 12)
        XCTAssertEqual(msg.payload, Data())
    }

    func testStatusFrame() {
        // pi: dx_status(1, 0x1000)
        XCTAssertEqual(DataX.status(1, 0x1000), hex("8004000103001000"))
    }

    // MARK: - AirShield

    func testPaddingIsNotPKCS7() {
        // pad_len = 16 - (n % 16); each byte is pad_len + 0xC0
        let plain46 = Data(repeating: 0x01, count: 46)
        let padded = AirShieldPad.pad(plain46)
        XCTAssertEqual(padded.count, 48)
        XCTAssertEqual(padded.suffix(2), Data([0xC2, 0xC2]))
        XCTAssertEqual(AirShieldPad.unpad(padded), plain46)

        let hello = AirShieldPad.pad(Data("hello".utf8))
        XCTAssertEqual(hello, hex("68656c6c6fcbcbcbcbcbcbcbcbcbcbcb"))
        XCTAssertEqual(AirShieldPad.unpad(hello), Data("hello".utf8))
    }

    func testDeriveKeys() throws {
        // pi: derive_keys(bytes(range(32)), bytes(range(16)), bytes(range(32,64)), 40..4f)
        let keys = try AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
                                        seed: bytes(32..<64), iv: bytes(0x40..<0x50),
                                        quirks: .none, multikey: false)
        let expected = hex("be4a1ce4657ac7e8b9605751cbe0e3ce5b741863b632edc8661dc7b62ac25497")
        XCTAssertEqual(keys.aes, expected)
        XCTAssertEqual(keys.hmac, expected, "multikey off: one key does both jobs")
        XCTAssertEqual(keys.iv, bytes(0x40..<0x50))
        XCTAssertEqual(keys.macWord, hex("02020000"))
    }

    func testQCS7QuirksChangeMacWord() throws {
        let keys = try AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
                                        seed: bytes(32..<64), iv: bytes(0x40..<0x50),
                                        quirks: .qcs7, multikey: false)
        XCTAssertEqual(keys.macWord, hex("02020001"))
        let plain = try AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
                                         seed: bytes(32..<64), iv: bytes(0x40..<0x50),
                                         quirks: .none, multikey: false)
        XCTAssertNotEqual(keys.aes, plain.aes, "quirks change the HKDF info")
    }

    func testChannelBinding() {
        // pi: channel_binding(bytes(0..<16), bytes(0..<64), bytes(32..<64), bytes(64..<128))
        let binding = AirShield.channelBinding(glassesChallenge: bytes(0..<16),
                                               glassesPubkey: bytes(0..<64),
                                               seed: bytes(32..<64),
                                               phonePubkey: bytes(64..<128))
        XCTAssertEqual(binding, hex("eccda52b21ed91d89403dcc0321f482321f46cc3ddd6af5eef138c1e7345fa9c"))
    }

    func testEndLinkSetup() throws {
        let frame = try AirShield.endLinkSetup(streamUUID: hex("00112233445546778999aabbccddeeff"),
                                               linkUUID: hex("0f1e2d3c4b5a49678896a5b4c3d2e1f0"))
        XCTAssertEqual(frame, hex("802a8001020010000801121000112233445546778999aabbccddeeff"
                                  + "1a100f1e2d3c4b5a49678896a5b4c3d2e1f0"))
        XCTAssertEqual(frame.count, 46)
        XCTAssertTrue(Session.isEndLinkSetupRequest(try DataX.parse(frame)))

        XCTAssertThrowsError(try AirShield.endLinkSetup(streamUUID: Data(repeating: 0x11, count: 16),
                                                        linkUUID: hex("0f1e2d3c4b5a49678896a5b4c3d2e1f0")),
                             "a non-v4 UUID must be refused before it reaches the wire")
    }

    func testIdentityMessageWithSameTypeIsNotEndLinkSetup() throws {
        let tags = [DataX.tag(1, UInt16(AirShield.svcIdentity), last: false),
                    DataX.tag(2, AirShield.idEnableTrust, last: true)]
        for channel in [UInt16(0x8004), DataX.chSetup] {
            let identity = try DataX.parse(DataX.message(channel, tags: tags))
            XCTAssertFalse(Session.isEndLinkSetupRequest(identity))
        }
    }

    func testPeerTrustRepliesUseTheIncomingChannelMirror() throws {
        for type in [AirShield.idEnableTrust, AirShield.idEnableTrustEC] {
            let tags = [DataX.tag(1, UInt16(AirShield.svcIdentity), last: false),
                        DataX.tag(2, type, last: true)]
            let peer = try DataX.parse(DataX.message(0x8004, tags: tags))
            XCTAssertEqual(Session.peerTrustReplyChannel(peer), 0x0004)
            let mirror = try DataX.parse(DataX.message(0x0004, tags: tags))
            XCTAssertNil(Session.peerTrustReplyChannel(mirror))
        }
    }

    // MARK: - camera shutter

    func testNewCaptureConfirmationUsesOriginalAssetRatherThanGlassesClock() {
        let old = CaptureAsset(uuid: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", type: 1, delivered: false, size: 2_048)
        let new = CaptureAsset(uuid: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb", type: 1, delivered: false, size: 3_072)
        let pending = CaptureAsset(uuid: new.uuid, type: 1, delivered: false, size: 0)
        let baseline = [Capture(handle: "old", kind: 3074, timestampNS: 20, assets: [old])]
        let unfinished = Capture(handle: "new", kind: 3074, timestampNS: nil, assets: [pending])
        let finished = Capture(handle: "new", kind: 3074, timestampNS: 10, assets: [new])
        XCTAssertFalse(Shutter.hasNewOriginal(in: baseline, comparedTo: baseline, photo: false))
        XCTAssertFalse(Shutter.hasNewOriginal(in: [unfinished], comparedTo: baseline, photo: false))
        XCTAssertTrue(Shutter.hasNewOriginal(in: [finished], comparedTo: baseline, photo: false))
        XCTAssertFalse(Shutter.hasNewOriginal(in: [finished], comparedTo: baseline, photo: true))
    }

    func testCameraStateCodesMatchShutterConfirmations() {
        XCTAssertEqual(Status.cameraCode(PB.uint(3, 1)), Status.photoStarted)
        XCTAssertEqual(Status.cameraCode(PB.uint(3, 2)), Status.videoStarted)
        XCTAssertNotEqual(Status.cameraCode(PB.uint(3, 3)), Status.videoStarted)
        XCTAssertNil(Status.cameraCode(PB.uint(6, 1)))
    }

    func testPhotoIntentStructure() throws {
        let fields = try PB.parse(Shutter.photoPayload())
        XCTAssertEqual(fields[1]?.first as? Data, Data(Shutter.actionPhoto.utf8))
        let data = fields[2] as? [Data] ?? []
        XCTAssertEqual(data.count, 3, "launch type, referrer and IS_MODAL")
        let keys = try data.map { payload -> String in
            let parsed = try PB.parse(payload)
            guard let raw = parsed[1]?.first as? Data else { return "" }
            return String(decoding: raw, as: UTF8.self)
        }
        XCTAssertEqual(keys, [Shutter.keyLaunchType, Shutter.keyReferrer, Shutter.keyIsModal])
    }

    func testVideoIntents() throws {
        let start = try PB.parse(Shutter.startVideoPayload())
        XCTAssertEqual(start[1]?.first as? Data, Data(Shutter.actionStartRecording.utf8))
        let stop = try PB.parse(Shutter.stopVideoPayload())
        XCTAssertEqual(stop[1]?.first as? Data, Data(Shutter.actionCloseCapture.utf8))
        XCTAssertNil(stop[2], "stop carries no extras")
    }

    // MARK: - assistant answer

    func testAssistantRegistrationVersions() {
        XCTAssertEqual(Assistant.registrationVersion(Data()), 0)
        XCTAssertEqual(Assistant.registrationVersion(Data([2, 0, 0, 0])), 2)
        let nested = PB.uint(1, 3) + PB.bytes(2, Data([1, 2, 3, 4]))
        XCTAssertEqual(Assistant.registrationVersion(nested), 3)
    }

    func testAssistantExtractsActualFinalQuestion() throws {
        let asr = ThriftWriter().string(1, "  明天天气怎么样？  ").done()
        let understanding = ThriftWriter().structField(1, asr).done()
        let body = ThriftWriter().string(1, "turn-1").structField(2, understanding).bool(30, false).done()
        let fields = try ThriftCompact.loads(body)
        let request = try XCTUnwrap(Assistant.spokenRequest(fields))
        XCTAssertEqual(request.interaction, "turn-1")
        XCTAssertEqual(request.transcript, "明天天气怎么样？")
        XCTAssertFalse(request.simplified)
    }

    func testAssistantRejectsWakeOnlyAndTakesQuestionsAboutWhatIsSeen() throws {
        let words = ThriftWriter().string(1, "Hey Meta").done()
        let wakeUnderstanding = ThriftWriter().structField(1, words).done()
        let wake = ThriftWriter().string(1, "turn-1").structField(2, wakeUnderstanding)
            .string(23, "IN:WAKE_WORD").done()
        XCTAssertNil(Assistant.spokenRequest(try ThriftCompact.loads(wake)))
        let asr = ThriftWriter().string(1, "这是什么？").done()
        let visual = ThriftWriter().binary(4, Data(repeating: 0x11, count: 101)).done()
        let understanding = ThriftWriter().structField(1, asr).structField(4, visual).done()
        let photo = try ThriftCompact.loads(ThriftWriter().string(1, "turn-2").structField(2, understanding).done())
        // A question about what the wearer sees is a question; what it says about the camera is read apart.
        XCTAssertEqual(Assistant.spokenRequest(photo)?.transcript, "这是什么？")
        let hint = Assistant.visualHint(photo)
        XCTAssertTrue(hint.captured)
        XCTAssertEqual(hint.inline?.count, 101)
        XCTAssertFalse(Assistant.visualHint(try ThriftCompact.loads(wake)).captured)
    }

    func testCompleteLayout() throws {
        let body = Varm.complete(interaction: "turn-1", text: "前面没有台阶。",
                                 expectsAnswer: false, followUp: true)
        let outer = try ThriftCompact.loads(body)
        XCTAssertEqual(outer[1] as? Data, Data("turn-1".utf8))
        XCTAssertEqual(outer[2] as? Int64, 1000)
        let inner = try XCTUnwrap(outer[4] as? [Int: Any])
        XCTAssertEqual(inner[1] as? Data, Data("前面没有台阶。".utf8))
        XCTAssertEqual(inner[3] as? Bool, false)
        XCTAssertEqual(inner[7] as? Bool, false, "streamed=false: the glasses speak it")
        XCTAssertEqual(inner[8] as? Bool, false)
        XCTAssertEqual(inner[11] as? Bool, true)
    }

    func testVarmSpliceReplacesTemplateStrings() throws {
        guard Varm.available else {
            throw XCTSkip("varm_template.bin is not in the test bundle")
        }
        let text = "今天二十七度，适合出门。"
        let built = try XCTUnwrap(Varm.build(interaction: "turn-42", transcript: "天气怎么样", text: text))
        let parsed = try ThriftCompact.loads(built)
        XCTAssertEqual(parsed[8] as? Data, Data("turn-42".utf8))
        // The answer string sits at server[3][0][2][1] in the captured template.
        let server = try XCTUnwrap(parsed[1] as? [Int: Any])
        let answers = try XCTUnwrap(server[3] as? [Any])
        let first = try XCTUnwrap(answers.first as? [Int: Any])
        let inner = try XCTUnwrap(first[2] as? [Int: Any])
        XCTAssertEqual(inner[1] as? Data, Data(text.utf8))
        // fields 6 and 14 are cleared so no audio stream is expected after the VARM
        XCTAssertEqual(parsed[6] as? Bool, false)
        XCTAssertEqual(parsed[14] as? Bool, false)
    }

    func testSetBoolFlipsOnlyTheRequestedField() throws {
        let body = ThriftWriter().string(1, "x").bool(7, false).bool(11, false).done()
        let flipped = VarmSplice.setBool(body, 11, true)
        let parsed = try ThriftCompact.loads(flipped)
        XCTAssertEqual(parsed[11] as? Bool, true)
        XCTAssertEqual(parsed[1] as? Data, Data("x".utf8))
    }

    func testStatusReportsSeparateGlassesAndCaseCharge() {
        var state = GlassesState()
        let time = Date(timeIntervalSince1970: 100)
        let glasses = PB.bytes(1, PB.uint(2, 2) + PB.uint(3, 100))
        let chargingCase = PB.bytes(2, PB.uint(2, 1) + PB.uint(3, 0) + PB.uint(7, 100) + PB.uint(8, 1))
        Status.merge(glasses + chargingCase, into: &state, receivedAt: time)

        XCTAssertEqual(state.batteryPercent, 100)
        XCTAssertEqual(state.batteryCharge, .full)
        XCTAssertTrue(state.receivedCaseBattery)
        XCTAssertEqual(state.caseBattery?.charging, true)
        XCTAssertEqual(state.caseBattery?.reading?.level, .percent(0))
        XCTAssertEqual(state.caseBattery?.reading?.observedAt, time)

        Status.merge(PB.bytes(1, PB.uint(2, 0)), into: &state)
        XCTAssertEqual(state.batteryCharge, .unknown)
        XCTAssertNil(state.batteryCharge?.label)
    }

    func testStatusShowsCaseBarsAndRetainsTimestampedReadingAfterDetach() {
        var state = GlassesState()
        let time = Date(timeIntervalSince1970: 100)
        let chargingCase = PB.bytes(2, PB.uint(2, 0) + PB.uint(3, 3) + PB.uint(8, 1))
        Status.merge(chargingCase, into: &state, receivedAt: time)
        XCTAssertEqual(state.caseBattery?.reading?.level, .bars(3))
        XCTAssertEqual(state.caseBattery?.charging, false)

        var detached = GlassesState()
        Status.merge(PB.bytes(2, PB.uint(2, 1) + PB.uint(3, 94) + PB.uint(7, 100) + PB.uint(8, 0)),
                     into: &detached, receivedAt: time.addingTimeInterval(20))
        state.mergeReported(from: detached)
        XCTAssertEqual(state.caseBattery?.present, false)
        XCTAssertNil(state.caseBattery?.charging)
        XCTAssertNil(state.caseBattery?.reading)
        XCTAssertEqual(state.lastCaseBatteryReading?.level, .bars(3))
        XCTAssertEqual(state.lastCaseBatteryReading?.observedAt, time)

        var partial = GlassesState()
        Status.merge(PB.bytes(1, PB.uint(3, 90)), into: &partial)
        state.mergeReported(from: partial)
        XCTAssertFalse(state.receivedCaseBattery)
        XCTAssertEqual(state.lastCaseBatteryReading?.observedAt, time)
    }

    func testStatusDoesNotTreatMissingOrInvalidCaseLevelsAsZero() {
        var state = GlassesState()
        for payload in [PB.uint(8, 1), PB.uint(3, 101) + PB.uint(7, 100),
                        PB.uint(3, UInt64(UInt32.max)) + PB.uint(7, 100), PB.uint(3, 5) + PB.uint(7, 4)] {
            Status.merge(PB.bytes(2, payload), into: &state)
            XCTAssertNil(state.caseBattery?.reading)
            XCTAssertNil(state.lastCaseBatteryReading)
        }
    }
}

extension Data {
    /// Full lowercase hex — `hexShort` truncates for log lines and must not be compared.
    var hexFull: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
