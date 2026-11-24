// App.swift 鈥?the iPhone talks to the glasses by itself.
//
//   scan 鈫?connect 鈫?L2CAP(PSM 128) 鈫?AirShield handshake
//        鈫?(once) become owner via svc36 + Meta   鈫?afterwards: trust
//        鈫?capture list 鈫?pull newest photo over the encrypted link
//        鈫?ask your own model about it (any OpenAI-compatible endpoint)

import SwiftUI
import CoreBluetooth
import Photos
import UIKit
import UniformTypeIdentifiers

@main
struct GlassesApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - share sheet plumbing

struct ShareBox: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

// MARK: - link controller

@MainActor
final class Glasses: NSObject, ObservableObject {
    @Published var log: [String] = []
    @Published var devices: [ScanEntry] = []
    private var scanTimer: Timer?
    private var scanRound = 0
    private var scanRounds = 4
    @Published var connected = false
    @Published var busy = false
    @Published var ownerLine = "owner key: 鏈煡"
    @Published var glassesLine = "鏈繛鎺?
    @Published var lastPhoto: Data?
    @Published var answer = ""
    @Published var share: ShareBox?

    @Published var modelBaseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? "http://192.168.3.90:11434/v1"
    @Published var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "gemma3:4b"
    @Published var settings: [String: String] = [:]
    @Published var settingsLoading = false
    @Published var status = GlassesState()
    @Published var captures: [Capture] = []
    @Published var recording = false
    @Published var lastVideo: Data?
    @Published var live: LiveStream?
    @Published var liveLine = "鈥?
    @Published var selfTestLines: [SelfTest.Line] = []
    @Published var selfTestBad = 0
    @Published var showSelfTest = false
    private var liveTicker: Timer?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var stream: SDUStream?
    private var session: Session?
    private var owner: OwnerMaterial?

    /// Ray-Ban Meta Gen 2 exposes its link on L2CAP PSM 0x80.
    let psm: CBL2CAPPSM = 0x80

