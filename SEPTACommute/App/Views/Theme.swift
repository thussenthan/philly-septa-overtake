import SwiftUI

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Theme {
    /// SEPTA's published Broad Street Line orange, used as the app accent.
    static let accent = Color(hex: "F26100")

    /// A line's own published colour. Every line in the bundled data carries one,
    /// so a B trip is orange, an L trip blue, a trolley trip green.
    static func color(for line: Line?) -> Color {
        guard let line else { return accent }
        return Color(hex: line.colorHex)
    }

    static func color(for kind: PatternKind) -> Color {
        switch kind {
        case .express: return Color(hex: "0B7285")
        case .local: return broadStreet
        case .spur: return Color(hex: "6A4C93")
        case .nightBus: return Color(hex: "495057")
        }
    }

    static func color(for level: Urgency.Level) -> Color {
        switch level {
        case .missed: return .secondary
        case .leaveNow: return Color(hex: "C92A2A")
        case .leaveSoon: return Color(hex: "E8590C")
        case .relaxed: return Color(hex: "2B8A3E")
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
    var size: CGFloat = 26

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
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
