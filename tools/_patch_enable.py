import io
p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()

# 1) accept the peer's EnableEncryption on its real channel (0x0001), not only 0x8001
old = """        func absorb(_ m: DataX.Message) throws {
            guard m.channel == DataX.chSetup, let t = m.type else { return }"""
new = """        func absorb(_ m: DataX.Message) throws {
            // Visor puts RequestEncryption on LINK_SETUP (0x8001) but EnableEncryption on
            // ENABLE (0x0001). Filtering on 0x8001 alone silently dropped the peer's seed and
            // IV, which is exactly what produced "enable=absent" and an underivable rx key.
            guard m.channel == DataX.chSetup || m.channel == DataX.chEnable, let t = m.type else { return }"""
assert old in s
s = s.replace(old, new, 1)

# 2) after sending our EnableEncryption, give the peer a real window to answer with its own
old2 = """        let keys = try AirShield.sessionKeys(shared: shared,"""
new2 = """        // The glasses answer our EnableEncryption with their own, carrying the seed and IV our
        // receive direction needs. Wait for it instead of deriving keys from an empty seed.
        if peerEnable == nil {
            let until = Date().addingTimeInterval(3)
            while Date() < until, peerEnable == nil {
                guard let sdu = try? stream.nextFrame(timeout: 1.0),
                      let m = try? DataX.parse(sdu) else { continue }
                try? absorb(m)
            }
            emit("post-enable read: peer enable=\\(peerEnable == nil ? "absent" : "present")")
        }

        let keys = try AirShield.sessionKeys(shared: shared,"""
assert old2 in s
s = s.replace(old2, new2, 1)

# 3) peerEnable is a copy of a captured var; re-read after the wait
s = s.replace("peerSeed: en?.seed ?? Data(),", "peerSeed: peerEnable?.seed ?? Data(),", 1)
s = s.replace("ownIV: iv, peerIV: en?.iv ?? Data(), peerBaseSeq: en?.base ?? 0,",
              "ownIV: iv, peerIV: peerEnable?.iv ?? Data(), peerBaseSeq: peerEnable?.base ?? 0,", 1)
s = s.replace("peerChallenge: req.challenge, peerSeed: en?.seed ?? Data(),",
              "peerChallenge: req.challenge, peerSeed: peerEnable?.seed ?? Data(),", 1)
s = s.replace("ownIV: iv, peerIV: en?.iv ?? Data(), peerBase: en?.base ?? 0,",
              "ownIV: iv, peerIV: peerEnable?.iv ?? Data(), peerBase: peerEnable?.base ?? 0,", 1)

# 4) EndLinkSetup belongs AFTER trust (Visor: finishLinkSetup is the last step of open())
s = s.replace("""        do {
            try endLinkSetup(timeout: min(timeout, 2))
        } catch {
            emit("EndLinkSetup 未应答（\\(error)）——继续尝试 trust")
        }

        if trust { try doTrust(timeout: timeout) }""",
"""        if trust { try doTrust(timeout: timeout) }

        // Visor sends EndLinkSetup at the very end of open() — after trust. Sending it before
        // trust made the glasses answer trust frames we could not attribute, and cost 2 s
        // of dead time on every attempt.
        do {
            try endLinkSetup(timeout: min(timeout, 2))
        } catch {
            emit("EndLinkSetup 未应答（\\(error)）——链路已可用，继续")
        }""", 1)

io.open(p, "w", encoding="utf-8").write(s)
print("patched")
