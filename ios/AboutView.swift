import SwiftUI

/// Legal surface. The app ships three data files that come from Visor (AGPL-3.0):
/// the settings catalogue, its UI copy, and the assistant's VARM template.
/// Distributing this build therefore has to carry the licence and a source pointer.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let repo = "https://github.com/vigohan95/glasseslink"

    var body: some View {
        NavigationStack {
            List {
                Section("这个 app 是什么") {
                    Text("Ray-Ban Meta (Gen 2) 的独立客户端：不经 Meta 云端，直接和眼镜说 DataX/AirShield。照片、设置、取景、助手都走本地链路。")
                        .font(.footnote)
                }
                Section("第三方许可") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Visor — AGPL-3.0").font(.subheadline).bold()
                        Text("捆绑的三份数据文件来自 Visor：settings.tsv（眼镜设置表）、settings_ui.json（设置的中文文案）、varm_template.bin（助手语音回答模板）。源代码在仓库的 ios/Resources 下，按 AGPL-3.0 提供。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Link("Visor 源码", destination: URL(string: "https://github.com/macedonga/visor")!)
                    Link("完整的 AGPL-3.0 文本", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.txt")!)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("sherpa-onnx、Kokoro-82M v1.1-zh — Apache-2.0").font(.subheadline).bold()
                        Text("内置的中文 AI 语音：sherpa-onnx（k2-fsa）在手机上运行 Kokoro v1.1-zh 模型（hexgrad），全程离线。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Link("sherpa-onnx 源码", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!)
                    Link("Kokoro-82M v1.1-zh", destination: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh")!)
                }
                Section("本项目的源码") {
                    Link(repo, destination: URL(string: repo)!)
                    Text("按 AGPL-3.0 分发：如果你把这个 app 发给别人，需要同时提供对应源码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("隐私") {
                    Text("没有账号、没有遥测、没有服务器。唯一的网络请求是你自己填的模型地址（例如本机的 Ollama），以及你主动发起的 Meta 登录（仅用于把眼镜的主人改成这台手机）。")
                        .font(.footnote)
                }
            }
            .navigationTitle("关于")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
