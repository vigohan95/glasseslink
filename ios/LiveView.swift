import AVFoundation
import SwiftUI
import UIKit

/// Hosts the display layer the live frames are enqueued into.
struct LiveLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspect
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        CATransaction.commit()
    }
}

struct LiveView: View {
    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let live = g.live {
                    LiveLayerView(layer: live.layer)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            Text(g.liveLine)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(6)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .overlay(Text("未开始").foregroundStyle(.secondary).font(.footnote))
                }

                HStack(spacing: 10) {
                    if g.live == nil {
                        Button("开始取景") { g.startLive() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!g.canUseGlasses || g.busy)
                    } else {
                        Button("停止") { g.stopLive() }
                            .buttonStyle(.bordered)
                        Button("抓取取景画面") { g.live?.requestPhoto() }
                            .disabled(!g.canUseGlasses || g.busy)
                            .buttonStyle(.bordered)
                    }
                }

                Text("通过蓝牙验证眼镜的实时取景。开始前请连接眼镜并验证主人身份。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let err = g.live?.lastError {
                    Text("错误：\(err)").font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("实时取景（实验）")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .onDisappear { g.stopLive() }
        }
    }
}
