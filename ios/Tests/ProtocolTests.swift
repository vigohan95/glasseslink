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

    // MARK: - varint

    /// The glasses verify svc36 with NONEwithECDSA, so the channel binding must be signed
    /// verbatim. tools/p256_ref.py is the executable spec: it produces r||s for the same
    /// digest with a fixed nonce and checks it with `cryptography`'s prehashed verifier.
    func testSignsTheDigestVerbatim() throws {
        let owner = OwnerMaterial(scalar: Data((1 ... 32).map { UInt8($0) }))
        let digest = Data((0 ..< 32).map { UInt8($0) })
        let sig = try owner.signRaw(digest: digest)
        XCTAssertEqual(sig.count, 64)
        let pub = try P256.Signing.PublicKey(rawRepresentation: Data([0x04]) + owner.publicKeyXy)
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: sig)
        XCTAssertTrue(pub.isValidSignature(parsed, for: SHA256Digest(rawRepresentation: digest)))
        let low = sig[64 - 1]
        XCTAssertTrue(low <= 0x80, "s is not the low half; the glasses normalise to it")
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

    func testDeriveKeys() {
        // pi: derive_keys(bytes(range(32)), bytes(range(16)), bytes(range(32,64)), 40..4f)
        let keys = AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
                                        seed: bytes(32..<64), iv: bytes(0x40..<0x50),
                                        quirks: .none, multikey: false)
        let expected = hex("be4a1ce4657ac7e8b9605751cbe0e3ce5b741863b632edc8661dc7b62ac25497")
        XCTAssertEqual(keys.aes, expected)
        XCTAssertEqual(keys.hmac, expected, "multikey off: one key does both jobs")
        XCTAssertEqual(keys.iv, bytes(0x40..<0x50))
        XCTAssertEqual(keys.macWord, hex("02020000"))
    }

    func testQCS7QuirksChangeMacWord() {
        let keys = AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
                                        seed: bytes(32..<64), iv: bytes(0x40..<0x50),
                                        quirks: .qcs7, multikey: false)
        XCTAssertEqual(keys.macWord, hex("02020001"))
        let plain = AirShield.deriveKeys(shared: bytes(0..<32), nonce: bytes(0..<16),
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

        XCTAssertThrowsError(try AirShield.endLinkSetup(streamUUID: Data(repeating: 0x11, count: 16),
                                                        linkUUID: hex("0f1e2d3c4b5a49678896a5b4c3d2e1f0")),
                             "a non-v4 UUID must be refused before it reaches the wire")
    }

    // MARK: - camera shutter

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
}
