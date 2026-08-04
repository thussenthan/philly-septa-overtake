import SwiftUI

/// An alternative to the recommendation, on one line.
///
/// A rider only ever wants two things from an alternative: what it costs, and what
/// it buys. So each row is "+3 min later, but you can leave 6 minutes from now" —
/// which is the whole express-versus-local question in a single line — and the
/// itinerary is a tap away.
struct OptionRow: View {
    var journey: Journey
    var summary: JourneySummary
    var comparison: JourneyComparison
    var network: Network
    /// True when SEPTA is reporting something on one of this option's lines.
    var hasAlert: Bool

    var body: some View {
        HStack(spacing: 10) {
            badges
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(summary.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if hasAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.color(for: .leaveSoon))
                    }
                }
                Text(tradeoff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title), \(tradeoff)")
    }

    private var badges: some View {
        HStack(spacing: -6) {
            ForEach(lines.prefix(2), id: \.id) { line in
                LineBadge(
                    text: line.badge,
                    color: Theme.color(for: line),
                    textColor: Theme.foreground(on: line),
                    size: 22
                )
            }
            if lines.isEmpty {
                Image(systemName: "figure.walk")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
        }
    }

    /// "+3 min later · leave in 8 min" — cost on the left, slack on the right.
    private var tradeoff: String {
        var parts: [String] = []
        if abs(comparison.arrivalDelta) >= 30 {
            parts.append("\(Format.signedMinutes(comparison.arrivalDelta)) arrival")
        } else {
            parts.append("same arrival")
        }
        if journey.isWalkOnly {
            parts.append("no train to catch")
        } else {
            let slack = journey.urgency.secondsUntilLeaveBy(asOf: Date())
            parts.append("leave \(Format.relativeLeave(slack))")
        }
        return parts.joined(separator: " · ")
    }

    private var lines: [Line] {
        var seen: [Line] = []
        for ride in journey.rides {
            guard let line = network.line(ride.lineID) else { continue }
            if !seen.contains(where: { $0.id == line.id }) { seen.append(line) }
        }
        return seen
    }
}