    var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("glasses.log")
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "dev.local.glasseslink.central"])
        if let k = OwnerMaterial.loadFromKeychain() {
            owner = k
            ownerLine = "owner key: 宸茶浇鍏?\(k.publicKeyXy.hexShort)"
        } else if let (k, b) = try? OwnerMaterial.load(from: OwnerMaterial.defaultURL) {
            owner = k
            ownerLine = "owner key: 浠庢枃浠跺鍏?\(b.serial)"
        } else {
            ownerLine = "owner key: 娌℃湁鈥斺€斿厛鐐广€屾垚涓轰富浜恒€?
        }
        note("鍚姩銆俹wner=\(owner == nil ? "鏃? : "鏈?)")
    }

    /// Runs the checks that only this phone can answer (key import, both signing paths,
    /// ECDH) and pushes every line into the log so it can be shared after a failed connect.
    func runSelfTest() {
        let lines = SelfTest.run()
        note("鈥斺€?鑷寮€濮?鈥斺€?)
        for l in lines { note("\(l.ok ? "鉁? : "鉁?) \(l.text)") }
        let bad = lines.filter { !$0.ok }.count
        note("鈥斺€?鑷缁撴潫锛歕(lines.count) 椤癸紝澶辫触 \(bad) 鈥斺€?)
        // Also show it as a sheet: the log area is easy to miss on first run.
        selfTestLines = lines
        selfTestBad = bad
        showSelfTest = true
    }

    // MARK: logging (kept on disk so it can be shared from the phone)

    func note(_ s: String) {
        let line = "\(Self.ts()) \(s)"
        log.insert(line, at: 0)
        if log.count > 500 { log.removeLast() }
        if let d = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: logURL)
            }
        }
        print(line)
    }

    static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    // MARK: scan / connect

    /// Keeping the glasses advertising while you fiddle with them matters more than a tidy
    /// one-shot scan: the two of you are never in sync, so scan in a few rounds instead.
    func startScan(rounds: Int = 4) {
        guard central.state == .poweredOn else { note("钃濈墮涓嶅彲鐢細\(central.state.rawValue)"); return }
        devices.removeAll()
        scanRound = 0
        scanRounds = rounds
        beginScanRound()
    }

    private func beginScanRound() {
        scanRound += 1
        note("绗?\(scanRound)/\(scanRounds) 杞壂鎻忥紙姣忚疆 15 绉掞級鈥︾溂闀滄姌鍙犲悗闀挎寜鎷嶆憚閿?5 绉掑埌鎸囩ず鐏棯钃?)
        // Duplicates must stay ON: the glasses announce themselves in a short burst and
        // then go quiet, so a scan started a second too early would otherwise never see them.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            Task { @MainActor in
                self.central.stopScan()
                if self.devices.contains(where: { $0.isGlasses }) {
                    self.note("鎵惧埌鐪奸暅浜嗭紝鐐瑰垪琛ㄦ渶涓婇潰閭ｆ潯杩炴帴")
                    return
                }
                if self.scanRound < self.scanRounds {
                    self.beginScanRound()
                    return
                }
                if self.devices.isEmpty {
                    self.note("鍥涜疆閮芥病鎵埌浠讳綍璁惧锛氱‘璁よ摑鐗欏紑鐫€銆丟lassesLink 鏈夎摑鐗欐潈闄?)
                } else {
                    self.note("鎵埌 \(self.devices.count) 鍙拌澶囦絾閮芥病鏈夌溂闀溿€備袱涓師鍥狅細鈶?閭ｅ彴瀹夊崜杩樿繛鐫€瀹冿紙鍏虫帀瀹夊崜钃濈墮锛夆憽 鐪奸暅娌¤繘閰嶅妯″紡锛堟姌鍙?鈫?闀挎寜鎷嶆憚閿?5 绉?鈫?鎸囩ず鐏棯钃濓級")
                }
            }
        }
    }

    func connect(_ id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("鎵句笉鍒拌繖鍙拌澶囷紙鍏堟壂鎻忥級"); return
        }
        central.stopScan()
        peripheral = p
        p.delegate = self
        UserDefaults.standard.set(id.uuidString, forKey: "lastPeripheral")
        note("杩炴帴 \(p.name ?? "?") 鈥?)
        central.connect(p, options: nil)
    }

    /// The glasses stay paired at the iOS level, so a cold launch can go straight back to
    /// the same peripheral without scanning 鈥?that is what makes "鎵撳紑灏辫兘鐢? work.
    func autoReconnect() {
        guard central.state == .poweredOn else { return }
        guard let saved = UserDefaults.standard.string(forKey: "lastPeripheral"),
              let id = UUID(uuidString: saved) else { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("涓婃鐨勭溂闀滅幇鍦ㄤ笉鍦ㄧ郴缁熼噷锛岀偣銆屾壂鎻忋€嶄竴娆?)
            return
        }
        peripheral = p
        p.delegate = self
        note("鑷姩杩炴帴涓婃鐨勭溂闀?\(p.name ?? saved) 鈥?)
        central.connect(p, options: nil)
    }

    // MARK: link bring-up

    private func bringUp(trust: Bool) async {
        guard let ch = channel else { note("娌℃湁 L2CAP 閫氶亾"); return }
        let s = SDUStream(channel: ch)
        s.onLog = { [weak self] in self?.note($0) }
        stream = s
        guard let own = owner else {
            note("娌℃湁 owner key锛氳繖鏉￠摼璺彧鑳界敤鏉ヨ窇銆屾垚涓轰富浜恒€?)
            return
        }
        let sess = Session(stream: s, owner: own, log: { [weak self] in self?.note($0) })
        session = sess
        do {
            try sess.handshake(trust: trust)
            connected = true
            if trust { UserDefaults.standard.set(true, forKey: "isOwner") }
            glassesLine = "宸茶繛涓?路 trust=\(trust) 路 serial \(sess.peerSerial)"
            note("鉁?鎻℃墜瀹屾垚")
        } catch {
            note("鉂?鎻℃墜涓柇锛歕(error)")
            glassesLine = "鎻℃墜澶辫触锛歕(error)"
        }
    }

    /// Connect without proving ownership 鈥?used before the first provisioning.
    func connectSetup() { Task { await bringUp(trust: false) } }

    /// Normal connect: prove we hold the owner key.
    func connectTrusted() { Task { await bringUp(trust: true) } }

    // MARK: capture

    func loadCaptures() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let caps = try sess.captureList()
                captures = caps.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
                note("娓呭崟 \(caps.count) 鏉?)
            } catch {
                note("璇绘竻鍗曞け璐ワ細\(error)")
            }
        }
    }

    /// Pulls one capture's best asset: the still for a photo, the first video asset otherwise.
    func fetch(_ captureItem: Capture, saveToLibrary: Bool) {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        let asset = captureItem.isPhoto
            ? (captureItem.stills.first ?? captureItem.assets.first)
            : (captureItem.assets.first { $0.type == 1 } ?? captureItem.assets.first)
        guard let asset else {
            note("杩欐潯娌℃湁鍙紶鐨勮祫浜?)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                note("鎷夊彇 \(captureItem.handle) / \(asset.uuid)锛圽(asset.size)B锛?)
                try sess.requestAsset(handle: captureItem.handle, assetID: asset.uuid)
                guard let transfer = try sess.receiveFile(timeout: 300) else {
                    note("娌℃敹鍒版枃浠讹紙瀵圭娌″彂璧蜂紶杈擄級")
                    return
                }
                note("鏀跺埌 \(transfer.name) \(transfer.size)B")
                if transfer.data.prefix(2) == Data([0xFF, 0xD8]) {
                    lastPhoto = transfer.data
                    if saveToLibrary { saveToPhotos(transfer.data) }
                } else {
                    lastVideo = transfer.data
                    note("瑙嗛宸叉敹鍒帮紝鐢ㄣ€屽垎浜棰戙€嶅鍑?)
                }
            } catch {
                note("鍙栨枃浠跺け璐ワ細\(error)")
            }
        }
    }

    /// Press the glasses' shutter, then pull whatever landed. The glasses take a
    /// second or two to write the file, so this waits before asking for the list.
    func snap() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        busy = true
        Task {
            do {
                try sess.shutterPhoto()
                note("宸叉寜蹇棬锛岀瓑鐪奸暅鍐欐枃浠垛€?)
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                busy = false
                capture()
            } catch {
                busy = false
                note("蹇棬澶辫触锛歕(error)")
            }
        }
    }

    /// Start or stop a recording through the same SNIntent path Visor uses.
    /// On stop it waits for the file and pulls it, like the photo path.
    func toggleRecording() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        let wasRecording = recording
        busy = true
        Task {
            do {
                if wasRecording {
                    try sess.stopVideo()
                    note("宸插彂鍋滄褰曞儚锛岀瓑鐪奸暅鏀跺熬鈥?)
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    recording = false
                    busy = false
                    loadCaptures()
                } else {
                    try sess.startVideo()
                    note("宸插彂寮€濮嬪綍鍍?)
                    recording = true
                    busy = false
                }
            } catch {
                busy = false
                note("褰曞儚鎺у埗澶辫触锛歕(error)")
            }
        }
    }

    func capture() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let caps = try sess.captureList()
                note("娓呭崟 \(caps.count) 鏉?)
                captures = caps.sorted { ($0.timestampNS ?? 0) > ($1.timestampNS ?? 0) }
                guard let newest = caps.filter({ $0.isPhoto })
                        .max(by: { ($0.timestampNS ?? 0) < ($1.timestampNS ?? 0) }),
                      let still = newest.stills.first else {
                    note("娓呭崟閲屾病鏈夌収鐗囪祫浜?)
                    return
                }
                note("鎷夊彇 \(newest.handle) / \(still.uuid) (\(still.size)B)")
                try sess.requestAsset(handle: newest.handle, assetID: still.uuid)
                if let t = try sess.receiveFile() {
                    lastPhoto = t.data
                    note("鏀跺埌 \(t.name) \(t.size)B")
                    saveToPhotos(t.data)
                } else {
                    note("娌℃敹鍒版枃浠讹紙瀵圭娌″彂璧蜂紶杈擄級")
                }
            } catch {
                note("鍙栧浘澶辫触锛歕(error)")
            }
        }
    }

    func refreshStatus() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        Task {
            do {
                let s = try sess.subscribeStatus()
                status = s
                if s.lines.isEmpty { note("鐘舵€侊細鐪奸暅娌″洖璁惧鐘舵€?) }
            } catch {
                note("鐘舵€佽鍙栧け璐ワ細\(error)")
            }
        }
    }

    // MARK: assistant takeover

    @Published var assistantOn = false
    private var assistantRef: Assistant?

    /// svc15 registration: after this the glasses' own wake word routes to this app.
    func startAssistant() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        guard assistantRef == nil else { return }
        let a = Assistant(session: sess)
        a.log = { [weak self] line in self?.note("asst: \(line)") }
        a.onTurn = { [weak self] interaction in
            guard let self else { return }
            let client = ModelClient(baseURL: self.modelBaseURL, model: self.modelName)
            Task {
                let q = "鐢ㄦ埛鍒氬敜閱掓櫤鑳界溂闀溿€傚彧鐢ㄤ竴鍙ヤ笉瓒呰繃 20 瀛楃殑绠€浣撲腑鏂囧洖搴旂敤鎴枫€?
                let text = (try? await client.ask(question: q, jpeg: Data())) ?? "鎴戝湪銆?
                a.complete(interaction: interaction, text: text)
            }
        }
        // The glasses' own speech recognition finished a sentence: answer it with the model.
        a.onTranscript = { [weak self] transcript, interaction in
            guard let self else { return }
            let client = ModelClient(baseURL: self.modelBaseURL, model: self.modelName)
            Task {
                let q = "鐢ㄦ埛鎴寸潃鏅鸿兘鐪奸暅璇达細鈥淺(transcript)鈥濄€傜敤涓嶈秴杩?40 瀛楃殑绠€浣撲腑鏂囩洿鎺ュ洖绛旓紝涓嶇敤澶嶈堪闂銆?
                let text = (try? await client.ask(question: q, jpeg: Data())) ?? "鎴戞病鍚竻锛屽啀璇翠竴閬嶏紵"
                a.complete(interaction: interaction, text: text)
            }
        }
        do {
            try a.register()
            a.startLoop()
            assistantRef = a
            assistantOn = true
            note("鍔╂墜鎺ョ宸插紑鍚?)
        } catch {
            note("鍔╂墜鎺ョ澶辫触锛歕(error)")
        }
    }

    func stopAssistant() {
        assistantRef?.stop()
        assistantRef = nil
        assistantOn = false
        note("鍔╂墜鎺ョ宸插叧闂?)
    }

    // MARK: live

    func startLive() {
        guard let sess = session else { note("鍏堣繛鎺?); return }
        guard live == nil else { return }
        let l = LiveStream(session: sess)
        l.log = { [weak self] line in self?.note("live: \(line)") }
        l.onPhase = { [weak self] phase in
            self?.note("live phase: \(phase.rawValue)")
            if phase == .failed { self?.liveLine = "澶辫触" }
        }
        l.onPhoto = { [weak self] photo in
            guard let self else { return }
            if let img = UIImage(data: photo.data) {
                self.lastPhoto = photo.data
                self.saveToPhotos(photo.data)
                self.note("live 蹇収 \(photo.data.count)B 宸插瓨鐩稿唽")
                _ = img
            } else {
                self.note("live 蹇収 \(photo.data.count)B锛岀郴缁熻В涓嶄簡锛圽(photo.isHeic ? "HEIC" : "鏈煡")锛?)
            }
        }
        live = l
        l.start()
        // One second of stats into the overlay line; the stream itself runs on its own thread.
        liveTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let l = self.live else { return }
            self.liveLine = "\(l.phase.rawValue) \(l.framesPerSecond)fps \(l.kbitPerSecond)kbit/s "
                + "\(l.frames)甯? + (l.decodedSize.map { " \(Int($0.width))x\(Int($0.height))" } ?? "")
        }
    }

    func stopLive() {
        liveTicker?.invalidate()
        liveTicker = nil
        live?.stop()
        live = nil
        liveLine = "鈥?
    }

    func shareVideo() {
        guard let data = lastVideo else { note("杩樻病鏈夎棰?); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture.mp4")
        do {
            try data.write(to: url)
            share = ShareBox(url: url)
        } catch {
            note("鍐欎复鏃舵枃浠跺け璐ワ細\(error)")
        }
    }

    private func saveToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self?.note("娌℃湁鐩稿唽鏉冮檺锛岀収鐗囧彧鍦?app 鍐?) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, err in
                let msg = ok ? "宸插瓨鍒扮浉鍐? : "瀛樼浉鍐屽け璐ワ細\(err?.localizedDescription ?? "?")"
                Task { @MainActor in self?.note(msg) }
            }
        }
    }

    // MARK: ask your own model

    func ask(_ question: String) {
        guard let photo = lastPhoto else { note("鍏堟媿涓€寮?); return }
        UserDefaults.standard.set(modelBaseURL, forKey: "modelBaseURL")
        UserDefaults.standard.set(modelName, forKey: "modelName")
        busy = true
        Task {
            defer { busy = false }
            do {
                let text = try await ModelClient(baseURL: modelBaseURL, model: modelName,
                                                 log: { [weak self] in self?.note($0) })
                    .ask(question: question, jpeg: photo)
                answer = text
            } catch {
                note("妯″瀷璋冪敤澶辫触锛歕(error)")
            }
        }
    }

    // MARK: provisioning (no Android, no PC)

    func becomeOwner(userToken: String) {
        guard let sess = session else {
            note("鍏堢偣銆岃繛鎺ワ紙setup 閾捐矾锛夈€嶏紝鍐嶇櫥褰?)
            return
        }
        let key = owner ?? OwnerMaterial.generate()
        owner = key
        ownerLine = "owner key: 鏂板缓 \(key.publicKeyXy.hexShort)"
        busy = true
        Task {
            defer { busy = false }
            do {
                let bundle = try await Provisioner.becomeOwner(session: sess, owner: key,
                                                               userToken: userToken,
                                                               log: { [weak self] in self?.note($0) })
                UserDefaults.standard.set(true, forKey: "isOwner")
                ownerLine = "owner key: 宸叉敞鍐?路 serial \(bundle.serial)"
                note("鉁?杩欏彴 iPhone 鐜板湪鏄富浜恒€傛柇寮€閲嶈繛涓€娆¤蛋 trust 閾捐矾")
                shareOwner()
            } catch {
                note("鉂?鏀?owner 澶辫触锛歕(error)")
            }
        }
    }

    // MARK: export

    /// Copies an owner bundle picked in the Files app into Documents, then loads it.
    func importOwner(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = try? OwnerMaterial.loadAny(from: try writeTemp(data)) else {
                note("瑙ｆ瀽澶辫触鈥斺€旇 owner-export.json 鎴?Visor 瀵煎嚭鐨?visor-owner-*.json")
                return
            }
            // Normalise to owner-export.json so the next launch finds it without the original file.
            let normalised = try JSONEncoder().encode(parsed.1)
            try normalised.write(to: OwnerMaterial.defaultURL, options: .atomic)
            try parsed.0.saveToKeychain()
            owner = parsed.0
            ownerLine = "owner key: 宸插鍏?\(parsed.1.serial)"
            note("宸插鍏?\(parsed.1.serial) 鐨?owner key锛堟潵婧愭枃浠跺彲鐩存帴鏄?Visor 瀵煎嚭鐨勯偅涓級")
        } catch {
            note("瀵煎叆澶辫触锛歕(error)")
        }
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-owner.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func shareOwner() {        let url = OwnerMaterial.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            note("杩樻病鏈?owner-export.json锛坧rovision 鎴愬姛鍚庢墠浼氭湁锛?)
            return
        }
        share = ShareBox(url: url)
    }

    func shareLog() {
        share = ShareBox(url: logURL)
    }

    /// Copies the log to the pasteboard so it can be pasted into a chat in one step.
    func copyLog() {
        UIPasteboard.general.string = log.reversed().joined(separator: "\n")
        note("鏃ュ織宸插鍒跺埌鍓创鏉匡紙\(log.count) 琛岋級")
    }

    // MARK: settings (svc33)

    /// Reads the whole settings namespace once and keeps it keyed by setting name.
    func loadSettings() {
        guard let sess = session, connected else {
            note("鍏堣繛鎺ョ溂闀滐紝鍐嶈璁剧疆")
            return
        }
        settingsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let objects = try sess.driveObjects()
                var map: [String: String] = [:]
                for object in objects where object.type == Drive.kv && !object.deleted {
                    map[object.uri] = object.data
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settings = map
                    self.settingsLoading = false
                    self.note("璁剧疆锛氳鍒?\(map.count) 椤?)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settingsLoading = false
                    self.note("璁剧疆璇诲彇澶辫触锛歕(error)")
                }
            }
        }
    }

    /// Writes one setting and only reports success if the read-back agrees.
    func writeSetting(_ key: String, _ value: String) {
        guard let sess = session, connected else {
            note("鍏堣繛鎺ョ溂闀滐紝鍐嶆敼璁剧疆")
            return
        }
        note("鍐?\(key) = \(value)")
        let schema = SettingsSchemaTable.schema(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // Firmware-parsed settings go over svc31; the rest live in RLDrive.
                // Either way the write is only trusted once a read comes back equal.
                var ok = false
                if let schema, !schema.viaDrive {
                    let sent = try sess.writeSettingsField(schema, value: value)
                    if sent {
                        // Read-back is only meaningful where RLDrive mirrors the same key.
                        let after = try sess.driveObjects()
                        let mirrored = after.first { $0.uri == key }
                        ok = mirrored.map { $0.data == value } ?? true
                    }
                } else {
                    ok = try sess.driveWrite(key: key, value: value)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok {
                        self.settings[key] = value
                        self.note("\(key) 宸茬敓鏁?)
                    } else {
                        self.note("\(key) 鍐欒繘鍘讳簡浣嗚鍥炰笉涓€鑷达紙鍥轰欢鍙兘鎷掓敹锛?)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.note("鍐?\(key) 澶辫触锛歕(error)")
                }
            }
        }
    }
}

// MARK: - CoreBluetooth

extension Glasses: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn:
                note("钃濈墮灏辩华")
                autoReconnect()
            case .unauthorized: note("钃濈墮鏉冮檺琚嫆鈥斺€旀鏌?Info.plist")
            case .poweredOff: note("钃濈墮鍏抽棴")
            default: note("central state \(c.state.rawValue)")
            }
        }
    }

    /// iOS relaunches us in the background with the old central; take the peripheral back.
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return
        }
        Task { @MainActor in
            peripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                note("鍚庡彴鎭㈠锛歕(restored.name ?? "鐪奸暅") 浠嶈繛鐫€")
            } else {
                note("鍚庡彴鎭㈠锛氶噸杩?\(restored.name ?? "鐪奸暅") 鈥?)
                c.connect(restored, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // The glasses are the only thing here advertising Meta's service (0xfd5f) 鈥?everything
        // else (car keys, printers) just floods the list and buries them.
        let isGlasses = name.localizedCaseInsensitiveContains("meta")
            || name.localizedCaseInsensitiveContains("rb ")
            || services.contains { $0.uuidString.lowercased().hasPrefix("fd5") }
        let entry = ScanEntry(id: p.identifier, name: name, rssi: RSSI.intValue, isGlasses: isGlasses)
        Task { @MainActor in
            if let i = self.devices.firstIndex(where: { $0.id == p.identifier }) {
                self.devices[i] = entry
            } else {
                self.devices.append(entry)
                self.note("鍙戠幇 \(name) rssi=\(RSSI)\(isGlasses ? " 鈫?鍍忕溂闀? : "")")
            }
            self.devices.sort { a, b in
                if a.isGlasses != b.isGlasses { return a.isGlasses }
                return a.rssi > b.rssi
            }
            if self.devices.count > 40 { self.devices.removeLast(self.devices.count - 40) }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            self.note("宸茶繛鎺ワ紝鎵撳紑 L2CAP PSM 0x\(String(self.psm, radix: 16))")
            p.discoverServices(nil)
            p.openL2CAPChannel(self.psm)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.connected = false
            self.glassesLine = "鏂紑"
            self.note("鏂紑锛歕(error?.localizedDescription ?? "姝ｅ父")")
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in p.services ?? [] { self.note("service \(s.uuid)") }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        Task { @MainActor in
            guard let ch = channel else {
                self.note("L2CAP 鎵撳紑澶辫触锛歕(error?.localizedDescription ?? "?")")
                return
            }
            self.channel = ch
            self.note("L2CAP up psm=0x\(String(ch.psm, radix: 16))")
            let hasOwner = self.owner != nil && UserDefaults.standard.bool(forKey: "isOwner")
            await self.bringUp(trust: hasOwner)
        }
    }
}

// MARK: - model client

struct ModelClient {
    let baseURL: String
    let model: String
    var log: (String) -> Void = { _ in }

    func ask(question: String, jpeg: Data) async throws -> String {
        guard var comps = URLComponents(string: baseURL) else { throw LinkError.io("bad base URL") }
        comps.path = (comps.path.hasSuffix("/") ? comps.path : comps.path + "/") + "chat/completions"
        guard let url = comps.url else { throw LinkError.io("bad base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserDefaults.standard.string(forKey: "modelKey") ?? "none")",
                     forHTTPHeaderField: "Authorization")
        let b64 = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": question],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
                ],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        log("POST \(url.absoluteString) model=\(model) img=\(jpeg.count)B")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw LinkError.io("model \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        return text
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var g = Glasses()
    @State private var question = "鎴戦潰鍓嶆湁浠€涔堬紵鏈夊彴闃舵垨闅滅鐗╁悧锛?
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var showImport = false
    @State private var showLive = false
    @State private var showQuick = false
    @State private var verboseLog = false

    var body: some View {
        NavigationStack {
            List {
                Section("鐘舵€?) {
                    Text(g.ownerLine).font(.footnote)
                    Text(g.glassesLine).font(.footnote).foregroundStyle(.secondary)
                }

                Section("1 路 杩炵溂闀?) {
                    Button("鎵弿闄勮繎鐪奸暅") { g.startScan() }
                    ForEach(g.devices, id: \.id) { d in
                        Button {
                            g.connect(d.id)
                        } label: {
                            HStack {
                                if d.isGlasses { Image(systemName: "eyeglasses") }
                                Text(d.name)
                                Spacer()
                                Text("\(d.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(d.isGlasses ? Color.accentColor : .secondary)
                            }
                        }
                    }
                    Text("鐪奸暅鎺掑湪鍓嶉潰锛堟湁鐪奸暅鍥炬爣锛夈€傚垪琛ㄩ噷娌℃湁 `RB Meta` 鏃讹細鈶犵溂闀滄姌鍙犲悗闀挎寜鎷嶆憚閿?5 绉掞紝绛夋寚绀虹伅闂摑 鈶℃妸閭ｅ彴瀹夊崜鐨勮摑鐗欏叧鎺夛紝鍚﹀垯鐪奸暅涓嶄細骞挎挱銆?)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("閲嶆柊鎻℃墜锛坰etup 閾捐矾锛屼笉楠?owner锛?) { g.connectSetup() }
                    Toggle("璇︾粏鏃ュ織锛堟姄瀹屾暣甯э紝鎺掓煡鐢級", isOn: $verboseLog)
                        .onChange(of: verboseLog) { _, on in Session.verbose = on }
                    Text("鎵撳紑鍚庢瘡甯ф渶澶氳 512 瀛楄妭鍗佸叚杩涘埗锛涜繛涓嶄笂鎴栨帀绾挎椂鎵撳紑锛屽啀銆屽鍒跺叏閮ㄣ€嶅彂鎴戙€?)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("2 路 鑷锛堜笉鐢ㄨ繛鐪奸暅涔熻兘璺戯級") {
                    Button("璺戜竴閬嶅瘑閽?/ 绛惧悕 / ECDH 鑷") { g.runSelfTest() }
                    Text("缁撴灉浼氬啓杩涗笅闈㈢殑鏃ュ織锛涜繛涓嶄笂鐪奸暅鏃跺厛鐪嬭繖閲岋紝鑳藉垎娓呮槸鎵嬫満杩欏瀵嗙爜瀛︾殑闂杩樻槸閾捐矾鐨勯棶棰樸€?)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("3 路 鎴愪负涓讳汉锛堝彧鍋氫竴娆★級") {
                    Button("鐢?Meta 璐﹀彿鐧诲綍骞舵敞鍐岃繖鍙?iPhone") { showLogin = true }
                    Text("鐧诲綍鍦?app 鍐呭畬鎴愶紱token 鍙敤鏉ョ粰鐪奸暅绛句竴寮?ownership receipt銆?
                         + "鎴愬姛鍚?owner-export.json 浼氬脊鍑烘潵锛屽姟蹇呭瓨鍒?iCloud銆?)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("瀵煎嚭 owner-export.json") { g.shareOwner() }
                    Button("浠庢枃浠?App 瀵煎叆 owner-export.json") { showImport = true }
                }

                Section("3.5 路 鐩稿唽 / 鎷嶇収") {
                    HStack {
                        Button(g.busy ? "澶勭悊涓€? : "鍒锋柊娓呭崟") { g.loadCaptures() }
                            .disabled(!g.connected || g.busy)
                        Spacer()
                        Button(g.busy ? "澶勭悊涓€? : "鎷夋渶鏂扮収鐗?) { g.capture() }
                            .disabled(!g.connected || g.busy)
                    }
                    Button(g.busy ? "澶勭悊涓€? : "鎸夌溂闀滃揩闂ㄦ媿涓€寮?) { g.snap() }
                        .disabled(!g.connected || g.busy)
                    Button(g.recording ? "鍋滄褰曞儚" : "寮€濮嬪綍鍍?) { g.toggleRecording() }
                        .disabled(!g.connected || g.busy)
                        .tint(g.recording ? .red : .accentColor)
                    ForEach(g.captures, id: \.handle) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.isPhoto ? "鐓х墖" : "瑙嗛") 路 \(item.assets.count) 涓祫浜?)
                                Text(item.handle).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let ns = item.timestampNS {
                                    Text(Date(timeIntervalSince1970: Double(ns) / 1e9)
                                        .formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("鍙栧洖") { g.fetch(item, saveToLibrary: item.isPhoto) }
                                .disabled(g.busy)
                        }
                    }
                    if let d = g.lastPhoto, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                    if g.lastVideo != nil {
                        Button("鍒嗕韩瑙嗛") { g.shareVideo() }
                    }
                }

                Section("璁惧鐘舵€?) {
                    ForEach(g.status.lines, id: \.self) { line in
                        Text(line).font(.footnote)
                    }
                    Button("鍒锋柊鐘舵€?) { g.refreshStatus() }.disabled(!g.connected)
                }

                Section("3.5 路 蹇嵎") {
                    Button("甯哥敤寮€鍏筹紙鍔╂墜 / 鎻愮ず闊?/ 鐢昏川锛?) { showQuick = true }
                        .disabled(!g.connected)
                }

                Section("4 路 Live 鍙栨櫙") {
                    Button(g.live == nil ? "鎵撳紑鍙栨櫙" : "鍙栨櫙涓€?) { showLive = true }
                        .disabled(!g.connected)
                    if let size = g.live?.decodedSize {
                        Text("\(Int(size.width))脳\(Int(size.height))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("5 路 闂嚜宸辩殑妯″瀷") {
                    TextField("base URL", text: $g.modelBaseURL)
                        .textInputAutocapitalization(.never).font(.footnote)
                    TextField("model", text: $g.modelName).font(.footnote)
                    TextField("闂", text: $question, axis: .vertical).lineLimit(1 ... 3)
                    Button("鐪嬪浘闂瓟") { g.ask(question) }.disabled(g.lastPhoto == nil || g.busy)
                    if !g.answer.isEmpty { Text(g.answer).font(.callout) }
                }

                Section("5.5 路 鍔╂墜鎺ョ锛圚ey Meta 璧拌繖涓?app锛?) {
                    Button(g.assistantOn ? "鍏抽棴鎺ョ" : "寮€鍚帴绠?) {
                        if g.assistantOn { g.stopAssistant() } else { g.startAssistant() }
                    }
                    .disabled(!g.connected)
                    Text("寮€鍚悗鐪奸暅鐨勫敜閱掕瘝浼氳矾鐢卞埌杩欓噷锛岀敱浣犺嚜宸遍厤鐨勬ā鍨嬪洖绛斻€傝闊宠浆鍐欒繕鍦ㄥ仛锛岀幇鍦ㄦ槸鍏堟帴浣忚繖涓€杞啀鍥炰竴鍙ヨ瘽銆?)
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("6 路 鐪奸暅璁剧疆锛圽(SettingsCatalog.all.count) 椤癸級") {
                    Button("鎵撳紑璁剧疆") { showSettings = true }
                        .disabled(!g.connected)
                    Text(g.settingsLoading ? "璇诲彇涓€? : "宸茶鍒?\(g.settings.count) 椤?)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("鏃ュ織") {
                    HStack {
                        Button("瀵煎嚭鏃ュ織鏂囦欢") { g.shareLog() }
                        Spacer()
                        Button("澶嶅埗鍏ㄩ儴") { g.copyLog() }
                    }
                    ForEach(Array(g.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Glasses")
            .sheet(isPresented: $showLogin) {
                LoginWebView(url: Meta.authorize(state: UUID().uuidString),
                             onCode: { code in
                                 showLogin = false
                                 g.note("鎷垮埌 code锛屼氦鎹?token鈥?)
                                 Task {
                                     do {
                                         let token = try await MetaClient(log: { g.note($0) })
                                             .exchangeCode(code)
                                         g.becomeOwner(userToken: token)
                                     } catch {
                                         g.note("token 浜ゆ崲澶辫触锛歕(error)")
                                     }
                                 }
                             },
                             onCancel: { showLogin = false })
            }
            .sheet(item: $g.share) { box in ActivityView(url: box.url) }
            .sheet(isPresented: $showSettings) { SettingsView(g: g) }
            .sheet(isPresented: $showLive) { LiveView(g: g) }
            .sheet(isPresented: $showQuick) { NavigationStack { QuickPanel(g: g) } }
            .sheet(isPresented: $g.showSelfTest) { SelfTestView(g: g) }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .data]) { result in
                switch result {
                case .success(let url): g.importOwner(from: url)
                case .failure(let error): g.note("閫夋枃浠跺け璐ワ細\(error.localizedDescription)")
                }
            }
        }
    }
}
