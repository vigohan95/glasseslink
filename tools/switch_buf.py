import io

p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()

s = s.replace("private var buf = Data()", "private var buf = [UInt8]()", 1)
s = s.replace("        buf.append(data)", "        buf.append(contentsOf: data)", 1)
s = s.replace(
    "            if let need = Self.frameLength(buf), buf.count >= need {\n"
    "                let frame = Data(buf.prefix(need))",
    "            if let need = Self.frameLength(buf), buf.count >= need {\n"
    "                let frame = Data(buf[0 ..< need])",
    1,
)
s = s.replace("                buf = Data(buf.dropFirst(need))", "                buf.removeFirst(need)", 1)

start = s.index("    static func frameLength(_ b: Data) -> Int? {")
end = s.index("\n    }\n", start) + len("\n    }\n")
old_fn = s[start:end]

new_fn = '''    static func frameLength(_ b: [UInt8]) -> Int? {
        guard b.count >= 1 else { return nil }
        let b0 = b[0]
        if b0 & 0xC0 == Direction.frameData {          // encrypted DATA frame
            guard b.count >= 10 else { return nil }
            return 10 + 16 * (Int(b[9]) + 1)
        }
        guard b.count >= 4 else { return nil }         // plaintext DataX
        let payloadLen = Int(b0 & 0x3F) << 8 | Int(b[1])
        return 4 + payloadLen
    }

    /// Convenience for tests and for callers that already hold a `Data`.
    static func frameLength(_ b: Data) -> Int? {
        frameLength([UInt8](b))
    }
'''
s = s[:start] + new_fn + s[end:]
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("patched", old_fn.count("\n"), "lines ->", new_fn.count("\n"))
