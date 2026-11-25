# Bug ledger

Every entry is a bug that reached a real build or a real device session. The point of this
file is not the apology, it is the **guard column**: each class of bug has either a unit test
or a rule in `tools/audit.py`, and CI refuses to build when a rule fires.

Rule of the house: a fix without a guard is not a fix, it is a patch waiting to come back.

| # | Symptom the user saw | Root cause | Where | Guard |
|---|---|---|---|---|
| 1 | "连上了但什么都没发生，也不知道是不是主人" | `bringUp(trust:)` was gated on a `isOwner` flag that was only set *after* a successful trust — so trust was never attempted | `ios/App.swift` | `OwnerState` + trust runs whenever a key exists; `R2` covers the blocking variant |
| 2 | "点了连接就闪退十几次" | release build hit `precondition` inside AirShield arg parsing | `ios/AirShield.swift` | `guard … throw LinkError.unexpected(…)` with measured lengths in the message |
| 3 | same | `Data.removeFirst` leaves `startIndex != 0`, next `b[0]` traps (SIGTRAP) | `ios/Session.swift` | buffer is `[UInt8]` now; rules `R3`, `R4` |
| 4 | "每帧都 bad MAC" | peer `EnableEncryption` arrives on channel `0x0001`, reader only accepted `0x8001` → peer seed/IV dropped | `ios/Session.swift` | accept `chSetup | chSetupMirror` in `absorb`; log line `post-enable read: peer enable=…` |
| 5 | "bad MAC，永远解不开" | rx direction derived with `(peerSeed, ownChallenge)` — the two arguments swapped | `ios/AirShield.swift` / `Session` | `receiveCandidates` keeps the correct pair first, HMAC picks the winner |
| 6 | "trust 明明对却报拒绝" | success compared against `0x0000` only; glasses answer `0x1000` | `Session.doTrust`, `_idRecv`, `FakeGlasses` | `R5` |
| 7 | "点什么都没反应，卡老久" | `handshake()` (blocks up to 12 s on NSCondition) called from a `@MainActor` function | `ios/App.swift` | `Task.detached`; `R2` |
| 8 | same | log lived in the view model and was republished per line from the BLE thread | `ios/App.swift` → `ios/LogStore.swift` | `R1` |
| 9 | "点没点上根本看不出来" | no state between "tap" and "connected" | `Glasses.Phase` + capsule + row | phase is `connecting / handshaking / connected / failed` |
| 10 | "登录页一秒就退出来" | login sheet hosted inside a pushed view that got rebuilt when `g` published | `ios/App.swift` | root-level `.sheet(item: $g.route)` |
| 11 | build fails on YAML | `project.yml` entries indented 4 spaces | `ios/project.yml` | `R8` |
| 12 | build fails: `no member 'sheet(isPresented:)'` | shell expanded `$signingIn` inside a here-string, leaving `isPresented: ,` | `ios/RootView.swift` | `R6`, and Chinese-containing sources are only edited with proper editors |
| 13 | build fails: `extraneous argument label 'value:'` | `writeSetting(_:_:)` has no second label | `ios/RootView.swift` | `R7` |
| 14 | build fails: `keyword 'struct'` | `func struct(…)` is illegal | `ios/Thrift.swift` | `R10` |
| 15 | CI hung 40–70 s, then "Restarting after unexpected exit" | `nextFrame` pumped `RunLoop.current` → `handshake` re-entered, two readers stole frames | `ios/Session.swift` | dedicated read thread; `R9` |
| 16 | six CI rounds wasted | the loopback fake peer was not faithful, and skipping inside a hosted test still killed the host | `ios/Tests/` | `-only-testing:…ProtocolTests` / `…CompatibilityTests`; canary test for the pipe |
| 17 | key imported but nothing worked | `OwnerMaterial.publicKeyXy` could be 63 bytes (CryptoKit does not zero-pad) | `ios/OwnerKey.swift` | `SelfTest` line "公钥 x‖y 64 字节（应为 64）" |
| 18 | trust signature rejected (expected) | CryptoKit `signature(for:)` hashes the digest again | `ios/OwnerKey.swift` | self-implemented P-256, cross-checked byte-for-byte with `tools/p256_ref.py` in `ProtocolTests` |
| 19 | code that should be 138 bytes was invalid DER | `AlgorithmIdentifier` declared 19 bytes but carried 20 | `ios/Provision.swift` | `SelfTest` asserts `pkcs8` length ∈ {138, 150} |
| 20 | Android owner key impossible to extract | Visor stores it in AndroidKeyStore | — | patched Visor (`.owner` suffix) exports a software key; documented in `OWNER-MIGRATION.md` |

## How to add a bug here

1. Reproduce it and write down the exact user-visible sentence.
2. Find the line that makes it true (not the line that fails).
3. Add a test **or** an `audit.py` rule that would have caught it.
4. Only then fix. If you cannot write the guard, you have not understood the bug yet.
