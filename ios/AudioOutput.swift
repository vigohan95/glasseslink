import AVKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.accessibilityLabel = "选择媒体音频输出"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = .label
        picker.activeTintColor = .systemTeal
    }
}

enum GlassesAudioInput {
    static func isWirelessMicrophone(_ port: AVAudioSessionPortDescription) -> Bool {
        port.portType == .bluetoothHFP || port.portType == .bluetoothLE
    }

    static func normalizedName(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
            .replacingOccurrences(of: "raybanmeta", with: "rbmeta")
    }

    static func label(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .bluetoothHFP: return "\(port.portName) · HFP"
        case .bluetoothLE: return "\(port.portName) · LE 音频"
        default: return port.portName
        }
    }
}

struct AudioPortInfo: Equatable {
    let type: AVAudioSession.Port
    let name: String
}

/// Whether iOS can use the glasses as a headset. Only a system Bluetooth pairing makes that true;
/// the app's own data link never does (0.99's bridging reconnect could not create one).
enum GlassesAudioState: Equatable {
    case glasses(profile: String)
    case otherBluetooth(name: String)
    case unavailable

    static func from(outputs: [AudioPortInfo], inputs: [AudioPortInfo], glassesNames: [String]) -> GlassesAudioState {
        let wanted = Set(glassesNames.map(GlassesAudioInput.normalizedName))
        func isGlasses(_ port: AudioPortInfo) -> Bool {
            ScanEntry.matchesRayBanMetaName(port.name) || wanted.contains(GlassesAudioInput.normalizedName(port.name))
        }
        let wirelessOut = outputs.filter { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.type) }
        if let port = wirelessOut.first(where: isGlasses) {
            switch port.type {
            case .bluetoothA2DP: return .glasses(profile: "蓝牙立体声 · A2DP")
            case .bluetoothLE: return .glasses(profile: "蓝牙 LE 音频")
            default: return .glasses(profile: "蓝牙通话模式 · HFP")
            }
        }
        if inputs.contains(where: { [.bluetoothHFP, .bluetoothLE].contains($0.type) && isGlasses($0) }) {
            return .glasses(profile: "眼镜麦克风可用")
        }
        if let other = wirelessOut.first { return .otherBluetooth(name: other.name) }
        return .unavailable
    }
}

@MainActor
final class AudioRouteTest: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?

    private let session = AVAudioSession.sharedInstance()
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var player: AVAudioPlayer?
    private var activated = false
    private var stopTask: Task<Void, Never>?

    func start(onRouteChange: @escaping () -> Void) {
        guard !isPlaying else { return }
        error = nil
        do {
            let tone = try AVAudioPlayer(data: Self.chime())
            previous = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
            activated = true
            tone.numberOfLoops = -1
            guard tone.play() else { throw PlaybackError.couldNotStart }
            player = tone
            isPlaying = true
            onRouteChange()
            stopTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.stop()
                onRouteChange()
            }
        } catch {
            stop()
            self.error = "播放测试音失败。\(error.localizedDescription)"
            onRouteChange()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        if activated { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        if let (category, mode, options) = previous {
            try? session.setCategory(category, mode: mode, options: options)
        }
        activated = false
        previous = nil
        isPlaying = false
    }

    private enum PlaybackError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "iPhone 未启动测试音播放。" }
    }

    private static func chime() -> Data {
        let sampleRate = 16_000
        let sampleCount = 2 * sampleRate
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        var wave = Data("RIFF".utf8)
        wave.reserveCapacity(44 + byteCount)

        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wave.append(contentsOf: $0) }
        }

        append(UInt32(36 + byteCount))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)) // PCM format block length
        append(UInt16(1))  // Linear PCM
        append(UInt16(1))  // Mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        wave.append(contentsOf: "data".utf8)
        append(UInt32(byteCount))
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let envelope = max(0, min(1, min(time * 50, (0.35 - time) * 12)))
            let sample = sin(2 * .pi * 520 * time) * (envelope * 4_800)
            append(Int16(sample))
        }
        return wave
    }
}
