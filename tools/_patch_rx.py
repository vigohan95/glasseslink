import io
p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()

old = """        var out: [RxCandidate] = []
        for (pn, nonce, seedValue) in pairs {
            guard !nonce.isEmpty, !seedValue.isEmpty else { continue }
            for (ivn, ivValue) in ivs {
                guard ivValue.count == 16 else { continue }
                for (sn, seq) in seqs {
                    guard let k = try? AirShield.deriveKeys(shared: shared, nonce: nonce, seed: seedValue,
                                                            iv: ivValue, quirks: quirks, multikey: multikey)
                    else { continue }
                    out.append(RxCandidate(label: "\\(pn) \\(ivn) \\(sn)",
                                           dir: Direction(k, seq: seq)))
                }
            }
        }
        return out"""
new = """        // The two directions are allowed to use different AirShield variants: whatever the
        // glasses announce applies to what they *send*, and some firmware announces nothing
        // while using QCS7 anyway. Try both; the HMAC decides.
        let variants: [(String, AirShield.Quirk)] = [("", quirks),
                                                    (quirks == .qcs7 ? " [plain]" : " [qcs7]",
                                                     quirks == .qcs7 ? .none : .qcs7)]
        var out: [RxCandidate] = []
        for (vn, q) in variants {
            for (pn, nonce, seedValue) in pairs {
                guard !nonce.isEmpty, !seedValue.isEmpty else { continue }
                for (ivn, ivValue) in ivs {
                    guard ivValue.count == 16 else { continue }
                    for (sn, seq) in seqs {
                        guard let k = try? AirShield.deriveKeys(shared: shared, nonce: nonce, seed: seedValue,
                                                                iv: ivValue, quirks: q, multikey: multikey)
                        else { continue }
                        out.append(RxCandidate(label: "\\(pn) \\(ivn) \\(sn)\\(vn)",
                                               dir: Direction(k, seq: seq)))
                    }
                }
            }
        }
        return out"""
assert old in s
s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8").write(s)
print("ok")
