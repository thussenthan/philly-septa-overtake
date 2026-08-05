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
            // Whatever the screen has spare after the itinerary, which on a short
            // ride is little — the stop strip is doing the filling now.
            Spacer(minLength: 0)
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
            fareRow
        }
    }

    /// Only on itineraries with a change of train, and only when how you paid
    /// changes what you pay.
    ///
    /// The fare is $2.90 for almost every trip on this network, so printing it
    /// everywhere would be decoration. The exception is a transfer: SEPTA includes it
    /// free on Key and contactless and charges again for cash, and a rider deciding
    /// between one train and two deserves to know that costs them another $2.90.
    @ViewBuilder
    private var fareRow: some View {
        if journey.rides.count > 1, let fare = journey.fare(network.fare), fare.mediumMatters {
            walkRow(
                "\(Format.money(fare.withFreeTransfers, currency: fare.currency)) — the change is free with "
                    + "\(network.fare.freeTransferMedia.first ?? "SEPTA Key")"
                    + ", \(Format.money(fare.perBoarding, currency: fare.currency)) paying twice",
                symbol: "creditcard"
            )
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
                stopStrip(for: ride)
            }
            Spacer(minLength: 0)
            Text(Format.clock(ride.departure))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The stops between boarding and getting off, drawn the way the map draws them.
    ///
    /// This is what a rider looks at once they're aboard — "how many more, and is the
    /// next one mine" — and it's the honest way to use a tall card: space filled with
    /// the thing you'd otherwise be counting on the wall diagram, rather than with
    /// nothing. Long rides are compressed in the middle, because twenty stop names is
    /// a wall of text and the two either end are the ones you watch for.
    @ViewBuilder
    private func stopStrip(for ride: RideLeg) -> some View {
        let stops = stopTimes(for: ride)
        if stops.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(compress(stops).enumerated()), id: \.offset) { index, entry in
                    switch entry {
                    case .stop(let name, let time, let isLast):
                        stopRow(
                            name: name,
                            time: time,
                            line: network.line(ride.lineID),
                            isFirst: index == 0,
                            isLast: isLast
                        )
                    case .gap(let count):
                        gapRow(count: count, line: network.line(ride.lineID))
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func stopRow(name: String, time: Date?, line: Line?, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 9) {
            ZStack {
                // The line runs through the row; the halves are trimmed at the ends
                // so it starts and stops at a station rather than in mid-air.
                VStack(spacing: 0) {
                    Rectangle().fill(isFirst ? Color.clear : Theme.color(for: line))
                    Rectangle().fill(isLast ? Color.clear : Theme.color(for: line))
                }
                .frame(width: 2.5)
                Circle()
                    .fill(isFirst || isLast ? Theme.color(for: line) : Color(.systemBackground))
                    .frame(width: isFirst || isLast ? 9 : 6)
                    .overlay(Circle().strokeBorder(Theme.color(for: line), lineWidth: 2))
            }
            .frame(width: 12, height: 22)

            Text(name)
                .font(isLast ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(isFirst || isLast ? .primary : .secondary)
                .lineLimit(1)
            if isLast {
                Text("get off")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 4)
            if let time {
                Text(Format.clock(time))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func gapRow(count: Int, line: Line?) -> some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(Theme.color(for: line))
                .frame(width: 2.5, height: 18)
                .frame(width: 12)
            Text("\(count) more stops")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// Every station on this ride with the clock time it is reached.
    ///
    /// Offsets are measured from the trip's own start, so the times come out of the
    /// same timetable the countdown does rather than being re-derived.
    private func stopTimes(for ride: RideLeg) -> [(name: String, time: Date?)] {
        guard let pattern = network.pattern(ride.patternID) else {
            return ride.stationsServed.map { (name: stationName($0), time: Date?.none) }
        }
        return ride.stationsServed.map { station in
            let time: Date? = pattern.stopIndex(of: station).map {
                ride.trip.startTime.addingTimeInterval(pattern.stops[$0].arrivalOffset)
            }
            return (name: stationName(station), time: time)
        }
    }

    private enum StripEntry {
        case stop(name: String, time: Date?, isLast: Bool)
        case gap(count: Int)
    }

    /// Keep the ends, compress the middle. Six stops fit; twenty do not, and the ones
    /// in the middle are exactly the ones nobody is watching for.
    private func compress(_ stops: [(name: String, time: Date?)]) -> [StripEntry] {
        let visible = 6
        guard stops.count > visible else {
            return stops.enumerated().map { index, stop in
                .stop(name: stop.name, time: stop.time, isLast: index == stops.count - 1)
            }
        }
        var entries: [StripEntry] = stops.prefix(2).map {
            .stop(name: $0.name, time: $0.time, isLast: false)
        }
        entries.append(.gap(count: stops.count - 4))
        for (offset, stop) in stops.suffix(2).enumerated() {
            entries.append(.stop(name: stop.name, time: stop.time, isLast: offset == 1))
        }
        return entries
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
