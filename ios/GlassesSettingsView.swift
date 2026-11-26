import SwiftUI

/// One setting Ray-Ban Meta (Gen 2) really has and the phone can change, in plain Chinese.
/// The keys and option values come from Visor's curated topics and settings_ui.json; the words are ours.
struct CuratedSetting: Identifiable {
    enum Control {
        case toggle
        case choice([CuratedOption])
        /// A raw integer range shown to people as 0–100 %.
        case percent(min: Double, max: Double)
    }

    let key: String
    let title: String
    let note: String
    let control: Control
    var id: String { key }
}

struct CuratedOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

extension CuratedSetting.Control {
    /// Options in the order written; a dictionary literal would lose it.
    static func options(_ pairs: KeyValuePairs<String, String>) -> Self {
        .choice(pairs.map { CuratedOption(value: $0.key, label: $0.value) })
    }
}

struct CuratedSection: Identifiable {
    let title: String
    let icon: String
    let items: [CuratedSetting]
    var id: String { title }
}

enum CuratedSettings {
    /// Only what passes three tests: the firmware reads it (settings.tsv marks the svc31 field as parsed,
    /// or the catalogue's code note says so), its effect is on the glasses themselves, and it does not
    /// depend on the Meta app or Meta's cloud. Location, cloud processing, stored voice records and the
    /// notification timing switches fail the last test and were dropped; docs/SETTINGS-GEN2.md has the
    /// reasoning per setting.
    static let sections: [CuratedSection] = [
        CuratedSection(title: "Hey Meta 与语音", icon: "waveform", items: [
            CuratedSetting(key: "assistant_enabled", title: "语音助手",
                           note: "关闭后眼镜不再响应「Hey Meta」，GlassesLink 也就收不到提问。", control: .toggle),
            CuratedSetting(key: "wakeword_enabled", title: "「Hey Meta」唤醒",
                           note: "说「Hey Meta」开始一条语音指令。", control: .toggle),
            CuratedSetting(key: "wakeword_sound_enabled", title: "唤醒提示音",
                           note: "说完「Hey Meta」后眼镜会响一声，表示在听。", control: .toggle),
            CuratedSetting(key: "assistant_follow_up_enabled", title: "免唤醒追问",
                           note: "回答结束后麦克风再听一小会儿，接着问不用再说「Hey Meta」。", control: .toggle),
            CuratedSetting(key: "assistant_voice_id", title: "眼镜自带的声音",
                           note: "眼镜用自己的声音读英文回答时用哪个声音，就是 Meta AI 的声音。眼镜没有中文声音，中文回答由 iPhone 读，见上面的「回答的声音」。名人声音是 Meta 提供的 AI 声音，眼镜里没有装的话可能读不出来，那时换回「出厂默认」。",
                           control: .options(["en_US.58": "出厂默认", "en_US.mai_01": "Aria", "en_US.mai_03": "Helio",
                                             "en_US.60": "Awkwafina（AI 声音）", "en_US.pf06": "Deepika Padukone（AI 声音）",
                                             "en_US.pf02": "Judi Dench（AI 声音）", "en_US.62": "Kristen Bell（AI 声音）",
                                             "en_US.63": "John Cena（AI 声音）",
                                             "en_US.61": "Keegan-Michael Key（AI 声音）"])),
            CuratedSetting(key: "tts_speak_speed", title: "眼镜朗读语速",
                           note: "眼镜用自己的声音朗读时的速度；中文回答由 iPhone 合成，不受它影响。",
                           control: .options(["75": "0.75 倍", "100": "1 倍", "125": "1.25 倍",
                                             "150": "1.5 倍", "175": "1.75 倍"])),
        ]),
        CuratedSection(title: "拍摄", icon: "camera", items: [
            CuratedSetting(key: "capture_button_short_long_press", title: "拍摄键",
                           note: "拍摄键单按和长按分别做什么。",
                           control: .options(["0": "单按拍照，长按录像", "1": "单按录像，长按拍照"])),
            CuratedSetting(key: "resolution_and_framerate", title: "视频画质",
                           note: "画质越高越耗电、越占空间；高帧率每帧曝光更短，室内噪点会更多。",
                           control: .options(["0": "标准 · 1080p 30 帧", "2": "高帧率 · 1080p 60 帧",
                                             "1": "高分辨率 · 3K 30 帧"])),
            CuratedSetting(key: "video_duration_ms", title: "单段视频最长",
                           note: "录到这个时长自动停止。这是官方给的几档；过热和电量由眼镜另外的保护机制管。",
                           control: .options(["30000": "30 秒", "60000": "1 分钟", "180000": "3 分钟",
                                             "300000": "5 分钟（仅标准画质）", "600000": "10 分钟"])),
            CuratedSetting(key: "eis_mode", title: "视频防抖",
                           note: "中（默认）：防抖并校正水平；强：画面最平稳；弱：保留动作感；自动：按画面运动自己选。",
                           control: .options(["0": "自动", "1": "强", "2": "中", "3": "弱"])),
            CuratedSetting(key: "flicker_reduction_mode", title: "灯光防闪烁",
                           note: "室内灯光下视频出现明暗条纹或闪烁时，按当地电网频率选：中国大陆、香港是 50 Hz，台湾、美国是 60 Hz。",
                           control: .options(["0": "自动", "50": "50 Hz", "60": "60 Hz"])),
            CuratedSetting(key: "motion_blur_reduction_enabled", title: "减少运动模糊",
                           note: "录像时减少快速移动造成的拖影。", control: .toggle),
            CuratedSetting(key: "occlusion_detection_enabled", title: "镜头遮挡提醒",
                           note: "头发或帽檐挡住镜头时提醒你。", control: .toggle),
            CuratedSetting(key: "music_concurrency_enabled", title: "录像时继续放音乐",
                           note: "录像时不暂停音乐；音乐声可能会被录进视频。", control: .toggle),
        ]),
        CuratedSection(title: "声音", icon: "speaker.wave.2", items: [
            CuratedSetting(key: "notification_volume", title: "提示音音量",
                           note: "眼镜提示音的音量，不影响音乐和通话。", control: .percent(min: 55, max: 127)),
            CuratedSetting(key: "avc_enabled", title: "自适应音量",
                           note: "根据周围噪音自动调整眼镜音量。", control: .toggle),
            CuratedSetting(key: "mono_audio_enabled", title: "单声道",
                           note: "左右两边的扬声器播放同样的声音。", control: .toggle),
        ]),
        CuratedSection(title: "佩戴与触控", icon: "hand.tap", items: [
            CuratedSetting(key: "wear_detection_enabled", title: "佩戴检测",
                           note: "摘下眼镜时暂停功能，戴上后恢复。", control: .toggle),
            CuratedSetting(key: "auto_play_pause_on_don_doff", title: "摘下时暂停音乐",
                           note: "摘下眼镜时音乐自动暂停，戴上后继续。", control: .toggle),
            CuratedSetting(key: "tap_and_hold_mapping", title: "触控板长按",
                           note: "手指按住镜腿触控板时做什么。其他选项要靠 Meta App 绑定音乐服务，这里不列。",
                           control: .options(["1": "不做任何事", "2": "唤醒语音助手"])),
            CuratedSetting(key: "sg_captouch_invert_swipe_direction_horizontal", title: "反转前后滑动",
                           note: "触控板前后滑动调音量的方向反过来。", control: .toggle),
        ]),
        CuratedSection(title: "来电", icon: "phone", items: [
            CuratedSetting(key: "user_setup_ica_toggle_enabled", title: "来电播报",
                           note: "来电时眼镜读出是谁打来的。", control: .toggle),
            CuratedSetting(key: "sg_do_not_disturb", title: "勿扰模式",
                           note: "开启后眼镜不响来电铃声。", control: .toggle),
        ]),
        CuratedSection(title: "固件更新", icon: "arrow.down.circle", items: [
            CuratedSetting(key: "cloud_ota_enabled", title: "自动固件更新",
                           note: "允许眼镜自己从云端下载新固件。新固件可能让 GlassesLink 失效，建议关闭。",
                           control: .toggle),
        ]),
    ]

