import io
p = "ios/App.swift"
s = io.open(p, encoding="utf-8").read()

# 1) phase state next to ownerState
anchor = """    @Published var ownerState: OwnerState = .unknown
"""
add = """    @Published var ownerState: OwnerState = .unknown

    /// One visible state for "what is happening right now". The user tapped, saw nothing, and
    /// could not tell whether the tap registered — a spinner that disappears after 200 ms and a
    /// silent log are both useless feedback. Everything the UI shows about progress reads this.
    enum Phase: Equatable {
        case idle
        case connecting      // CoreBluetooth connect + L2CAP open
        case handshaking     // ECDH, keys, trust
        case connected
        case failed(String)
    }
    @Published var phase: Phase = .idle

    var phaseText: String {
        switch phase {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .handshaking: return "握手中…"
        case .connected: return "已连接"
        case .failed(let why): return "失败：\\(why)"
        }
    }

    var phaseBusy: Bool {
        if case .connecting = phase { return true }
        if case .handshaking = phase { return true }
        return false
    }
"""
assert anchor in s
s = s.replace(anchor, add, 1)

# 2) connect(): visible immediately
s = s.replace("""        connecting = true
        connectingID = id
        lastConnectAt = Date()""",
"""        connecting = true
        connectingID = id
        phase = .connecting
        lastConnectAt = Date()
        note("▶︎ 已收到点击，开始连接 …")""", 1)

# 3) L2CAP up -> handshaking
s = s.replace("""            self.note("L2CAP up psm=0x\\(String(ch.psm, radix: 16))")""",
"""            self.note("L2CAP up psm=0x\\(String(ch.psm, radix: 16))")
            self.phase = .handshaking""", 1)

# 4) success / failure
s = s.replace("""            connected = true
            if trust {""",
"""            connected = true
            phase = .connected
            if trust {""", 1)
s = s.replace("""            trustLine = Glasses.explain(error)
            note("❌ 握手中断：\\(error)")""",
"""            trustLine = Glasses.explain(error)
            phase = .failed(Glasses.explain(error))
            note("❌ 握手中断：\\(error)")""", 1)
io.open(p, "w", encoding="utf-8").write(s)
print("app patched")
