import SwiftUI

struct QuickPanel: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: Double] = [:]

    var body: some View {
        List {
            if !g.canUseGlasses {
                Text("连接眼镜并验证主人身份后可读取设置。")
                    .foregroundStyle(.secondary)
            } else {
                Section("音量与指示灯") {
                    settingSlider("提示音量", key: "notification_volume", range: 0 ... 100, step: 5)
                    settingSlider("指示灯亮度", key: "notification_led_brightness", range: 0 ... 5, step: 1)
                }
                Section("声音") {
                    settingToggle("唤醒提示音", key: "wakeword_sound_enabled")
                    settingToggle("拍摄时播放声音", key: "audio_playback_during_capture_enabled")
                }
            }
        }
        .navigationTitle("常用设置")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(g.settingsLoading ? "读取中…" : "读取") { g.loadSettings() }
                    .disabled(!g.canUseGlasses || g.settingsLoading || g.busy)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
        .task(id: g.canUseGlasses) {
            if g.canUseGlasses && g.settings.isEmpty && !g.settingsLoading && !g.busy {
                g.loadSettings()
            }
        }
    }

    @ViewBuilder
    private func settingToggle(_ title: String, key: String) -> some View {
        if let raw = g.settings[key], raw == "true" || raw == "false" {
            Toggle(title, isOn: Binding(
                get: { g.settings[key] == "true" },
                set: { g.writeSetting(key, $0 ? "true" : "false") }
            ))
            .disabled(g.settingsLoading || g.busy)
        } else {
            LabeledContent(title, value: "未读取")
        }
    }

    @ViewBuilder
    private func settingSlider(_ title: String, key: String, range: ClosedRange<Double>, step: Double) -> some View {
        if let raw = g.settings[key], let value = Double(raw), range.contains(value) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(title, value: "\(Int((drafts[key] ?? value).rounded()))")
                Slider(value: Binding(
                    get: { drafts[key] ?? value },
                    set: { drafts[key] = $0 }
                ), in: range, step: step, onEditingChanged: { editing in
                    if !editing, let draft = drafts.removeValue(forKey: key),
                       g.canUseGlasses, !g.settingsLoading, !g.busy {
                        g.writeSetting(key, String(Int(draft.rounded())))
                    }
                })
                .accessibilityLabel(Text(title))
                .disabled(g.settingsLoading || g.busy)
            }
        } else {
            LabeledContent(title, value: "未读取")
        }
    }
}
