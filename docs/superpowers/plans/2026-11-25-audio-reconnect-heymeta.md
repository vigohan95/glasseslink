# 1.00 Audio / Reconnect / Hey Meta Parsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship GlassesLink 1.00: glasses-audio status and repair guidance instead of the harmful bridging reconnect, reconnect that survives a changed Bluetooth identifier, and an ev57 parser that understands compact map/float.

**Architecture:** Pure, unit-tested helpers (`ThriftCompact` map/float, `GlassesAudioState.from`, `MetaAdvertisement`, `Assistant.describeUndecodableEvent`) carry the logic; `App.swift`/`RootView.swift`/`MicrophoneCheckView.swift` only wire them in. Spec: `docs/superpowers/specs/2026-11-25-audio-reconnect-heymeta-design.md`.

**Tech Stack:** Swift 5.9, SwiftUI, CoreBluetooth, AVFoundation, XCTest; XcodeGen; GitHub Actions `macos-15-intel`.

**Verification constraint:** development happens on Windows with no Swift toolchain. Tests are written first, but "run and see it fail/pass" happens in CI after the push (one CI run ≈ 12 min). Before pushing, run `python tools/audit.py ios` locally. New tests go into classes CI already runs (`AssistantAudioTests`, `CompatibilityTests`) so `ios.yml` needs no change.

---

### Task 1: Compact Thrift map, float, little-endian double

**Files:** Modify `ios/Thrift.swift` (TC, `readValue`, new `readElement`/`mapKey`, `Dictionary.map`). Test `ios/Tests/AssistantAudioTests.swift`.

- [ ] **Step 1: tests** (append to `AssistantAudioTests`)

```swift
    func testCompactMapOfStringToStructListParsesAndLaterFieldsSurvive() throws {
        let slot = ThriftWriter().string(4, "Beijing").done()
        var event = Data([0x0B, 0x34])                 // field 26 (long form), type map
        event += [0x01, 0x89]                           // one entry, key binary, value list
        event += Data([0x08]) + Data("location".utf8)
        event += Data([0x1C]) + slot                          // list of one struct
        event += Data([0x18, 0x05]) + Data("after".utf8)      // field 27 binary
        event += [TC.stop]
        let fields = try ThriftCompact.loads(event)

        let slots = fields.map(26)["location"] as? [Any]
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

        XCTAssertEqual(fields.map(1)["a"] as? Bool, true)
        XCTAssertEqual(fields.map(1)["b"] as? Bool, false)
        XCTAssertTrue(fields.map(2).isEmpty)
        XCTAssertEqual(fields[3] as? Double, 1.5)
        XCTAssertEqual(fields[4] as? Double, 2.25)
        XCTAssertEqual(fields.int(5), 7)
        XCTAssertThrowsError(try ThriftCompact.loads(Data([0x1B, 0x05, 0x88, 0x01, 0x61])))
    }

    func testFulfillmentRequestWithSlotMapYieldsTheGlassesTranscript() throws {
        let asr = ThriftWriter().string(1, "今天天气怎么样").done()
        let understanding = ThriftWriter().structField(1, asr).done()
        var body = ThriftWriter().string(1, "turn-1").structField(2, understanding).done().dropLast()
        body += Data([0x0B, 0x34, 0x01, 0x89, 0x04]) + Data("city".utf8)
        body += Data([0x1C]) + ThriftWriter().string(4, "北京").done()
        body += [TC.stop]
        let request = Assistant.spokenRequest(try ThriftCompact.loads(Data(body)))

        XCTAssertEqual(request?.interaction, "turn-1")
        XCTAssertEqual(request?.transcript, "今天天气怎么样")
    }
```

- [ ] **Step 2: implementation** (`Thrift.swift`)

Add `static let float: UInt8 = 13` to `TC`. In `readValue` replace the `TC.double` case and add `TC.float` and `TC.map`:

