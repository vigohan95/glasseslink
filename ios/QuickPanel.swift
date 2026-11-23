import SwiftUI

/// The handful of switches worth having one tap away, keyed straight into settings.tsv.
struct QuickPanel: View {
    @ObservedObject var g: Glasses

    struct Toggle: Identifiable {
        let key: String
        let title: String
        let detail: String
        var id: String { key }
    }

    static let toggles: [Toggle] = [
        .init(key: "assistant_enabled", title: "眼镜自带助手",
              detail: "关掉之后眼镜不会再自己应答“Hey Meta”，助手全部交给这个 app 的模型"),
        .init(key: "assistant_llm_enabled", title: "助手大模型能力",
              detail: "眼镜端的大模型问答开关"),
        .init(key: "wakeword_sound_enabled", title: "唤醒提示音",
              detail: "被唤醒时眼镜自己发出的提示音"),
        .init(key: "audio_playback_during_capture_enabled", title: "拍摄时播放声音",
              detail: "录像时是否同时播音频"),
        .init(key: "advanced_video_quality_profile", title: "高画质视频档",
              detail: "视频用更高码率的 profile，文件更大"),
        .init(key: "quick_clips_photo_capture_enabled", title: "快剪里拍照",
              detail: "短视频模式允许抓取静态图"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.toggles) { t in
                    Button {
                        let current = g.settings[t.key] ?? ""
                        let next = (current == "true") ? "false" : "true"
                        g.writeSetting(t.key, next)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title)
                                Text(t.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((g.settings[t.key] ?? "") == "true" ? "开" : "关")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle((g.settings[t.key] ?? "") == "true" ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("常用开关")
            } footer: {
                Text("点了会立刻写进眼镜并读回校验；读不到值时显示「关」。完整 370 项在「眼镜设置」里。")
            }

            Section("语音") {
                ForEach(["assistant_voice_id", "live_caption_voice_id"], id: \.self) { key in
                    HStack {
                        Text(key == "assistant_voice_id" ? "助手音色" : "字幕音色")
                        Spacer()
                        Text((g.settings[key] ?? "").isEmpty ? "—" : (g.settings[key] ?? ""))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("快捷")
        .task { if g.settings.isEmpty { g.loadSettings() } }
    }
}
