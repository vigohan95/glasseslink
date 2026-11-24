import io
import subprocess

prev = subprocess.run(["git", "show", "HEAD~1:ios/Session.swift"], capture_output=True).stdout.decode("utf-8")
i = prev.index("final class SDUStream")
j = prev.index("final class Session")
old_mid = prev[i:j]

anchor = old_mid.index("struct CaptureAsset")
restored = old_mid[anchor:]

used = [line.strip() for line in old_mid.splitlines() if "onLog" in line]
print("onLog usage in old SDUStream:")
for line in used[:6]:
    print("   ", line)

p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()
k = s.index("final class Session")
s = s[:k] + restored + s[k:]

# New SDUStream needs the same hook the app already sets.
s = s.replace(
    "    private var writeHook: ((Data) throws -> Void)?\n    private var reader: Thread?",
    "    private var writeHook: ((Data) throws -> Void)?\n    private var reader: Thread?\n\n    /// Optional sink for transport-level notes (the app points this at its log).\n    var onLog: ((String) -> Void)?",
    1,
)
s = s.replace(
    '            print("[sdu] resync: header claimed \\(need)B, dropping a byte")',
    '            let note = "resync: header claimed \\(need)B, dropping a byte"\n            onLog?(note)',
    1,
)

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("restored", len(restored), "chars; file now", len(s))
