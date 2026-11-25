import AVFoundation
import Combine
import SwiftUI

struct MicrophoneCheckView: View {
    let glassesName: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var check = MicrophoneCheck()
    @State private var inputID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        check.start(glassesName: glassesName, inputID: inputID)
                    } label: {
                        Label("开始 5 秒测试", systemImage: "mic")
                    }
                    .disabled(check.activity != .idle)

                    if !check.availableInputs.isEmpty {
                        Picker("测试输入", selection: $inputID) {
                            Text("自动匹配眼镜").tag(String?.none)
                            ForEach(check.availableInputs) { input in
                                Text(input.name).tag(Optional(input.id))
                            }
                        }
                        .disabled(check.activity != .idle)
                    }
                } footer: {
                    Text("看到「正在录音」后，对着眼镜说话。样本只保存在这台 iPhone 上，关闭页面时删除。")
                }

                Section("检测结果") {
                    Text(check.message)
                    if let name = check.activeInput {
                        LabeledContent(check.sampleReady ? "录音使用的输入" : "测试时的系统输入", value: name)
                    }
                    if let rate = check.sampleRate {
                        LabeledContent("会话采样率", value: "\(rate) Hz")
                    }
                    if let level = check.level {
                        if check.activity == .measuring {
                            ProgressView(value: min(1, max(0, Double(level + 60) / 60)))
                                .accessibilityLabel("麦克风输入电平")
                        }
                        LabeledContent("最近读数", value: String(format: "%.0f dBFS", level))
                    }
                    if let peak = check.peak {
                        LabeledContent("最高峰值", value: String(format: "%.0f dBFS", peak))
                    }
                    if check.sampleReady {
                        Button {
                            if check.activity == .playing { check.stopPlayback() }
                            else { check.playSample() }
                        } label: {
                            Label(check.activity == .playing ? "停止回放" : "回放样本",
                                  systemImage: check.activity == .playing ? "stop.circle" : "play.circle")
                        }
                        .disabled(check.activity == .measuring)
                    }
                }

                Section {
                    HStack {
                        Label("系统播放输出", systemImage: "speaker.wave.2")
                        Spacer()
                        AudioOutputPicker().frame(width: 44, height: 44)
                    }
                } footer: {
                    Text("本页测试 iPhone 的蓝牙通话麦克风。语音助手的唤醒和听写通过独立连接。")
                }
            }
            .navigationTitle("眼镜麦克风测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in check.checkRoute() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)) { note in
            guard let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            check.interrupt()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { check.close() }
        }
        .onChange(of: check.availableInputs.map(\.id)) { _, available in
            if let inputID, !available.contains(inputID) { self.inputID = nil }
        }
        .onDisappear { check.close() }
    }
}

@MainActor
private final class MicrophoneCheck: ObservableObject {
    enum Activity: Equatable { case idle, measuring, playing }

    struct Input: Identifiable {
        let id: String
        let name: String
    }

    private struct AudioSettings {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let preferredInputID: String?
    }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var message = "点开始后，App 会检查眼镜是否提供蓝牙通话麦克风。"
    @Published private(set) var availableInputs: [Input] = []
    @Published private(set) var activeInput: String?
    @Published private(set) var sampleRate: Int?
    @Published private(set) var level: Float?
    @Published private(set) var peak: Float?
    @Published private(set) var sampleReady = false

    private let audio = AVAudioSession.sharedInstance()
    private var previousSettings: AudioSettings?
    private var activatedAudio = false
    private var task: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var sampleURL: URL?
    private var selectedHFP: String?

    func start(glassesName: String?, inputID: String?) {
        guard activity == .idle else { return }
        deleteSample()
        activeInput = nil
        sampleRate = nil
        level = nil
        peak = nil
        activity = .measuring
        message = "正在检查麦克风权限…"
        task = Task { [weak self] in
            await self?.measure(glassesName: glassesName, inputID: inputID)
        }
    }

    private func measure(glassesName: String?, inputID: String?) async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled else { return }
        defer {
            if !Task.isCancelled {
                finishActivity()
                if !sampleReady { deleteSample() }
            }
        }
        guard granted else {
            message = "没有麦克风权限。可在 iPhone 设置中允许 GlassesLink 使用麦克风。"
            return
        }

