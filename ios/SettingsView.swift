import SwiftUI

struct SettingsView: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var editing: SettingInfo?
    @State private var draft = ""
    @State private var rangeDrafts: [String: Double] = [:]

    private func settings(in group: String) -> [SettingInfo] {
        let options = SettingsCatalog.inGroup(group)
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || group.localizedCaseInsensitiveContains(query) { return options }
        return options.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !g.canUseGlasses {
                    Text("连接眼镜并验证主人身份后可修改设置。")
                        .foregroundStyle(.secondary)
                } else if SettingsCatalog.all.isEmpty {
                    Text("当前没有可用的设置目录。").foregroundStyle(.secondary)
                } else {
                    ForEach(SettingsCatalog.groups, id: \.self) { group in
                        let options = settings(in: group)
                        if !options.isEmpty {
                            Section(group) {
                                ForEach(options) { info in
                                    row(info)
                                }
                            }
                            .disabled(g.settingsLoading || g.busy)
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "搜索设置")
            .navigationTitle("高级眼镜设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(g.settingsLoading ? "读取中…" : "读取") { g.loadSettings() }
                        .disabled(!g.canUseGlasses || g.settingsLoading || g.busy)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("修改 \(editing?.name ?? "")", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("值", text: $draft)
                Button("写入") {
                    if g.canUseGlasses, let info = editing { g.writeSetting(info.key, draft) }
                    editing = nil
                }
                Button("取消", role: .cancel) { editing = nil }
            } message: {
                Text(editing?.detail ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(_ info: SettingInfo) -> some View {
        let raw = g.settings[info.key]
        switch info.control.type {
        case "toggle":
            if let raw, raw == "true" || raw == "false" {
                Toggle(isOn: Binding(
                    get: { g.settings[info.key] == "true" },
                    set: { g.writeSetting(info.key, $0 ? "true" : "false") }
                )) {
                    label(info, value: nil)
                }
            } else {
                Menu {
                    Button("设为开启") { g.writeSetting(info.key, "true") }
                    Button("设为关闭") { g.writeSetting(info.key, "false") }
                } label: {
                    label(info, value: "未读取")
                }
            }
        case "choice":
            Menu {
                ForEach(info.control.options ?? []) { option in
                    Button(option.display) { g.writeSetting(info.key, option.value) }
                }
            } label: {
                HStack {
                    label(info, value: SettingsCatalog.shown(info, raw))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
        case "range":
            let minimum = info.control.min ?? 0
            let maximum = info.control.max ?? 1
            let step = info.control.step ?? 0.1
            VStack(alignment: .leading, spacing: 4) {
                label(info, value: rangeDrafts[info.key].map { String(format: "%g", $0) } ?? SettingsCatalog.shown(info, raw))
                if let raw, let value = Double(raw), minimum < maximum, step > 0,
                   (minimum ... maximum).contains(value) {
                    Slider(value: Binding(
                        get: { rangeDrafts[info.key] ?? value },
                        set: { rangeDrafts[info.key] = $0 }
                    ), in: minimum ... maximum, step: step, onEditingChanged: { isEditing in
                        if !isEditing, let value = rangeDrafts.removeValue(forKey: info.key), g.canUseGlasses {
                            g.writeSetting(info.key, String(format: "%g", value))
                        }
                    })
                    .accessibilityLabel(Text(info.name))
                }
            }
        case "text":
            Button {
                draft = raw ?? ""
                editing = info
            } label: {
                label(info, value: raw.map { $0.isEmpty ? "—" : $0 })
            }
        default:
            label(info, value: SettingsCatalog.shown(info, raw))
        }
    }

    private func label(_ info: SettingInfo, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(info.name)
                Spacer()
                if let value {
                    Text(value).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let detail = info.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(info.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}