```swift
        case TC.double:
            // Visor's reader (core/protocol Thrift.kt) takes doubles little-endian.
            guard end - i >= 8 else { throw ThriftError.truncated("double") }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(data[i + k]) << (8 * UInt64(k)) }
            return (Double(bitPattern: bits), i + 8)
        case TC.float:
            guard end - i >= 4 else { throw ThriftError.truncated("float") }
            var bits: UInt32 = 0
            for k in 0..<4 { bits = (bits << 8) | UInt32(data[i + k]) }
            return (Double(Float(bitPattern: bits)), i + 4)
        case TC.map:
            let (size, afterSize) = try Varint.decode(data, i)
            i = afterSize
            guard size > 0 else { return ([String: Any](), i) }
            guard i < end else { throw ThriftError.truncated("map") }
            let kinds = data[i]
            i += 1
            // Every entry takes at least two bytes, so a larger count cannot be real.
            guard size <= UInt64(end - i) / 2 else { throw ThriftError.truncated("map") }
            var entries: [String: Any] = [:]
            for _ in 0..<Int(size) {
                let key = try readElement(data, i, kinds >> 4, depth: depth + 1)
                let value = try readElement(data, key.next, kinds & 0x0F, depth: depth + 1)
                entries[mapKey(key.value)] = value.value
                i = value.next
            }
            return (entries, i)
```

Below `readValue`:

```swift
    /// Inside a list, set or map a bool is a byte of its own (1 true, 2 false).
    private static func readElement(_ data: Data, _ start: Int, _ type: UInt8, depth: Int) throws -> (value: Any, next: Int) {
        guard type == TC.tTrue || type == TC.tFalse else { return try readValue(data, start, type, depth: depth) }
        guard start < data.endIndex else { throw ThriftError.truncated("bool element") }
        return (data[start] == TC.tTrue, start + 1)
    }

    /// Map keys become strings; binary keys that are not UTF-8 become hex.
    private static func mapKey(_ value: Any) -> String {
        switch value {
        case let d as Data: return String(data: d, encoding: .utf8) ?? d.hex
        case let n as Int64: return String(n)
        case let b as Bool: return b ? "true" : "false"
        default: return String(describing: value)
        }
    }
```

Accessor next to `list(_:)`: `func map(_ fid: Int) -> [String: Any] { (self[fid] as? [String: Any]) ?? [:] }`. Update the `ThriftCompact` doc comment to list `[String: Any]` and `Double`.

- [ ] **Step 3: commit** `git commit -m "fix(assistant): read compact map and float so ev57 carries its transcript"`

### Task 2: Say why an event did not decode

**Files:** Modify `ios/Assistant.swift` (`handleEvent`, new `describeUndecodableEvent`). Test `AssistantAudioTests`.

- [ ] **Step 1: test**

```swift
    func testUndecodableEventReportsInflateAndThriftFailures() {
        let broken = Assistant.describeUndecodableEvent([1: Int64(57), 2: Data([0x78, 0x9C, 0x01, 0x02, 0x03, 0x04, 0x05]), 3: true])
        XCTAssertTrue(broken.contains("inflate failed"), broken)
        let unknownType = Assistant.describeUndecodableEvent([1: Int64(57), 2: Data([0x1E, 0x00]), 3: false])
        XCTAssertTrue(unknownType.contains("bad compact type 14"), unknownType)
        XCTAssertTrue(unknownType.contains("decoded=2B"), unknownType)
    }
```

- [ ] **Step 2: implementation** — after `netEventBody`:

```swift
    /// One log line that tells a decompression failure from a parse failure.
    static func describeUndecodableEvent(_ fields: [Int: Any]) -> String {
        let raw = fields.bytes(2)
        var parts = ["body=\(raw?.count ?? 0)B", "compressed=\(fields.bool(3))"]
        guard let body = netEventBody(fields) else {
            parts.append(raw == nil ? "no body" : "inflate failed")
            if let raw { parts.append("head=\(raw.prefix(16).hex)") }
            return parts.joined(separator: " ")
        }
        parts.append("decoded=\(body.count)B")
        do {
            _ = try ThriftCompact.loads(body)
            parts.append("parsed")
        } catch {
            parts.append("thrift: \(error)")
        }
        parts.append("head=\(body.prefix(48).hex)")
        return parts.joined(separator: " ")
    }
```

