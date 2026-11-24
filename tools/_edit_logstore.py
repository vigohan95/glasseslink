import re, io
p = "ios/App.swift"
s = io.open(p, encoding="utf-8").read()

# 1) drop the leftover @Published log
s = s.replace("    @Published var log: [String] = []\n", "")

# 2) delete the now-unused static DateFormatter block
s = re.sub(r"    private static let stamp: DateFormatter = \{\n(?:.*\n)*?    \}\(\)\n\n", "", s, count=1)

# 3) start the store right after the log URL is known (inside init)
s = s.replace("        note(\"GlassesLink \\(short) (\\(build)) · iOS",
              "        LogStore.shared.start(fileURL: logURL)\n        note(\"GlassesLink \\(short) (\\(build)) · iOS", 1)

io.open(p, "w", encoding="utf-8").write(s)
print("ok")
