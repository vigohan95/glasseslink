import io
p = "ios/RootView.swift"
s = io.open(p, encoding="utf-8").read()

# capsule: show the live phase, not just connected/not
old = """                Circle()
                    .fill(g.connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(g.connected ? "已连接" : "未连接")
                    .font(.caption.weight(.semibold))"""
new = """                if g.phaseBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(g.connected ? Color.green
                              : { if case .failed = g.phase { return Color.red }; return Color.orange }())
                        .frame(width: 7, height: 7)
                }
                Text(g.phaseText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)"""
assert old in s
s = s.replace(old, new, 1)

# rows: spinner while this row is working OR the whole link is busy; disable all while busy
s = s.replace("""                                if g.connectingID == d.id {
                                    ProgressView().controlSize(.small)
                                } else {""",
"""                                if g.connectingID == d.id || (g.phaseBusy && d.isGlasses) {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(g.phaseText).font(.caption2).foregroundStyle(.secondary)
                                    }
                                } else {""", 1)
s = s.replace("                        .disabled(g.connectingID != nil)",
              "                        .disabled(g.connectingID != nil || g.phaseBusy)", 1)
io.open(p, "w", encoding="utf-8").write(s)
print("root patched")