    static var all: [CuratedSetting] { sections.flatMap(\.items) }

    /// The label for a stored value, or a plain "其他" for one the list does not name.
    static func label(_ item: CuratedSetting, _ raw: String?) -> String {
        guard let raw else { return "未知" }
        switch item.control {
        case .toggle:
            return SettingsSchemaTable.boolValue(raw).map { $0 ? "开" : "关" } ?? raw
        case .choice(let options):
            return options.first { SettingsSchemaTable.same(kind: "int", raw, $0.value) || raw == $0.value }?.label
                ?? "其他（\(raw)）"
        case .percent(let minimum, let maximum):
            guard let value = Double(raw) else { return raw }
            return "\(percent(value, minimum, maximum))%"
        }
    }

    static func percent(_ value: Double, _ minimum: Double, _ maximum: Double) -> Int {
        guard maximum > minimum else { return 0 }
        return Int(((min(max(value, minimum), maximum) - minimum) / (maximum - minimum) * 100).rounded())
    }
}

/// Which installed voice reads the answers in one language, and a way to hear it before the glasses do.
private struct AnswerVoiceRows: View {
    @ObservedObject var g: Glasses
    let title: String
    let tag: String
    @State private var chosen = ""
    @State private var choices: [PhoneVoice.Choice] = []

