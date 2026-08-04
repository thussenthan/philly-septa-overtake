import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The same hue, pushed into a brightness range that reads against the given
    /// background.
    ///
    /// Transit colours are chosen to sit on white paper, and several of SEPTA's
    /// are unreadable at one end or the other: the Norristown line's purple
    /// (5F249F) disappears on black, and the Girard trolley's yellow (FFD700)
    /// disappears on white. Hue and saturation are preserved so the palette still
    /// looks like the map — only lightness moves, and only when it has to.
    func adjustedForContrast(darkMode: Bool) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }

        if darkMode {
            // Lift dark colours off the background; ease off saturation slightly,
            // since fully saturated brights vibrate against near-black.
            brightness = max(brightness, 0.82)
            saturation = min(saturation, 0.78)
        } else {
            // Pull pale colours down far enough to read on white.
            brightness = min(brightness, 0.86)
        }
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    /// Whether text on top of this colour should be black rather than white.
    var prefersDarkForeground: Bool {
        var white: CGFloat = 0, alpha: CGFloat = 0
        guard getWhite(&white, alpha: &alpha) else { return false }
        return white > 0.62
    }
}

enum Theme {
    /// Resolves a fixed hex to a colour that adapts to light and dark.
    ///
    /// A `UIColor` with a dynamic provider re-resolves whenever the trait
    /// collection changes, so this follows the appearance live rather than being
    /// baked in at launch. Every colour in the app goes through here, including
    /// the line colours that come from SEPTA's feed and so cannot be hand-tuned.
    static func adaptive(_ hex: String) -> Color {
        let base = UIColor(hex: hex)
        return Color(uiColor: UIColor { traits in
            base.adjustedForContrast(darkMode: traits.userInterfaceStyle == .dark)
        })
    }

    /// SEPTA's published Broad Street Line orange, used as the app accent.
    static let accent = adaptive("F26100")

    /// A line's own published colour. Every line in the bundled data carries one,
    /// so a B trip is orange, an L trip blue, a trolley trip green.
    static func color(for line: Line?) -> Color {
        guard let line else { return accent }
        return adaptive(line.colorHex)
    }

    /// Text colour to sit on top of a line's badge.
    static func foreground(on line: Line?) -> Color {
        guard let line else { return .white }
        let base = UIColor(hex: line.colorHex)
        return Color(uiColor: UIColor { traits in
            let resolved = base.adjustedForContrast(darkMode: traits.userInterfaceStyle == .dark)
            return resolved.prefersDarkForeground ? .black : .white
        })
    }

    static func color(for kind: PatternKind) -> Color {
        switch kind {
        case .express: return adaptive("0B7285")
        case .local: return accent
        case .spur: return adaptive("6A4C93")
        case .nightBus: return adaptive("495057")
        }
    }

    static func color(for level: Urgency.Level) -> Color {
        switch level {
        case .missed: return .secondary
        case .leaveNow: return adaptive("C92A2A")
        case .leaveSoon: return adaptive("E8590C")
        case .relaxed: return adaptive("2B8A3E")
        }
    }

    static func symbol(for kind: PatternKind) -> String {
        switch kind {
        case .express: return "hare.fill"
        case .local: return "tram.fill"
        case .spur: return "arrow.triangle.branch"
        case .nightBus: return "bus.fill"
        }
    }
}

/// The line badge SEPTA puts on maps and station signs.
struct LineBadge: View {
    var text: String
    var color: Color = Theme.accent
    /// Defaults to white; pass black for a badge whose fill is pale.
    var textColor: Color = .white
    var size: CGFloat = 26

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
            .foregroundStyle(textColor)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }
}

/// A pill describing a stopping pattern: "Express", "Local", "Owl Bus".
struct PatternChip: View {
    var kind: PatternKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.symbol(for: kind))
                .font(.caption2)
            Text(kind.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.color(for: kind).opacity(0.15), in: Capsule())
        .foregroundStyle(Theme.color(for: kind))
    }
}

/// A live countdown that ticks once a second without redrawing the whole screen.
struct CountdownText: View {
    var target: Date
    var style: Font
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = target.timeIntervalSince(context.date)
            Text(Format.countdown(remaining))
                .font(style)
                .monospacedDigit()
                .foregroundStyle(remaining <= 0 ? Theme.color(for: .missed) : color)
                .contentTransition(.numericText(countsDown: true))
                .accessibilityLabel(
                    remaining <= 0
                        ? "departed"
                        : "\(Format.minutes(remaining)) remaining"
                )
        }
    }
}

/// "Leave now" / "Leave in 6 min", coloured by urgency.
struct UrgencyBadge: View {
    var urgency: Urgency

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = urgency.secondsUntilLeaveBy(asOf: context.date)
            let level = Urgency(
                leaveBy: urgency.leaveBy,
                boardingDeparture: urgency.boardingDeparture,
                slack: remaining
            ).level

            HStack(spacing: 5) {
                Image(systemName: level == .relaxed ? "figure.walk" : "figure.walk.motion")
                    .font(.caption2.weight(.bold))
                Text(label(for: level, remaining: remaining))
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.color(for: level).opacity(0.16), in: Capsule())
            .foregroundStyle(Theme.color(for: level))
        }
    }

    private func label(for level: Urgency.Level, remaining: TimeInterval) -> String {
        switch level {
        case .missed: return "Too late"
        case .leaveNow: return "Leave now"
        case .leaveSoon, .relaxed: return "Leave in \(Format.compactMinutes(remaining))"
        }
    }
}

/// Section header used across the screens.
struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

/// Empty-state and error messaging, kept consistent.
struct MessageCard: View {
    var symbol: String
    var title: String
    var message: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
