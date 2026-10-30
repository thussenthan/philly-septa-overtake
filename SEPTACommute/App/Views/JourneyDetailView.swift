import SwiftUI

/// Step-by-step instructions for one option.
struct JourneyDetailView: View {
    /// Rides whose full stop list the rider has opened, by board station.
    ///
    /// Collapsed by default because the summary — "7 stops, 14 min" — is what most
    /// riders want, and a wall of station names between the steps buries the steps.
    /// But "7 stops" is not checkable, and the home screen's compressed strip openly
    /// hides some of them, so there has to be somewhere the whole list exists.
    @State private var expandedRides: Set<String> = []

    var journey: Journey
    var summary: JourneySummary
    var narrator: JourneyNarrator
    var network: Network
    var originName: String
    var destinationName: String
    /// SEPTA's worst notice for the lines this option uses. The home screen only
    /// names it; this is where its text belongs.
    var alert: ServiceAlert?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview
                if let alert { alertBox(alert) }
                timeline
                if !journey.isWalkOnly {
                    breakdown
                }
            }
            .padding(20)
        }
        .navigationTitle("Your trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText, subject: Text("\(originName) → \(destinationName)")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share this trip")
            }
        }
    }

    // MARK: - Sharing

    /// The itinerary as plain text, for whoever is waiting at the other end: when
    /// the rider sets off, which trains, and when they will walk in the door.
    private var shareText: String {
        var lines = ["\(originName) → \(destinationName)"]
        if !journey.isWalkOnly {
            lines.append("Leave by \(Format.clock(journey.urgency.leaveBy))")
        }
        for leg in journey.legs {
            switch leg {
            case .walk(let walk) where walk.duration >= 60:
                lines.append("Walk \(Format.minutes(walk.duration)) to \(walk.toName)")
            case .wait(let wait) where wait.overtake != nil:
                lines.append("Wait \(Format.minutes(wait.duration)) at \(stationName(wait.stationID)) for the faster train")
            case .ride(let ride):
                lines.append(
                    "\(ride.routeBadge) \(ride.platformDescription): "
                        + "\(stationName(ride.boardStation)) \(Format.clock(ride.departure)) → "
                        + "\(stationName(ride.alightStation)) \(Format.clock(ride.arrival))"
                )
            default:
                break
            }
        }
        lines.append("Arrive \(Format.clock(journey.arrivalTime))")
        lines.append("Scheduled times from SEPTA's published timetable.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text("\(originName) → \(destinationName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                stat("Leave", Format.clock(journey.departureTime))
                stat("Arrive", Format.clock(journey.arrivalTime))
                stat("Total", Format.minutes(journey.totalDuration))
            }

            if !journey.isWalkOnly {
                UrgencyBadge(urgency: journey.urgency)
            }
            if let footnote = summary.footnote {
                Label(footnote, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Service alert

    /// SEPTA's own words, verbatim.
    ///
    /// The app doesn't try to interpret them: alert text is prose, and a planner
    /// that guessed at "expect residual delays" would be inventing a timetable.
    /// The rider gets the notice and the itinerary side by side, and decides.
    private func alertBox(_ alert: ServiceAlert) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                Text(alert.severity.label)
                    .font(.caption.weight(.bold))
                Text(alert.routeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Theme.color(for: alert.severity))

            Text(alert.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text("From SEPTA's service alerts. Times below come from the published timetable and don't account for this.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.color(for: alert.severity).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Step by step")
                .padding(.bottom, 10)
            ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                legRow(leg, isLast: index == journey.legs.count - 1)
            }
        }
    }

    @ViewBuilder
    private func legRow(_ leg: JourneyLeg, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(tint(for: leg))
                    .frame(width: 11, height: 11)
                if !isLast {
                    Rectangle()
                        .fill(tint(for: leg).opacity(0.35))
                        .frame(width: 2)
                        .frame(minHeight: 34)
                }
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                content(for: leg)
            }
            .padding(.bottom, isLast ? 0 : 14)

            Spacer(minLength: 0)

            Text(Format.clock(leg.startTime))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func content(for leg: JourneyLeg) -> some View {
        switch leg {
        case .walk(let walk):
            Text(walkTitle(walk))
                .font(.subheadline.weight(.medium))
            Text(walkSubtitle(walk))
                .font(.caption)
                .foregroundStyle(.secondary)

        case .wait(let wait):
            Text(wait.overtake != nil
                 ? "Get off and wait \(Format.minutes(wait.duration)) at \(stationName(wait.stationID))"
                 : "Wait \(Format.minutes(wait.duration)) on the platform")
                .font(.subheadline.weight(.medium))
            if let overtake = wait.overtake {
                // Both numbers were checked against the timetable, so they can be
                // stated as fact rather than hedged.
                Text("A faster train catches you up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Staying on your first train would reach \(stationName(overtake.comparedAt)) at \(Format.clock(overtake.arrivalIfTheyHadStayedPut)) — \(Format.minutes(overtake.timeSaved)) later.")
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: .relaxed))
            }

        case .ride(let ride):
            HStack(spacing: 6) {
                LineBadge(
                    text: badgeText(for: ride),
                    color: Theme.color(for: network.line(ride.lineID)),
                    textColor: Theme.foreground(on: network.line(ride.lineID)),
                    size: 22
                )
                Text(ride.platformDescription)
                    .font(.subheadline.weight(.medium))
            }
            Button {
                let key = rideKey(ride)
                if expandedRides.contains(key) { expandedRides.remove(key) } else { expandedRides.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    Text("\(stationName(ride.boardStation)) → \(stationName(ride.alightStation)) · \(Format.stops(ride.stopCount)) · \(Format.minutes(ride.duration))")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                    Image(systemName: expandedRides.contains(rideKey(ride)) ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandedRides.contains(rideKey(ride)) ? "Hide the stops" : "Show every stop")

            if expandedRides.contains(rideKey(ride)) {
                stopList(for: ride)
            }
            let skipped = narrator.skippedStations(on: ride)
            if !skipped.isEmpty {
                Text("Passes without stopping: \(skipped.map(stationName).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if ride.kind == .nightBus {
                Text("Boards at the curb on Broad St, not in the station.")
                    .font(.caption2)
                    .foregroundStyle(Theme.color(for: .leaveSoon))
            }
        }
    }

    /// Offsets are measured from the trip's own start, so these are the same
    /// timetable the countdown on the home screen is counting to.
    private func arrivalTime(of station: StationID, on ride: RideLeg, in pattern: ServicePattern?) -> Date? {
        guard let pattern, let index = pattern.stopIndex(of: station) else { return nil }
        return ride.trip.startTime.addingTimeInterval(pattern.stops[index].arrivalOffset)
    }

    private func rideKey(_ ride: RideLeg) -> String {
        "\(ride.trip.id)|\(ride.boardStation)"
    }

    /// Every station this ride calls at, with the time it reaches each.
    ///
    /// Times come from the pattern's own offsets rather than being re-derived, so they
    /// are the same timetable the countdown on the home screen is counting to.
    private func stopList(for ride: RideLeg) -> some View {
        let pattern = network.pattern(ride.patternID)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(ride.stationsServed.enumerated()), id: \.offset) { index, station in
                let isEnd = index == 0 || index == ride.stationsServed.count - 1
                HStack(spacing: 8) {
                    Circle()
                        .fill(isEnd ? Theme.color(for: network.line(ride.lineID)) : Color.secondary.opacity(0.4))
                        .frame(width: isEnd ? 7 : 5)
                        .frame(width: 9)
                    Text(stationName(station))
                        .font(.caption2)
                        .foregroundStyle(isEnd ? .primary : .secondary)
                    Spacer(minLength: 4)
                    if let time = arrivalTime(of: station, on: ride, in: pattern) {
                        Text(Format.clock(time))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.top, 2)
        .padding(.leading, 2)
    }

    private func walkTitle(_ walk: WalkLeg) -> String {
        "Walk to \(walk.toName)"
    }

    private func walkSubtitle(_ walk: WalkLeg) -> String {
        var parts = [Format.minutes(walk.duration), Format.distance(meters: walk.routedMeters)]
        parts.append(walk.isMeasured ? "walking directions" : "estimated")
        return parts.joined(separator: " · ")
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Where the time goes")
            row("On the train", "tram.fill", journey.ridingTime)
            row("Walking", "figure.walk", journey.walkingTime)
            row("Waiting", "hourglass", journey.waitingTime)
            if journey.transferCount > 0 {
                HStack(spacing: 8) {
                    icon("arrow.triangle.swap")
                    Text("Changes of train")
                    Spacer()
                    Text("\(journey.transferCount)")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ label: String, _ symbol: String, _ seconds: TimeInterval) -> some View {
        HStack(spacing: 8) {
            icon(symbol)
            Text(label)
            Spacer()
            Text(Format.minutes(seconds))
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// Fixed width so the labels line up in a column rather than stepping in and out
    /// with each glyph's width.
    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .frame(width: 18)
    }

    // MARK: - Helpers

    private func stationName(_ id: StationID) -> String {
        network.station(id)?.displayName ?? id.rawValue
    }

    /// The route as the map and the platform signs write it: B2, not B.
    private func badgeText(for ride: RideLeg) -> String { ride.routeBadge }

    private func tint(for leg: JourneyLeg) -> Color {
        switch leg {
        case .ride(let ride): return Theme.color(for: ride.kind)
        case .wait(let wait): return wait.isStrategicHold ? Theme.color(for: .leaveSoon) : .secondary
        case .walk: return .secondary
        }
    }
}
