import SwiftUI
import UIKit

// MARK: - 助手

/// Who answers "Hey Meta", what was answered, and a way to ask from the phone.
struct AssistantTab: View {
    @ObservedObject var g: Glasses
    let openDevice: () -> Void
    @State private var question = ""
    @State private var showModel = false
    @State private var showSpokenQuestion = false
    @State private var includePhoto = false
    @FocusState private var typing: Bool

    init(g: Glasses, openDevice: @escaping () -> Void) {
        self.g = g
        self.openDevice = openDevice
    }

    private var modelLabel: String {
        let name = g.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "还没有选择" : name
    }

    private var modelMissing: Bool {
        g.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !g.askingModel
    }

    private var takeoverTitle: String {
        if g.assistantRegistering { return "正在开启 Hey Meta…" }
        return g.assistantOn ? "Hey Meta 已接管" : "Hey Meta 未开启"
    }

    private var takeoverDetail: String {
        if g.assistantRegistering { return "等眼镜确认，通常只要几秒。" }
        if g.assistantOn {
            return "对眼镜说「Hey Meta」，听到提示音后提问。回答会在眼镜里播出。"
        }
        if !g.canUseGlasses {
            if g.connected { return "验证主人身份后可以开启。" }
            return g.assistantAutoStart ? "连上眼镜后会自动开启。" : "连接眼镜后可以开启。"
        }
        return "打开开关，眼镜上的提问就交给你选的模型回答。"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GlassesTheme.sectionSpacing) {
                    statusCard
                    conversation
                }
                .padding(.horizontal, GlassesTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .glassesPage()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("助手")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showModel) { ModelSheet(g: g) }
            .sheet(isPresented: $showSpokenQuestion) {
                SpokenQuestionView(glassesName: g.connectedGlassesName, modelName: g.modelName) { prompt in
                    g.ask(prompt)
                }
            }
        }
    }

    // MARK: 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(g.assistantOn ? GlassesTheme.accent : Color.secondary)
                    .frame(width: 48, height: 48)
                    .background((g.assistantOn ? GlassesTheme.accent : Color.secondary).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(takeoverTitle)
                        .font(.headline)
                    Text(takeoverDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                takeoverControl
            }
            if let message = g.assistantMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if g.assistantOn {
                Text("拍照、录像、调音量这类指令仍由眼镜自己处理。提问语言在「眼镜设置」里选。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button {
                typing = false
                showModel = true
            } label: {
                HStack(spacing: 8) {
                    Text("回答的模型")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(modelLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
        .glassesCard()
    }

    @ViewBuilder
    private var takeoverControl: some View {
        if g.assistantRegistering {
            ProgressView()
                .accessibilityLabel("正在开启")
        } else if g.canUseGlasses {
            Toggle("Hey Meta 接管", isOn: Binding(
                get: { g.assistantOn },
                set: { wanted in
                    Haptics.tap()
                    if wanted {
                        g.startAssistant()
                    } else {
                        g.stopAssistant()
                    }
                }
            ))
            .labelsHidden()
            .tint(GlassesTheme.accent)
            .disabled(!g.assistantOn && !g.canStartAssistant)
        } else {
            Button(g.connected ? "去验证" : "去连接", action: openDevice)
                .buttonStyle(SecondaryButtonStyle(fillsWidth: false))
        }
    }

    // MARK: 回答

    @ViewBuilder
    private var conversation: some View {
        if !g.assistantAnswer.isEmpty {
            answerCard(title: "眼镜上的回答", icon: "eyeglasses", text: g.assistantAnswer)
        }
        if g.askingModel {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在等 \(modelLabel) 回答…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .glassesCard()
        } else if !g.answer.isEmpty {
            answerCard(title: "回答", icon: "sparkles", text: g.answer)
        }
        if g.assistantAnswer.isEmpty && g.answer.isEmpty && !g.askingModel {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("在下面输入问题，或点麦克风说出来。回答会显示在这里。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func answerCard(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassesTheme.accent)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .glassesCard()
    }

    // MARK: 提问

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if g.assistantTranscriptMissing {
                HStack(alignment: .center, spacing: 8) {
                    Text("刚才没听清问题。可以直接打字，或用键盘上的麦克风听写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("打开键盘") { typing = true }
                        .buttonStyle(SecondaryButtonStyle(fillsWidth: false))
                }
            }
            if g.hasPhotoForModel {
                Toggle(isOn: $includePhoto) {
                    Label("附上最近一张照片", systemImage: "photo")
                        .font(.footnote)
                }
                .tint(GlassesTheme.accent)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    typing = false
                    showSpokenQuestion = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GlassesTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(GlassesTheme.accent.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(TileButtonStyle())
                .disabled(g.askingModel || modelMissing)
                .accessibilityLabel("说出问题")

                TextField("输入问题", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(GlassesTheme.surface, in: GlassesTheme.control)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? GlassesTheme.onAccent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background(canSend ? GlassesTheme.accent : GlassesTheme.fill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送问题")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func send() {
        let prompt = question
        question = ""
        typing = false
        Haptics.tap()
        g.ask(prompt, includePhoto: includePhoto && g.hasPhotoForModel)
    }
}