In `handleEvent` replace the failure log with `log("assistant: could not decode event \(id): \(Self.describeUndecodableEvent(fields))")`.

- [ ] **Step 3: commit** `git commit -m "diag(assistant): log whether an event failed to inflate or to parse"`

### Task 3: Glasses audio state

**Files:** Modify `ios/AudioOutput.swift`. Test `ios/Tests/CompatibilityTests.swift`.

- [ ] **Step 1: test**

```swift
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
```

- [ ] **Step 2: implementation** (append to `AudioOutput.swift`)

```swift
struct AudioPortInfo: Equatable {
    let type: AVAudioSession.Port
    let name: String
}

/// Whether iOS can use the glasses as a headset. Only a system Bluetooth pairing makes that true;
/// the app's own data link never does.
enum GlassesAudioState: Equatable {
    case glasses(profile: String)
    case otherBluetooth(name: String)
    case unavailable

    static func from(outputs: [AudioPortInfo], inputs: [AudioPortInfo], glassesNames: [String]) -> GlassesAudioState {
        let wanted = Set(glassesNames.map(GlassesAudioInput.normalizedName))
        func isGlasses(_ port: AudioPortInfo) -> Bool {
            ScanEntry.matchesRayBanMetaName(port.name) || wanted.contains(GlassesAudioInput.normalizedName(port.name))
        }
        let wirelessOut = outputs.filter { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.type) }
        if let port = wirelessOut.first(where: isGlasses) {
            switch port.type {
            case .bluetoothA2DP: return .glasses(profile: "蓝牙立体声 · A2DP")
            case .bluetoothLE: return .glasses(profile: "蓝牙 LE 音频")
            default: return .glasses(profile: "蓝牙通话模式 · HFP")
            }
        }
        if inputs.contains(where: { [.bluetoothHFP, .bluetoothLE].contains($0.type) && isGlasses($0) }) {
            return .glasses(profile: "眼镜麦克风可用")
        }
        if let other = wirelessOut.first { return .otherBluetooth(name: other.name) }
        return .unavailable
    }
}
```

- [ ] **Step 3: commit** `git commit -m "feat(audio): derive glasses headset state from the iOS route"`

### Task 4: Wire audio state, remove bridging reconnect

**Files:** Modify `ios/App.swift`, `ios/RootView.swift`.

- [ ] `App.swift` init, just before `readAudioOutput()`: `UserDefaults.standard.removeObject(forKey: "requestedGlassesAudioBridging")  // 0.99 left this on for every connect`
- [ ] Add `@Published private(set) var glassesAudio: GlassesAudioState = .none` next to `audioMediaProfile`.
- [ ] At the end of `readAudioOutput()`:

```swift
        let session = AVAudioSession.sharedInstance()
        let state = GlassesAudioState.from(
            outputs: outputs.map { AudioPortInfo(type: $0.portType, name: $0.portName) },
            inputs: (session.availableInputs ?? []).map { AudioPortInfo(type: $0.portType, name: $0.portName) },
            glassesNames: verifiedPeripheralNames.values.compactMap { ScanEntry.usableName($0) })
        if state != glassesAudio {
            glassesAudio = state
            switch state {
            case .glasses(let profile): note("音频：眼镜已是 iPhone 的音频设备 · \(profile)")
            case .otherBluetooth(let name): note("音频：当前蓝牙音频设备是 \(name)，不是眼镜")
            case .unavailable: note("音频：iOS 没有把眼镜当作音频设备（需要在系统蓝牙里配对）")
            }
        }
```

- [ ] Delete `canRequestGlassesAudioConnection` and `requestGlassesAudioConnection()`. In `beginConnection` delete `bridgeAudio`/`options` and use:

```swift
        if p.state == .connected {
            openLink(p)
        } else if p.state == .disconnected {
            central.connect(p, options: nil)
        }
```

- [ ] `RootView.audioPanel`: replace the "尝试接通眼镜音频" button with:

```swift
            glassesAudioStatus
```

