import SwiftUI

/// The answer, at full width.
///
/// Two jobs. First, the decision: how long until you have to move, and when you
/// land. Second — and this is what a phone can do that a platform sign can't — the
/// things you then have to *match against the station*: the route number as the map
/// writes it, the words on the front of the train, which platform to stand on by way
/// of where it's headed, and where to get off.
///
/// `B` is not enough for that. At Erie, B1 and B2 use different tracks and only one
/// of them stops where you're going, so a card that says "B" leaves the rider doing
/// the last and most error-prone step themselves.
struct HeroCard: View {
    var journey: Journey
    var summary: JourneySummary
    var narrator: JourneyNarrator
    var network: Network
    /// SEPTA's worst notice for the lines this option uses, if any.
    var alert: ServiceAlert?
    var alertLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timing
            if !journey.isWalkOnly {
                Divider().opacity(0.35).padding(.vertical, 14)
                instructions
            }
            if alert != nil, let alertLabel {
                Divider().opacity(0.35).padding(.vertical, 12)
                alertChip(alertLabel)
            }
            advisory
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - The decision

    private var timing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if journey.isWalkOnly {
                Text("Walk \(Format.minutes(journey.totalDuration))")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
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
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - What to do in the station

    /// One row per thing the rider does, in order. Walks are included when they are
    /// long enough to matter, because "leave in four minutes" means nothing if you
    /// don't know you're walking six blocks first.
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let access = journey.walks.first(where: { $0.purpose == .access }), access.duration >= 60 {
                walkRow("Walk \(Format.minutes(access.duration)) to \(access.toName)", symbol: "figure.walk")
            }

            ForEach(Array(journey.rides.enumerated()), id: \.offset) { index, ride in
                rideRow(
                    ride,
                    repeatsHeadsign: index > 0 && journey.rides[index - 1].headsign == ride.headsign
                )
            }

            if let exit = journey.finalWalk, exit.duration >= 60 {
                walkRow("Walk \(Format.minutes(exit.duration)) to \(exit.toName)", symbol: "figure.walk")
            }
        }
    }

    /// Everything needed to get on the right train and off at the right stop, and
    /// nothing else.
    ///
    /// The boarding station is left out on purpose: for the first train it is the
    /// "from" already at the top of the screen, and for a change it is where the
    /// previous row just put you. The headsign is left out when it repeats the row
    /// above, which it does for every same-corridor change. Stop counts are gone —
    /// you get off at a named station, not after counting.
    private func rideRow(_ ride: RideLeg, repeatsHeadsign: Bool) -> some View {
        let line = network.line(ride.lineID)
        return HStack(alignment: .top, spacing: 11) {
            // The route as the signs write it — B2, not B.
            LineBadge(
                text: ride.routeBadge,
                color: Theme.color(for: line),
                textColor: Theme.foreground(on: line),
                size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.platformHeadline)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail(for: ride, repeatsHeadsign: repeatsHeadsign))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if ride.kind == .nightBus {
                    Text("Boards at the curb, not in the station.")
                        .font(.caption2)
                        .foregroundStyle(Theme.color(for: Urgency.Level.leaveSoon))
                }
            }
            Spacer(minLength: 0)
            Text(Format.clock(ride.departure))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func detail(for ride: RideLeg, repeatsHeadsign: Bool) -> String {
        let off = "off at \(stationName(ride.alightStation))"
        guard !repeatsHeadsign, !ride.platformHeadline.hasPrefix("toward") else { return off }
        return "\(ride.headsignPhrase) · \(off)"
    }

    private func walkRow(_ text: String, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Warnings

    /// Only ever the run warning — the one thing that changes what to do in the
    /// next thirty seconds.
    @ViewBuilder
    private var advisory: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let advisory = narrator.advisory(for: journey, asOf: context.date) {
                let tint = advisoryTint(advisory)
                VStack(alignment: .leading, spacing: 0) {
                    if alert == nil {
                        Divider().opacity(0.35).padding(.vertical, 12)
                    }
                    HStack(spacing: 7) {
                        Image(systemName: advisorySymbol(advisory))
                            .font(.caption.weight(.bold))
                        Text(narrator.advisoryText(advisory))
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tint)
                }
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
        .foregroundStyle(Theme.color(for: Urgency.Level.leaveSoon))
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func stationName(_ id: StationID) -> String {
        network.station(id)?.name ?? id.rawValue
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
        case .run: return Theme.color(for: Urgency.Level.leaveNow)
        case .dontRush: return Theme.color(for: Urgency.Level.relaxed)
        case .worthCatching: return Theme.accent
        case .missed: return Theme.color(for: Urgency.Level.missed)
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [summary.title]
        if !journey.isWalkOnly {
            parts.append("leave by \(Format.clock(journey.urgency.leaveBy))")
            for ride in journey.rides {
                parts.append("\(ride.routeBadge) \(ride.platformDescription) from \(stationName(ride.boardStation)) to \(stationName(ride.alightStation))")
            }
        }
        parts.append("arrive \(Format.clock(journey.arrivalTime))")
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
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                } else {
                    Text("Leave in")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Format.countdown(remaining))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
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
