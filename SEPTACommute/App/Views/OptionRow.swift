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
        HStack(spacing: 3) {
            // Route numbers, not line letters: whether this option is the B2 express
            // or the B1 local is the entire difference between the two rows.
            ForEach(routes.prefix(2), id: \.badge) { route in
                LineBadge(
                    text: route.badge,
                    color: Theme.color(for: route.line),
                    textColor: Theme.foreground(on: route.line),
                    size: 24
                )
            }
            if routes.isEmpty {
                Image(systemName: "figure.walk")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
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

    private struct Route {
        var badge: String
        var line: Line?
    }

    private var routes: [Route] {
        var seen: [Route] = []
        for ride in journey.rides where !seen.contains(where: { $0.badge == ride.routeBadge }) {
            seen.append(Route(badge: ride.routeBadge, line: network.line(ride.lineID)))
        }
        return seen
    }
}