        do {
            message = "正在查找眼镜的蓝牙通话输入…"
            let hadBluetoothMedia = audio.currentRoute.outputs.contains {
                $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
            }
            try activate(.playAndRecord, options: .allowBluetooth)
            var ports = hfpInputs()
            var selected = selectedPort(in: ports, glassesName: glassesName, inputID: inputID)
            for _ in 0 ..< 12 {
                if selected != nil { break }
                try await Task.sleep(for: .milliseconds(100))
                ports = hfpInputs()
                selected = selectedPort(in: ports, glassesName: glassesName, inputID: inputID)
            }
            availableInputs = ports.map { Input(id: $0.uid, name: $0.portName) }
            guard let port = selected else {
                describeCurrentInput()
                if ports.isEmpty {
                    message = hadBluetoothMedia
                        ? "检测到蓝牙媒体输出。iPhone 没有提供蓝牙通话麦克风（HFP）。请在「设置 → 蓝牙」确认眼镜已连接后重试。"
                        : "iPhone 没有提供蓝牙通话麦克风（HFP）。请在「设置 → 蓝牙」确认眼镜已连接后重试。"
                } else {
                    message = "未找到此次测试要用的眼镜。请在「测试输入」中选择眼镜名称后重试。"
                }
                return
            }
            try audio.setPreferredInput(port)
            for _ in 0 ..< 15 {
                if hasActiveHFP(port.uid) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            describeCurrentInput()
            guard hasActiveHFP(port.uid) else {
                message = "系统没有切换到选中的蓝牙麦克风，未开始录音。"
                return
            }

            let rate = audio.sampleRate
            guard rate.isFinite, rate > 0, rate <= 384_000 else {
                message = "系统没有报告可用的录音采样率。"
                return
            }
            sampleRate = Int(rate)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("GlassesLink-mic-\(UUID().uuidString).caf")
            sampleURL = file
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ])
            recorder.isMeteringEnabled = true
            guard hasActiveHFP(port.uid), recorder.record(forDuration: 5) else {
                describeCurrentInput()
                message = "无法开始蓝牙麦克风录音。"
                return
            }
            self.recorder = recorder
            selectedHFP = port.uid
            message = "正在录音，请说话。"

            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while recorder.isRecording && ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard hasActiveHFP(port.uid) else {
                    invalidateSample("录音输入已切换，已丢弃本次样本。")
                    return
                }
                recorder.updateMeters()
                let average = recorder.averagePower(forChannel: 0)
                let samplePeak = recorder.peakPower(forChannel: 0)
                if average.isFinite { level = average }
                if samplePeak.isFinite { peak = max(peak ?? samplePeak, samplePeak) }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard hasActiveHFP(port.uid) else {
                invalidateSample("录音输入已切换，已丢弃本次样本。")
                return
            }
            recorder.stop()
            describeCurrentInput()
            if let recorded = try? AVAudioPlayer(contentsOf: file), recorded.duration >= 4.5 {
                sampleReady = true
                if let peak {
                    message = peak <= -120
                        ? "蓝牙通话麦克风的电平接近静音。可以回放，或重新测试并在录音时说话。"
                        : "已录到声音。回放样本可以确认是否录到你说的话，以及声音是否清楚。"
                } else {
                    message = "录音完成。未取得电平读数，可以回放样本检查声音。"
                }
            } else {
                message = "录音提前结束，未获得完整样本。"
            }
        } catch is CancellationError {
            return
        } catch {
            message = "麦克风测试未完成。\(error.localizedDescription)"
        }
    }

    private func hfpInputs() -> [AVAudioSessionPortDescription] {
        (audio.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }
    }

    private func selectedPort(in ports: [AVAudioSessionPortDescription], glassesName: String?,
                              inputID: String?) -> AVAudioSessionPortDescription? {
        if let inputID { return ports.first { $0.uid == inputID } }
        if let glassesName, !glassesName.isEmpty {
            let expected = normalized(glassesName)
            let sameName = ports.filter { normalized($0.portName) == expected }
            if sameName.count == 1 { return sameName[0] }
            return nil
        }

        let namedGlasses = ports.filter { normalized($0.portName).hasPrefix("rbmeta") }
        return namedGlasses.count == 1 ? namedGlasses[0] : nil
    }

    private func normalized(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
            .replacingOccurrences(of: "raybanmeta", with: "rbmeta")
    }

    private func describeCurrentInput() {
        let inputs = audio.currentRoute.inputs
        activeInput = inputs.isEmpty ? "无" : inputs.map { input in
            input.portType == .bluetoothHFP ? "\(input.portName) · HFP" : input.portName
        }.joined(separator: "、")
    }

    private func hasActiveHFP(_ id: String) -> Bool {
        let inputs = audio.currentRoute.inputs
        return inputs.count == 1 && inputs.contains { $0.uid == id && $0.portType == .bluetoothHFP }
    }

    func checkRoute() {
        guard let selectedHFP, activity == .measuring, !hasActiveHFP(selectedHFP) else { return }
        invalidateSample("录音输入已切换，已丢弃本次样本。")
    }

    func playSample() {
        guard activity == .idle, sampleReady, let sampleURL else { return }
        do {
            try activate(.playback)
            let player = try AVAudioPlayer(contentsOf: sampleURL)
            guard player.play() else {
                finishActivity()
                message = "无法回放样本。"
                return
            }
            self.player = player
            activity = .playing
            let duration = player.duration
            task = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration + 0.1)) } catch { return }
                self?.stopPlayback()
            }
        } catch {
            finishActivity()
            message = "无法回放样本。\(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        guard activity == .playing else { return }
        task?.cancel()
        finishActivity()
    }

    func interrupt() {
        if activity == .measuring {
            invalidateSample("音频被系统中断，已丢弃本次样本。")
        } else if activity == .playing {
            stopPlayback()
        }
    }

    func close() {
        if activity != .idle || sampleReady { message = "测试已结束，临时样本已删除。" }
        task?.cancel()
        finishActivity()
        deleteSample()
    }

    private func invalidateSample(_ reason: String) {
        describeCurrentInput()
        task?.cancel()
        finishActivity()
        deleteSample()
        sampleRate = nil
        level = nil
        peak = nil
        message = reason
    }

    private func activate(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions = []) throws {
        previousSettings = AudioSettings(category: audio.category, mode: audio.mode,
                                         options: audio.categoryOptions, preferredInputID: audio.preferredInput?.uid)
        try audio.setCategory(category, mode: .default, options: options)
        try audio.setActive(true)
        activatedAudio = true
    }

    private func finishActivity() {
        selectedHFP = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        if let previousSettings {
            if activatedAudio {
                if audio.category == .playAndRecord {
                    let preferred = previousSettings.preferredInputID.flatMap { id in
                        audio.availableInputs?.first { $0.uid == id }
                    }
                    try? audio.setPreferredInput(preferred)
                }
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try? audio.setCategory(previousSettings.category, mode: previousSettings.mode, options: previousSettings.options)
        }
        activatedAudio = false
        previousSettings = nil
        task = nil
        activity = .idle
    }

    private func deleteSample() {
        if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
        sampleURL = nil
        sampleReady = false
    }
}
