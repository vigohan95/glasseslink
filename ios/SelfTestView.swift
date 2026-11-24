import SwiftUI

/// The self-test used to write only into the log list, which is easy to miss on a
/// first run (people tap the button, see nothing, and assume it did not work).
/// This puts the same lines in a sheet with a "copy" action.
struct SelfTestView: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss

    private var report: String {
        g.selfTestLines.map { "\($0.ok ? "✓" : "✗") \($0.text)" }.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(g.selfTestBad == 0
                         ? "全部通过（\(g.selfTestLines.count) 项）"
                         : "有 \(g.selfTestBad) 项失败（共 \(g.selfTestLines.count) 项）")
                        .font(.headline)
                        .foregroundStyle(g.selfTestBad == 0 ? .green : .orange)

                    ForEach(Array(g.selfTestLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.ok ? "✓" : "✗")
                                .foregroundStyle(line.ok ? .green : .red)
                                .frame(width: 16, alignment: .leading)
                            Text(line.text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    Text("「Security 可导入私钥」为 ✗ 属正常：这台系统不允许导入独立 EC 私钥，签名会走 app 内的 P-256 实现。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("自检结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") { UIPasteboard.general.string = report }
                }
            }
        }
    }
}
