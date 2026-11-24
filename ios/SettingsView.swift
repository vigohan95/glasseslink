import SwiftUI

/// The glasses' own settings, read straight out of svc33 and written back the way another
/// replica would: present a newer version, then read it back.
struct SettingsView: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var editing: SettingInfo?
    @State private var draft = ""

    private var groups: [String] {
        guard !filter.isEmpty else { return SettingsCatalog.groups }
        let needle = filter.lowercased()
        return SettingsCatalog.groups.filter { group in
            group.lowercased().contains(needle) || SettingsCatalog.inGroup(group).contains {
                $0.key.contains(needle) || $0.name.lowercased().contains(needle)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if SettingsCatalog.all.isEmpty {
                    Text("settings_ui.json 没有打进 app 包里").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(SettingsCatalog.inGroup(group)) { info in
                            row(info)
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "搜索设置")
            .navigationTitle("眼镜设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(g.settingsLoading ? "读取中…" : "读取") { g.loadSettings() }
                        .disabled(g.settingsLoading || !g.connected)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("修改 \(editing?.name ?? "")", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("值", text: $draft)
                Button("写入") {
                    if let info = editing { g.writeSetting(info.key, draft) }
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
            // A value the glasses never reported must not look like "off" — that is how Visor
            // left people staring at locked-looking switches. Say we don't know, still allow a write.
            Toggle(isOn: Binding(
                get: { raw == "true" },
                set: { g.writeSetting(info.key, $0 ? "true" : "false") }
            )) {
                label(info, value: raw == nil ? "未读取" : nil)
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
            VStack(alignment: .leading, spacing: 4) {
                label(info, value: SettingsCatalog.shown(info, raw))
                Slider(value: Binding(
                    get: { Double(raw ?? "") ?? info.control.min ?? 0 },
                    set: { g.writeSetting(info.key, String(format: "%g", $0)) }
                ), in: (info.control.min ?? 0) ... (info.control.max ?? 1),
                   step: info.control.step ?? 0.1)
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