and add to the same view:

```swift
    @ViewBuilder private var glassesAudioStatus: some View {
        switch g.glassesAudio {
        case .glasses(let profile):
            Label("眼镜音频已接通 · \(profile)", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassesTheme.accent)
        case .otherBluetooth(let name):
            Text("当前声音走「\(name)」。要用眼镜，请在右上角的输出选择或控制中心里选眼镜。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .unavailable:
            VStack(alignment: .leading, spacing: 5) {
                Text("眼镜还不是 iPhone 的耳机，修复一次即可：").font(.footnote.weight(.semibold))
                Text("1. 设置 → 蓝牙：「我的设备」里已有眼镜就点 ⓘ →「忽略此设备」")
                Text("2. 折叠眼镜，长按拍摄键约 5 秒到指示灯闪蓝，再展开")
                Text("3. 在「设置 → 蓝牙 → 其他设备」里点眼镜，弹窗选「配对」")
                Text("4. 回到这里，会自动显示「眼镜音频已接通」")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
```

Change the test-tone hint (`"先在「设置 → 蓝牙」确认眼镜已连接…"`) to `"播放视频或其他 App 时，在控制中心的播放卡片中选择眼镜。"`.

- [ ] Commit `git commit -m "fix(audio): replace the bridging reconnect with pairing status and guidance"`

### Task 5: Mic test tolerance

**Files:** Modify `ios/MicrophoneCheckView.swift`.

- [ ] Wait loop `for _ in 0 ..< 12` → `for _ in 0 ..< 30` (3 s).
- [ ] `selectedPort` body:

```swift
        if let inputID { return ports.first { $0.uid == inputID } }
        if let glassesName, !glassesName.isEmpty {
            let expected = GlassesAudioInput.normalizedName(glassesName)
            let sameName = ports.filter { GlassesAudioInput.normalizedName($0.portName) == expected }
            if sameName.count == 1 { return sameName[0] }
        }
        let namedGlasses = ports.filter { ScanEntry.matchesRayBanMetaName($0.portName) }
        if namedGlasses.count == 1 { return namedGlasses[0] }
        // The headset name can differ from the advertised name; a single Bluetooth mic is the glasses'.
        return ports.count == 1 ? ports[0] : nil
```

- [ ] Commit `git commit -m "fix(audio): give the Bluetooth mic 3 s and accept a lone headset mic"`

### Task 6: Meta advertisement parsing

**Files:** Modify `ios/ScanEntry.swift`. Test `CompatibilityTests`.

- [ ] **Step 1: test**

```swift
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
```

- [ ] **Step 2: implementation** (append to `ScanEntry.swift`)

```swift
/// Meta's manufacturer data as CoreBluetooth reports it (company id 0x01AB first, little-endian).
/// After the company id: legacy `[product:2 LE][flags]`, or V2 `[version ≥ 0x80][product:2 LE][reserved][flags]`
/// (Visor `NearbyGlasses.advert`).
enum MetaAdvertisement {
    static let wristbandProducts: Set<Int> = [1537, 1538]

    static func isMeta(_ manufacturerData: Data?) -> Bool {
        guard let data = manufacturerData else { return false }
        let bytes = [UInt8](data)
        return bytes.count >= 2 && bytes[0] == 0xAB && bytes[1] == 0x01
    }

    static func product(_ manufacturerData: Data?) -> Int? {
        guard isMeta(manufacturerData), let data = manufacturerData else { return nil }
        let payload = [UInt8](data).dropFirst(2).map { Int($0) }
        guard payload.count >= 3 else { return nil }
        return payload[0] >= 0x80 ? payload[1] | payload[2] << 8 : payload[0] | payload[1] << 8
    }

    /// Glasses worth trying when the saved Bluetooth identifier is gone; the owner check decides.
    static func isGlassesCandidate(manufacturerData: Data?, hasMetaService: Bool) -> Bool {
        guard isMeta(manufacturerData) || hasMetaService else { return false }
        if let product = product(manufacturerData), wristbandProducts.contains(product) { return false }
        return true
    }
}
```

