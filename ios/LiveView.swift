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
                            .disabled(!g.connected)
                    } else {
                        Button("停止") { g.stopLive() }
                            .buttonStyle(.bordered)
                        Button("拍一张") { g.live?.requestPhoto() }
                            .buttonStyle(.bordered)
                    }
                }

                Text("iPhone 没有 Wi-Fi Direct，取景走蓝牙：360×640、十几个 fps，够看取景和抓拍，"
                     + "当监视器不行。取景期间其他读眼镜的操作会排队。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let err = g.live?.lastError {
                    Text("错误：\(err)").font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Live 取景")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .onDisappear { g.stopLive() }
        }
    }
}
