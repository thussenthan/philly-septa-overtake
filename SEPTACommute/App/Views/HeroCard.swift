import SwiftUI

/// The answer, and nothing else.
///
/// The home screen exists to settle one question — which train, and how long have
/// I got — so the best option gets a card with four things on it: the lines, what
/// to do, when to move, and when you land. Stops, transfers, walking distances and
/// skipped stations are all a tap away in `JourneyDetailView`; putting them here
/// would mean reading a paragraph to answer a question that fits in a glance.
struct HeroCard: View {
    var journey: Journey
    var summary: JourneySummary
    var narrator: JourneyNarrator
    var network: Network
    /// SEPTA's worst notice for the lines this option uses, if any.
    var alert: ServiceAlert?
    var alertLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            badgeRow
            Text(summary.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            timing
            if alert != nil, let alertLabel {
                alertChip(alertLabel)
            }
            advisory
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pieces

    private var badgeRow: some View {
        HStack(spacing: 6) {
            ForEach(lines, id: \.id) { line in
                LineBadge(
                    text: line.badge,
                    color: Theme.color(for: line),
                    textColor: Theme.foreground(on: line),
                    size: 24
                )
            }
            if journey.isWalkOnly {
                Image(systemName: "figure.walk")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// The two numbers that decide it: how long until you have to move, and when
    /// you land. Departure time, total duration, stop counts and walking distances
    /// are all in the detail view — none of them change the decision.
    private var timing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if journey.isWalkOnly {
                Text("Walk \(Format.minutes(journey.totalDuration))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            } else {
                LeaveCountdown(urgency: journey.urgency)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.clock(journey.arrivalTime))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("arrive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only ever the run warning — the one thing that changes what to do in the
    /// next thirty seconds. Everything else the narrator could say lives in the
    /// detail view.
    @ViewBuilder
    private var advisory: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let advisory = narrator.advisory(for: journey, asOf: context.date) {
                let tint = advisoryTint(advisory)
                HStack(spacing: 7) {
                    Image(systemName: advisorySymbol(advisory))
                        .font(.caption.weight(.bold))
                    Text(narrator.advisoryText(advisory))
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(tint)
            }
        }
    }

    /// Names the disruption and the line, not SEPTA's paragraph about it.
    private func alertChip(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.color(for: .leaveSoon))
    }

    private var lines: [Line] {
        var seen: [Line] = []
        for ride in journey.rides {
            guard let line = network.line(ride.lineID) else { continue }
            if !seen.contains(where: { $0.id == line.id }) { seen.append(line) }
        }
        return seen
    }

    private func advisorySymbol(_ advisory: Advisory) -> String {
        switch advisory {
        case .run: return "figure.run"
        case .dontRush: return "figure.walk"
        case .worthCatching: return "star.fill"
        case .missed: return "xmark.circle"
        }
    }

    private func advisoryTint(_ advisory: Advisory) -> Color {
        switch advisory {
        case .run: return Theme.color(for: .leaveNow)
        case .dontRush: return Theme.color(for: .relaxed)
        case .worthCatching: return Theme.accent
        case .missed: return Theme.color(for: .missed)
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [summary.title]
        if !journey.isWalkOnly {
            parts.append("leave by \(Format.clock(journey.urgency.leaveBy))")
            parts.append("train departs \(Format.clock(journey.urgency.boardingDeparture))")
        }
        parts.append("arrive \(Format.clock(journey.arrivalTime))")
        parts.append("total \(Format.minutes(journey.totalDuration))")
        if let alertLabel { parts.append(alertLabel) }
        return parts.joined(separator: ", ")
    }
}

/// "Leave in 4:07", counting down, coloured by how tight it is.
///
/// The one number on the home screen that has to be live: a countdown that is
/// thirty seconds stale is a train missed.
struct LeaveCountdown: View {
    var urgency: Urgency

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = urgency.secondsUntilLeaveBy(asOf: context.date)
            let level = Urgency(
                leaveBy: urgency.leaveBy,
                boardingDeparture: urgency.boardingDeparture,
                slack: remaining
            ).level
            let tint = Theme.color(for: level)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if remaining <= 30 {
                    Text("Go now")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                } else {
                    Text("Leave in")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Format.countdown(remaining))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .accessibilityLabel(
                remaining <= 30 ? "leave now" : "leave in \(Format.minutes(remaining))"
            )
        }
    }
}
