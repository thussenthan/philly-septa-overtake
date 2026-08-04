import SwiftUI

/// Step-by-step instructions for one option.
struct JourneyDetailView: View {
    var journey: Journey
    var summary: JourneySummary
    var narrator: JourneyNarrator
    var network: Network
    var originName: String
    var destinationName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview
                timeline
                if !journey.isWalkOnly {
                    breakdown
                }
            }
            .padding(20)
        }
        .navigationTitle("Your trip")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Label("\(originName) → \(destinationName)", systemImage: "arrow.forward")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

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
                LineBadge(text: badgeText(for: ride), color: Theme.color(for: network.line(ride.lineID)), size: 22)
                Text("\(ride.kind.label) toward \(ride.headsign)")
                    .font(.subheadline.weight(.medium))
            }
            Text("\(stationName(ride.boardStation)) → \(stationName(ride.alightStation)) · \(Format.stops(ride.stopCount)) · \(Format.minutes(ride.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            row("On the train", journey.ridingTime)
            row("Walking", journey.walkingTime)
            row("Waiting", journey.waitingTime)
            if journey.transferCount > 0 {
                HStack {
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

    private func row(_ label: String, _ seconds: TimeInterval) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Format.minutes(seconds))
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private func stationName(_ id: StationID) -> String {
        network.station(id)?.displayName ?? id.rawValue
    }

    private func badgeText(for ride: RideLeg) -> String {
        network.line(ride.lineID)?.badge ?? ride.lineID.rawValue
    }

    private func tint(for leg: JourneyLeg) -> Color {
        switch leg {
        case .ride(let ride): return Theme.color(for: ride.kind)
        case .wait(let wait): return wait.isStrategicHold ? Theme.color(for: .leaveSoon) : .secondary
        case .walk: return .secondary
        }
    }
}
