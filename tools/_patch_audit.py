import io
# test-side success-code bug (same class as the one that blocked trust)
p = "ios/Tests/FakeGlasses.swift"
s = io.open(p, encoding="utf-8").read()
s = s.replace("""        guard s.error == Int(AirShield.stOK) else {
            throw LinkError.unexpected("phone did not ack EndLinkSetup (error 0x\\(String(s.error ?? 0xFFFF, radix: 16)))")
        }""",
"""        guard s.error == Int(AirShield.stOK) || s.error == Int(AirShield.stSuccess) else {
            throw LinkError.unexpected("phone did not ack EndLinkSetup (error 0x\\(String(s.error ?? 0xFFFF, radix: 16)))")
        }""", 1)
io.open(p, "w", encoding="utf-8").write(s)

# make R4 look at the enclosing signature instead of the whole file
p2 = "tools/audit.py"
a = io.open(p2, encoding="utf-8").read()
a = a.replace("""    if rid == "R4-raw-index":
        if not re.search(r"\\bb\\[\\s*\\d+\\s*\\]", line):
            return False, ""
        if "func frameLength(_ b: Data)" not in text:
            return False, ""   # once the buffer is [UInt8], b[0] is bounds-checked and correct""",
"""    if rid == "R4-raw-index":
        if not re.search(r"\\bb\\[\\s*\\d+\\s*\\]", line):
            return False, ""
        # Look at the enclosing signature: `[UInt8]` is bounds-checked and correct; `Data` is not.
        enclosing = ""
        for prev in reversed(lines_of(path)[max(0, lineno - 20):lineno]):
            if "func " in prev:
                enclosing = prev
                break
        if "[UInt8]" in enclosing or "Data)" not in enclosing:
            return False, """"", 1)
io.open(p2, "w", encoding="utf-8", newline="\n").write(a)
print("patched")
