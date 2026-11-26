import SwiftUI

/// Every catalogue entry offered on Ray-Ban Meta (Gen 2), for people who know what they are changing.
/// Pushed from 眼镜设置; the curated page above it is the one meant for everyday use.
struct SettingsView: View {
    @ObservedObject var g: Glasses
    @State private var filter = ""
    @State private var editing: SettingInfo?
    @State private var draft = ""
    @State private var rangeDrafts: [String: Double] = [:]
    @State private var onlyStored = false

    private var groups: [String] {
        SettingsCatalog.groups.filter { !SettingsCatalog.otherModelGroups.contains($0) }
    }

    private func settings(in group: String) -> [SettingInfo] {
        let options = SettingsCatalog.inGroup(group).filter { $0.offeredOnGen2 && (!onlyStored || g.settings[$0.key] != nil) }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || SettingsCatalog.groupName(group).localizedCaseInsensitiveContains(query) { return options }
        return options.filter {
            $0.key.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
                || $0.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("只看眼镜里保存过的项（\(g.settings.count)）", isOn: $onlyStored)
            } footer: {
                Text("这是固件的完整设置表，名称多为原厂英文；不少项只在 Meta App 的某些功能里起作用。没有保存过的项显示出厂默认值。")
            }
            if !g.canUseGlasses {
                Text("连接眼镜并验证主人身份后可修改设置。")
                    .foregroundStyle(.secondary)
            } else if SettingsCatalog.all.isEmpty {
                Text("当前没有可用的设置目录。").foregroundStyle(.secondary)
            } else {
                ForEach(groups, id: \.self) { group in
                    let options = settings(in: group)
                    if !options.isEmpty {
                        Section(SettingsCatalog.groupName(group)) {
                            ForEach(options) { info in
                                row(info)
                            }
                        }
                        .disabled(g.settingsLoading || g.busy || g.settingsReadAt == nil)
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "搜索设置或键名")
        .navigationTitle("全部原始设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(g.settingsLoading ? "读取中…" : "重新读取") { g.loadSettings() }
                    .disabled(!g.canUseGlasses || g.settingsLoading || g.busy)
            }
        }
        .task(id: "\(g.canUseGlasses)-\(g.busy)") {
            if g.canUseGlasses, g.settingsReadAt == nil, !g.settingsLoading, !g.busy { g.loadSettings() }
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

    @ViewBuilder
    private func row(_ info: SettingInfo) -> some View {
        let current = g.settingValue(info.key)
        let raw = current.value
        switch info.control.type {
        case "toggle":
            if let raw, let on = SettingsSchemaTable.boolValue(raw) {
                Toggle(isOn: Binding(
                    get: { on },
                    set: { g.writeSetting(info.key, $0 ? "true" : "false") }
                )) {
                    label(info, value: nil, isDefault: current.isDefault)
                }
            } else {
                Menu {
                    Button("设为开启") { g.writeSetting(info.key, "true") }
                    Button("设为关闭") { g.writeSetting(info.key, "false") }
                } label: {
                    label(info, value: "未知", isDefault: false)
                }
            }
        case "choice":
            Menu {
                ForEach((info.control.options ?? []).filter(\.offeredOnGen2)) { option in
                    Button(option.display) { g.writeSetting(info.key, option.value) }
                }
            } label: {
                HStack {
                    label(info, value: SettingsCatalog.shown(info, raw), isDefault: current.isDefault)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
        case "range":
            let minimum = info.control.min ?? 0
            let maximum = info.control.max ?? 1
            let step = info.control.step ?? 0.1
            VStack(alignment: .leading, spacing: 4) {
                label(info, value: rangeDrafts[info.key].map { String(format: "%g", $0) } ?? SettingsCatalog.shown(info, raw),
                      isDefault: current.isDefault)
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
        case "text", "number":
            Button {
                draft = raw ?? ""
                editing = info
            } label: {
                label(info, value: raw.map { $0.isEmpty ? "—" : $0 }, isDefault: current.isDefault)
            }
        default:
            label(info, value: SettingsCatalog.shown(info, raw), isDefault: current.isDefault)
        }
    }

    private func label(_ info: SettingInfo, value: String?, isDefault: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(info.name)
                if g.settingsWriting == info.key { ProgressView().controlSize(.mini) }
                Spacer()
                if let value {
                    Text(isDefault ? "\(value)（默认）" : value).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let detail = info.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(info.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}
