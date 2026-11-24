import io, re
p = "ios/App.swift"
s = io.open(p, encoding="utf-8").read()

s = s.replace('if g.log.count > 12 {\n                            DisclosureGroup("更早的 \\(g.log.count - 12) 行") {\n                                ForEach(Array(g.log.dropFirst(12).enumerated()), id: \\.offset) { _, line in',
              'if logStore.lines.count > 12 {\n                            DisclosureGroup("更早的 \\(logStore.lines.count - 12) 行") {\n                                ForEach(Array(logStore.lines.dropFirst(12).enumerated()), id: \\.offset) { _, line in', 1)

# declare the observed store in the view that owns this Section
s = s.replace("struct ContentView: View {\n    @ObservedObject var g: Glasses",
              "struct ContentView: View {\n    @ObservedObject var g: Glasses\n    @ObservedObject private var logStore = LogStore.shared", 1)
io.open(p, "w", encoding="utf-8").write(s)
print("done")
