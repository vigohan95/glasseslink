import AVFoundation
import Combine
import Speech
import SwiftUI

@MainActor
struct SpokenQuestionView: View {
    let glassesName: String?
    let modelName: String
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = SpokenQuestionCapture()
    @State private var localeID = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en-US"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("转写语言", selection: $localeID) {
                        Text("普通话").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .disabled(speech.phase != .idle)

                    switch speech.phase {
                    case .idle:
                        Button {
                            speech.start(localeID: localeID, glassesName: glassesName)
                        } label: {
                            Label(speech.text.isEmpty ? "开始说话" : "重新录音", systemImage: "mic.circle")
                        }
                    case .recording:
                        Button {
                            speech.stop()
                        } label: {
                            Label("结束录音", systemImage: "stop.circle")
                        }
                    case .preparing, .finishing:
                        ProgressView(speech.message)
                    }

                    if let input = speech.inputName {
                        LabeledContent("录音输入", value: input)
                    }
                    if speech.phase != .preparing && speech.phase != .finishing {
                        Text(speech.message).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("录音在 iPhone 上转写，最长 15 秒。确认发送后，文字会交给当前模型。")
                }

                Section("确认问题") {
                    TextEditor(text: $speech.text)
                        .frame(minHeight: 88)
                        .accessibilityLabel("可编辑的问题文字")
                        .disabled(speech.phase != .idle)
                    Button {
                        let question = speech.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !question.isEmpty else { return }
                        speech.cancel()
                        dismiss()
                        onSend(question)
                    } label: {
                        Label(modelName.isEmpty ? "发送问题" : "发送给 \(modelName)", systemImage: "arrow.up.circle")
                    }
                    .disabled(speech.phase != .idle || speech.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("语音提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        speech.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { speech.interrupt("应用已离开前台，录音结束。") }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            speech.checkInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
            guard let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            speech.interrupt("录音被系统中断。")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification).receive(on: RunLoop.main)) { _ in
            speech.interrupt("系统音频已重置，录音结束。")
        }
        .onDisappear { speech.cancel() }
    }
}

@MainActor
private final class SpokenQuestionCapture: ObservableObject {
    enum Phase: Equatable { case idle, preparing, recording, finishing }

    private struct AudioSettings {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let preferredInputID: String?
    }

    @Published var text = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "点「开始说话」使用本机转写，也可以直接输入问题。"
    @Published private(set) var inputName: String?

    private let audio = AVAudioSession.sharedInstance()
    private var id: UUID?
    private var setup: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var inputID: String?
    private var previousSettings: AudioSettings?
    private var audioActivated = false

    func start(localeID: String, glassesName: String?) {
        guard phase == .idle else { return }
        let id = UUID()
        self.id = id
        inputName = nil
        phase = .preparing
        message = "正在准备本机转写…"
        setup = Task { [weak self] in
            await self?.begin(id: id, localeID: localeID, glassesName: glassesName)
        }
    }

    private func begin(id: UUID, localeID: String, glassesName: String?) async {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.supportsOnDeviceRecognition else {
            finish(id: id, message: "当前 iPhone 不支持这门语言的本机转写。可切换语言或直接输入。")
            return
        }
        let status = await speechAuthorization()
        guard self.id == id, !Task.isCancelled else { return }
        guard status == .authorized else {
            finish(id: id, message: "未获得语音识别权限。可在 iPhone 设置中开启。")
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard self.id == id, !Task.isCancelled else { return }
        guard granted else {
            finish(id: id, message: "未获得麦克风权限。可在 iPhone 设置中开启。")
            return
        }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            finish(id: id, message: "本机语音识别当前不可用。可切换语言或直接输入。")
            return
        }

        do {
            previousSettings = AudioSettings(category: audio.category, mode: audio.mode, options: audio.categoryOptions,
                                             preferredInputID: audio.preferredInput?.uid)
            try audio.setCategory(.playAndRecord, mode: .default, options: .allowBluetooth)
            try audio.setActive(true)
            audioActivated = true

            guard let input = try await selectInput(glassesName: glassesName) else {
                finish(id: id, message: "系统没有切换到眼镜或 iPhone 麦克风。请检查蓝牙音频连接。")
                return
            }
            guard self.id == id, !Task.isCancelled else { return }
            try startEngine(recognizer: recognizer, input: input, id: id)
        } catch {
            finish(id: id, message: "无法开始本机录音。请确认麦克风可用后重试。")
        }
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }

    private func selectInput(glassesName: String?) async throws -> AVAudioSessionPortDescription? {
        if let glassesName {
            let wanted = normalized(glassesName)
            if !wanted.isEmpty {
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    let matches = (audio.availableInputs ?? []).filter {
                        $0.portType == .bluetoothHFP && normalized($0.portName) == wanted
                    }
                    if matches.count == 1 {
                        if let selected = try? await activateInput(matches[0]) { return selected }
                        break
                    }
                    if matches.count > 1 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        try Task.checkCancellation()
        guard let phone = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return nil }
        return try await activateInput(phone)
    }

    private func activateInput(_ input: AVAudioSessionPortDescription) async throws -> AVAudioSessionPortDescription? {
        try audio.setPreferredInput(input)
        for _ in 0..<12 {
            try Task.checkCancellation()
            if let active = audio.currentRoute.inputs.first, active.uid == input.uid, active.portType == input.portType {
                return active
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func normalized(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
            .replacingOccurrences(of: "raybanmeta", with: "rbmeta")
    }

    private func startEngine(recognizer: SFSpeechRecognizer, input: AVAudioSessionPortDescription, id: UUID) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            finish(id: id, message: "系统没有提供可用的麦克风格式。")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.engine = engine
        self.recognizer = recognizer
        self.request = request
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in request.append(buffer) }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.receive(id: id, transcript: transcript, isFinal: isFinal, failed: failed)
            }
        }
        engine.prepare()
        try engine.start()
        guard audio.currentRoute.inputs.first?.uid == input.uid else {
            finish(id: id, message: "系统更改了音频输入，本次录音已停止。")
            return
        }
        text = ""
        inputID = input.uid
        inputName = input.portType == .builtInMic ? "iPhone 麦克风" : input.portName
        phase = .recording
        message = "正在本机转写，请说话。"
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        guard phase == .recording, let id else { return }
        phase = .finishing
        message = "正在完成转写…"
        stopInput()
        request?.endAudio()
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.finish(id: id)
        }
    }

    func checkInput() {
        guard phase == .recording, let inputID, audio.currentRoute.inputs.first?.uid != inputID else { return }
        text = ""
        inputName = nil
        interrupt("录音输入已切换，本次转写已清除。请重新录音。")
    }

    func interrupt(_ message: String) {
        if let id { finish(id: id, message: message) }
    }

    func cancel() {
        if let id { finish(id: id) }
    }

    private func receive(id: UUID, transcript: String?, isFinal: Bool, failed: Bool) {
        guard self.id == id else { return }
        if let transcript, !transcript.isEmpty { text = transcript }
        if isFinal || failed { finish(id: id) }
    }

    private func finish(id: UUID, message: String? = nil) {
        guard self.id == id else { return }
        self.id = nil
        setup?.cancel()
        setup = nil
        timer?.cancel()
        timer = nil
        stopInput()
        if phase != .finishing { request?.endAudio() }
        recognition?.cancel()
        request = nil
        recognition = nil
        recognizer = nil
        phase = .idle
        self.message = message ?? (text.isEmpty ? "没有识别到文字，可重试或直接输入。" : "请核对文字后发送。")
    }

    private func stopInput() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        inputID = nil
        if let previousSettings {
            if audioActivated {
                let previous = audio.availableInputs?.first { $0.uid == previousSettings.preferredInputID }
                try? audio.setPreferredInput(previous)
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try? audio.setCategory(previousSettings.category, mode: previousSettings.mode, options: previousSettings.options)
        }
        audioActivated = false
        previousSettings = nil
    }
}