    var body: some View {
        Picker(title, selection: $chosen) {
            Text("自动（音质最好的女声）").tag("")
            ForEach(choices) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
        .task(id: tag) {
            choices = PhoneVoice.choices(for: tag)
            chosen = PhoneVoice.chosenIdentifier(for: tag)
        }
        .onChange(of: chosen) { _, picked in
            PhoneVoice.choose(picked, for: tag)
        }
        Button {
            Haptics.tap()
            g.previewAnswerVoice(tag)
        } label: {
            Label("试听\(title)", systemImage: "play.circle")
        }
    }
}

/// The settings page on the 眼镜 tab: what the glasses really have, read from them, in Chinese.
struct GlassesSettingsView: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss
    @State private var percentDrafts: [String: Double] = [:]
    @AppStorage(PhotoLeveling.enabledKey) private var levelPhotos = true
    @AppStorage(VideoLeveling.enabledKey) private var levelVideos = true
    @AppStorage(HeyMetaLanguage.key) private var heyMetaLanguage = HeyMetaLanguage.defaultTag

    private var ready: Bool { g.canUseGlasses && g.settingsReadAt != nil }

    /// Unverified lengths offered only as an experiment, away from the proven list.
    private static let longerVideoMinutes = [15, 20, 30]

    var body: some View {
        List {
            statusSection
            Section {
                Picker("提问语言", selection: $heyMetaLanguage) {
                    ForEach(HeyMetaLanguage.choices) { choice in
                        Text(choice.name).tag(choice.tag)
                    }
                }
                if heyMetaLanguage != HeyMetaLanguage.glasses {
                    AnswerVoiceRows(g: g, title: "回答的声音", tag: heyMetaLanguage)
                }
            } header: {
                Label("Hey Meta 用什么语言问", systemImage: "character.bubble")
            } footer: {
                Text("眼镜只听得懂、也只会读它自己设置的语言（多数是英文）。这种语言的问题照旧由眼镜自己识别，回答用眼镜自带的声音。选了别的语言（比如普通话）时，你的话会传到 iPhone 上识别；回答眼镜读不了，由 iPhone 的声音读出来，从眼镜里播放。首次使用会请求「语音识别」权限，iPhone 的「听写」也要开着（设置 › 通用 › 键盘）。\n\niPhone 自带的「标准音质」声音比较机械。想要好听的女声不用花钱：到 iPhone「设置 › 辅助功能 › 朗读内容 › 声音」，进你选的语言，点一个女声旁边的下载，选「高音质」（没有就选「优化音质」）。下载完回到这里，它会出现在列表里，「自动」也会改用它。")
            }
            ForEach(CuratedSettings.sections) { section in
                Section {
                    ForEach(section.items) { item in row(item) }
                } header: {
                    Label(section.title, systemImage: section.icon)
                }
                .disabled(!ready || g.settingsLoading || g.busy)
            }
            Section {
                Toggle(isOn: $levelPhotos) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("照片自动摆正")
                        Text("戴着眼镜头一歪，照片就斜。导入时 iPhone 会找画面里的水平线，把存进 iPhone 相册的那份转正并裁掉斜边；App 里的原件不动。歪得太厉害（超过 12°）或画面里找不到水平线时不处理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $levelVideos) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("视频自动摆正")
                        Text("眼镜的防抖只管抖，不管歪。导入时会一并取回眼镜随视频记录的陀螺仪数据，算出每一刻头歪了多少，把存进 iPhone 相册的那份逐帧转正；最多修正 8°，明显是故意歪头的不修。导入会因此多花一点时间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("导入到 iPhone 相册时", systemImage: "level")
            } footer: {
                Text("App 里保留的始终是原件；关掉开关后重新存到相册，得到的就是未处理的原样。")
            }
            Section {
                ForEach(Self.longerVideoMinutes, id: \.self) { minutes in
                    Button("把单段视频上限设为 \(minutes) 分钟") {
                        g.writeSetting("video_duration_ms", String(minutes * 60_000))
                    }
                }
            } header: {
                Label("实验：更长的录像", systemImage: "flask")
            } footer: {
                Text("官方最多给到 10 分钟。固件里另有一种拍摄模式的上限是 30 分钟，所以硬件录得了更久，但普通录像认不认更大的值还没有验证。帮我试一次：点一个时长，显示「已保存」后录一段直到它自己停，把实际录了多久告诉我。眼镜过热或电量低时会自己停止，这是它的保护，不受这里影响。")
            }
            .disabled(!ready || g.settingsLoading || g.busy)
            Section {
                NavigationLink("全部原始设置（开发者）") { SettingsView(g: g) }
            } footer: {
                Text("原始列表是眼镜固件里的全部设置项，许多只对其他型号有效，名称多为原厂英文。")
            }
        }
        .navigationTitle("眼镜设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
        // Keyed on busy too: opened while Hey Meta registers, the read starts as soon as the link is free.
        .task(id: "\(g.canUseGlasses)-\(g.busy)") {
            if g.canUseGlasses, g.settingsReadAt == nil, !g.settingsLoading, !g.busy { g.loadSettings() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if !g.canUseGlasses {
                Label("连接眼镜并验证主人身份后才能读取和修改。", systemImage: "eyeglasses")
                    .foregroundStyle(.secondary)
            } else if g.settingsReadAt == nil {
                HStack(spacing: 10) {
                    if g.settingsLoading { ProgressView() }
                    Text(g.settingsLoading ? "正在从眼镜读取设置…" : (g.settingsMessage ?? "还没有读取眼镜设置。"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !g.settingsLoading {
                        Button("读取") { g.loadSettings() }.disabled(g.busy)
                    }
                }
            } else if g.settingsLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(g.settingsWriting == nil ? "正在重新读取…" : "正在写入并核对…").foregroundStyle(.secondary)
                }
            } else if let message = g.settingsMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } footer: {
            Text("这里只列出 Ray-Ban Meta 第二代上确实存在、能从手机修改的设置。改动会写入眼镜，再读回确认后才算生效。标「默认」的项表示眼镜里没有单独保存过，显示的是出厂默认值。")
        }
    }

    @ViewBuilder
    private func row(_ item: CuratedSetting) -> some View {
        let current = g.settingValue(item.key)
        let writing = g.settingsWriting == item.key
        VStack(alignment: .leading, spacing: 4) {
            switch item.control {
            case .toggle:
                Toggle(isOn: Binding(
                    get: { current.value.flatMap(SettingsSchemaTable.boolValue) ?? false },
                    set: { g.writeSetting(item.key, $0 ? "true" : "false") }
                )) {
                    title(item, isDefault: current.isDefault, writing: writing)
                }
            case .choice(let options):
                Menu {
                    ForEach(options) { option in
                        Button(option.label) { g.writeSetting(item.key, option.value) }
                    }
                } label: {
                    HStack {
                        title(item, isDefault: current.isDefault, writing: writing)
                        Spacer(minLength: 8)
                        Text(CuratedSettings.label(item, current.value)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
            case .percent(let minimum, let maximum):
                let stored = current.value.flatMap { Double($0) } ?? minimum
                let shown = percentDrafts[item.key] ?? stored
                HStack {
                    title(item, isDefault: current.isDefault, writing: writing)
                    Spacer()
                    Text("\(CuratedSettings.percent(shown, minimum, maximum))%").foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { percentDrafts[item.key] ?? stored },
                    set: { percentDrafts[item.key] = $0 }
                ), in: minimum ... maximum, step: 1, onEditingChanged: { editing in
                    if !editing, let draft = percentDrafts.removeValue(forKey: item.key) {
                        g.writeSetting(item.key, String(Int(draft.rounded())))
                    }
                })
                .accessibilityLabel(Text(item.title))
            }
            Text(item.note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func title(_ item: CuratedSetting, isDefault: Bool, writing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
            if writing {
                ProgressView().controlSize(.mini)
            } else if isDefault {
                Text("默认")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
