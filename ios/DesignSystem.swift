import SwiftUI
import UIKit

// MARK: - 主题

/// One visual language for every screen: a grouped page, flat cards, one accent colour.
enum GlassesTheme {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// A quiet fill for tracks, placeholders and disabled controls that sit on a card.
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.39, green: 0.88, blue: 0.85, alpha: 1)
            : UIColor(red: 0.00, green: 0.36, blue: 0.39, alpha: 1)
    })
    /// Text and symbols drawn on top of the accent: the accent is dark in light mode and bright in dark mode.
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.02, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })

    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16

    static var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
    }

    static var control: RoundedRectangle {
        RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
    }
}

extension View {
    /// A flat card on the page: surface colour, 16 pt continuous corners, content leading-aligned.
    func glassesCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassesTheme.surface, in: GlassesTheme.card)
    }

    /// The page colour behind a tab's scrolling content.
    func glassesPage() -> some View {
        background(GlassesTheme.page.ignoresSafeArea())
    }
}

/// A light tap in the hand when a control is pressed; results use `Glasses.showToast`.
enum Haptics {
    @MainActor
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - 按钮样式

/// The one obvious action on a card.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? GlassesTheme.onAccent : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isEnabled ? GlassesTheme.accent : GlassesTheme.fill, in: GlassesTheme.control)
            .contentShape(GlassesTheme.control)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A quieter action next to, or instead of, the primary one.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = GlassesTheme.accent
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, tint: tint, fillsWidth: fillsWidth)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 46)
            .background((isEnabled ? tint : Color.secondary).opacity(0.12), in: GlassesTheme.control)
            .contentShape(GlassesTheme.control)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A whole row or card that reacts to the finger.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.4)
    }
}

/// A tile (quick action, thumbnail, shutter) that presses in slightly.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileButtonBody(configuration: configuration)
    }
}

private struct TileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 小组件

/// The link state in two or three characters, shown beside a page title.
struct StatePill: View {
    enum Tone { case good, busy, attention, idle }

    let text: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .good: return Color.green
        case .busy: return GlassesTheme.accent
        case .attention: return Color.orange
        case .idle: return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if tone == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tone == .idle ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("眼镜状态，\(text)")
    }
}

/// A thin level bar under a number (battery, storage, transfer).
struct ThinBar: View {
    let fraction: Double?
    var tint: Color = GlassesTheme.accent

    private var clamped: CGFloat {
        guard let fraction, fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        Capsule()
            .fill(GlassesTheme.fill)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A small ring for one item's transfer; spins until the first bytes are counted.
struct ProgressRing: View {
    let fraction: Double

    private var clamped: CGFloat {
        guard fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        ZStack {
            if clamped > 0 {
                Circle().stroke(GlassesTheme.fill, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(GlassesTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// One row of a card that leads somewhere: icon, title, a line of state, a chevron.
struct CardRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(GlassesTheme.accent)
                .frame(width: 32, height: 32)
                .background(GlassesTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The hairline between two `CardRow`s, starting where the titles start.
struct CardRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 62)
    }
}

/// One choice in a row of filters.
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? GlassesTheme.onAccent : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? GlassesTheme.accent : GlassesTheme.surface, in: Capsule())
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shown on 相册、拍摄 when the glasses cannot be used yet: says why and leads to the 眼镜 tab.
struct ConnectHintCard: View {
    @ObservedObject var g: Glasses
    let purpose: String
    let openDevice: () -> Void

    private var title: String {
        if g.phaseBusy { return "正在连接眼镜…" }
        return g.connected ? "还没验证主人身份" : "眼镜未连接"
    }

    private var buttonTitle: String {
        if g.phaseBusy { return "查看连接进度" }
        return g.connected ? "去验证" : "去连接"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eyeglasses")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(purpose)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button(buttonTitle, action: openDevice)
                .buttonStyle(SecondaryButtonStyle())
        }
        .glassesCard()
    }
}

// MARK: - 结果提示

/// The one place results are announced: a capsule at the top that slides in, stays about 2.5 s and
/// can be tapped away. Hosted at the root, and again inside sheets that would otherwise cover it.
struct ToastOverlay: View {
    @ObservedObject var g: Glasses
    /// Only one host reads the text to VoiceOver.
    var announces = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: 1)
                .allowsHitTesting(false)
            if let toast = g.toast {
                ToastBanner(toast: toast) { dismiss(toast.id) }
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: g.toast?.id)
        .task(id: g.toast?.id) {
            guard let shown = g.toast else { return }
            if announces {
                UIAccessibility.post(notification: .announcement, argument: shown.text)
            }
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            dismiss(shown.id)
        }
    }

    /// Clears only the toast that was showing, so a newer one keeps its full time.
    private func dismiss(_ id: UUID) {
        if g.toast?.id == id { g.toast = nil }
    }
}

private struct ToastBanner: View {
    let toast: Toast
    let onTap: () -> Void

    private var symbol: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return Color.green
        case .failure: return Color.red
        default: return GlassesTheme.accent
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toast.text)
        .accessibilityHint("轻点关闭")
    }
}

// MARK: - 文字格式

enum GlassesFormat {
    /// Storage the way the glasses report it, in megabytes.
    static func storage(_ megabytes: Int) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", Double(megabytes) / 1024) : "\(megabytes) MB"
    }

    static func captureDate(_ nanoseconds: Int?) -> Date? {
        guard let nanoseconds else { return nil }
        return Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }

    /// "15:57", or nothing when the capture carries no time.
    static func clock(_ nanoseconds: Int?) -> String {
        guard let moment = captureDate(nanoseconds) else { return "" }
        return clockFormatter.string(from: moment)
    }

    /// The heading of one day in the album: 今天, 昨天, "11月26日 星期四", or with the year when it differs.
    static func dayTitle(_ day: Date) -> String {
        if day == Date.distantPast { return "日期未知" }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return dayFormatter.string(from: day)
        }
        return yearDayFormatter.string(from: day)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    private static let yearDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}
