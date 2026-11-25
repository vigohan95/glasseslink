# Conformance with the reference implementation

Every row is a protocol step. "Source" is the Kotlin in `visor-src/` that the step was copied from;
"Ours" is where the Swift lives. A row is **matched** only when both sides are quoted here.

Status legend: ✅ matched · 🟡 matched but unproven on hardware · ❌ differed (fixed in v0.90) · ⏳ next

| # | Step | Source (Kotlin) | Ours (Swift) | Status |
|---|------|-----------------|--------------|--------|
| 1 | Open the CoC on PSM 0x80 | `BleTransport` / `openL2CAPChannel` | `Glasses.openLink(_:attempt:)` | ✅ proven — `L2CAP up psm=0x80` |
| 2 | Send RequestEncryption, then EnableEncryption **immediately** | `SecureLink.open()`: `sendLinkSetup(LINK_SETUP_CHANNEL, REQUEST_ENCRYPTION…)` then `sendLinkSetup(ENABLE_CHANNEL, ENABLE_ENCRYPTION…)`, comment *"Send our EnableEncryption IMMEDIATELY."* | `Session.handshake`: two writes back to back, `emit("sent RequestEncryption + EnableEncryption")` | ❌→✅ v0.90 (used to wait for their request) |
| 3 | EnableEncryption rides channel **0x0001**, request rides **0x8001** | `ENABLE_CHANNEL = 0x0001`, `LINK_SETUP_CHANNEL = 0x8001` | `DataX.chSetupMirror` / `DataX.chSetup`, `absorb()` accepts both | ✅ v0.85 |
| 4 | Read up to **8** frames; queue DATA frames, accept plaintext request/enable in any order; require **both** | `HANDSHAKE_READS = 8`; `pending.addLast(sdu); continue`; `if (request == null \|\| enable == null) throw` | read loop with `reads < 8`, `peerRequest`/`peerEnable` | 🟡 v0.90 (loop exists; "require both" is a soft warning because Gen 2 sometimes stays silent) |
| 5 | `multikey = (OUR_PARAMETERS & request.supportedParameters & enable.parameters & Kdf.MULTIKEY) != 0` | `SecureLink.open()` | `multikey = true` (31 & 31 & 31 & 4 = 4) | ✅ v0.72 |
| 6 | rx key: `(secret, myChallenge, enable.seed, enable.iv, quirks = enable.quirks)` | `Kdf.deriveDirectionKeys` | `deriveKeys(shared:nonce: ownChallenge, seed: peerSeed, iv: peerIV)` | ✅ v0.72 (was transposed) |
| 7 | tx key: `(secret, request.challenge, mySeed, myIv, quirks = request.quirks)` | same | `sessionKeys(... ownSeed, ownIV, quirks: request.quirks)` | 🟡 |
| 8 | tx starts at our own random sequence; rx starts at `enable.base` | `mySeq = random 32-bit`, `FrameCrypto(… mySeq.toInt())`, `FrameCrypto(rxKeys, enable.base.toInt())` | `send.seq = baseSeq`; `rx` base from peer enable | 🟡 (rx base only applied when the peer's enable was seen) |
| 9 | EndLinkSetup is **the first encrypted DATA frame**, before trust | *"EndLinkSetup is NOT sent here."* + `finishLinkSetup()` *"Send EndLinkSetup as the first encrypted DATA frame"* | `endLinkSetup(timeout: 2)` then `doTrust` | ❌→✅ v0.90 (was after trust) |
| 10 | Trust = svc36 `0x1000` type-4096 frame: `{1: SHA256(pubkey), 2: r‖s over binding, 3: 2}` | `Trust.buildEnableTrust()` | `AirShield.trustMessage` | 🟡 signatures proven in-app, not yet accepted by hardware |
| 11 | Success is `0x1000` (also accept `0x0000` on mirrors) | `Constants.Status.SUCCESS` | `LinkError.trustRejected`, accepts `stOK`/`stSuccess` | ✅ v0.55/v0.72 |

## What is still unproven

- Steps 8–10 have never been observed completing against the glasses. Everything else in this table
  has either a device log line or a unit test behind it.
- The 12-second silences in `glasses(16/17/18/19).log` all happened **before** step 2 and step 9 were
  matched. If 0.90 still goes silent, the next measurement is not another guess: it is a raw hex dump
  of every inbound SDU for the first 8 frames, plus the same dump from Visor's `wire.log` on the
  Android build, compared side by side.