- [ ] Commit `git commit -m "feat(scan): read Meta product ids from advertisements"`

### Task 7: Reconnect when the identifier changed

**Files:** Modify `ios/App.swift`.

- [ ] State next to `recoveryScanUsed`:

```swift
    /// A candidate connected because the saved identifier vanished; the owner check confirms it.
    private var adoptingID: UUID?
    /// Candidates that failed that check this launch, so recovery does not pick them again.
    private var rejectedCandidates: Set<UUID> = []
```

- [ ] New helpers in the scan/connect section:

```swift
    /// iOS gives unpaired glasses a new identifier after their address rotates. When the saved one is gone,
    /// connect to a Meta glasses candidate instead; the owner check in the handshake decides whether it is ours.
    private func adoptRecoveryCandidate(_ p: CBPeripheral, why: String) {
        guard !rejectedCandidates.contains(p.identifier), channel == nil, !connecting else { return }
        stopScanning()
        resetRecovery()
        discoveredPeripherals[p.identifier] = p
        adoptingID = p.identifier
        note("上次的蓝牙标识已失效，改连\(why)的眼镜 · \(p.identifier.uuidString.suffix(4))，握手时核对主人身份")
        beginConnection(p.identifier)
    }

    private func systemConnectedCandidate() -> CBPeripheral? {
        central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Self.metaService)])
            .first { !rejectedCandidates.contains($0.identifier) }
    }
```

- [ ] `beginConnection`, inside the `guard let p = … else {` branch, before `if scanForRecovery(id) { return }`:

```swift
                if let connected = systemConnectedCandidate() {
                    adoptRecoveryCandidate(connected, why: "系统已连接")
                    return
                }
```

- [ ] `didDiscover`: compute outside the Task
  `let metaCandidate = MetaAdvertisement.isGlassesCandidate(manufacturerData: manufacturerData, hasMetaService: hasMetaService)`;
  inside the Task replace `if target { … }` with:

```swift
            if target {
                self.stopScanning()
                self.beginConnection(id)
            } else if self.recoveryScanID != nil, metaCandidate, isConnectable, (-90 ... -1).contains(rssi),
                      !self.rejectedCandidates.contains(id) {
                self.adoptRecoveryCandidate(p, why: "附近")
            }
```

- [ ] `rememberVerifiedPeripheral`: first line `if adoptingID == p.identifier { adoptingID = nil }`.
- [ ] `bringUp` catch, the `trustRejected` branch becomes:

```swift
            if case LinkError.trustRejected(let code) = error {
                if let adopted = adoptingID, adopted == peripheral?.identifier {
                    // Someone else's glasses: forget the candidate, keep our own owner state untouched.
                    note("候选眼镜不认这台 iPhone 的主人身份（0x\(String(code, radix: 16))），不是你的眼镜")
                } else {
                    resetRecovery()
                    ownerState = .rejected(code)
                    UserDefaults.standard.set("rejected:\(code)", forKey: "ownerState")
                    UserDefaults.standard.set(Self.ts(), forKey: "ownerStateAt")
                }
            }
```

- [ ] `failConnection`, first lines after the guard:

```swift
        if adoptingID == p.identifier {
            rejectedCandidates.insert(p.identifier)
            adoptingID = nil
        }
```

- [ ] Commit `git commit -m "fix(link): reconnect to the glasses after their Bluetooth identifier changes"`

### Task 8: Version, docs, audit

- [ ] `ios/project.yml`: `CFBundleShortVersionString: "1.00"`, `CFBundleVersion: "100"`.
- [ ] `python tools/audit.py ios` → `clean`.
- [ ] Commit `git commit -m "chore: GlassesLink 1.00 (100)"`.

### Task 9: CI and release (needs the user's OK to push)

- [ ] `git push -u origin claude/1.00-audio-reconnect`; watch `gh run watch`.
- [ ] On green: `gh run download <id> -n GlassesLink-ipa -D <scratch>`; copy to `D:\GlassesLink\releases\GlassesLink-1.00.0.ipa`; record size + sha256.
- [ ] Device acceptance per the spec.
