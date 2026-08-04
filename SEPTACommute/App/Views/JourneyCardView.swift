import SwiftUI

/// One option in the list: how to go, when to leave, when you arrive.
struct JourneyCardView: View {
    var journey: Journey
    var summary: JourneySummary
    var comparison: JourneyComparison
    var network: Network

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            legStrip
            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(comparison.isBest ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.background.secondary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if comparison.isBest {
                        Text("FASTEST")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    ForEach(distinctKinds, id: \.self) { kind in
                        PatternChip(kind: kind)
                    }
                }
                Text(summary.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            arrivalColumn
        }
    }

    private var arrivalColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Format.clock(journey.arrivalTime))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("arrive")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !comparison.isBest, abs(comparison.arrivalDelta) >= 30 {
                Text(Format.signedMinutes(comparison.arrivalDelta))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(comparison.arrivalDelta > 0 ? .secondary : Theme.color(for: .relaxed))
            }
        }
    }

    // MARK: - Legs

    /// A one-line pictogram of the trip: walk, ride, change, walk.
    private var legStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(visibleLegs.enumerated()), id: \.offset) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                legToken(leg)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func legToken(_ leg: JourneyLeg) -> some View {
        switch leg {
        case .walk(let walk):
            HStack(spacing: 3) {
                Image(systemName: "figure.walk").font(.caption2)
                Text(Format.compactMinutes(walk.duration)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)

        case .wait(let wait):
            HStack(spacing: 3) {
                Image(systemName: wait.isStrategicHold ? "arrow.triangle.swap" : "clock").font(.caption2)
                Text(Format.compactMinutes(wait.duration)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(wait.isStrategicHold ? Theme.color(for: .leaveSoon) : .secondary)

        case .ride(let ride):
            HStack(spacing: 4) {
                Image(systemName: Theme.symbol(for: ride.kind)).font(.caption2)
                Text(Format.stops(ride.stopCount)).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.color(for: ride.kind).opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.color(for: ride.kind))
        }
    }

    /// Sub-minute waits are noise on a summary card.
    private var visibleLegs: [JourneyLeg] {
        journey.legs.filter { leg in
            switch leg {
            case .wait(let wait): return wait.duration >= 45
            case .walk(let walk): return walk.duration >= 45
            case .ride: return true
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if journey.isWalkOnly {
                Label(Format.minutes(journey.totalDuration), systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                UrgencyBadge(urgency: journey.urgency)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Train at \(Format.clock(journey.urgency.boardingDeparture))")
                            .font(.caption.weight(.medium))
                        CountdownText(
                            target: journey.urgency.boardingDeparture,
                            style: .caption.weight(.bold),
                            color: .primary
                        )
                    }
                    if let footnote = summary.footnote {
                        Text(footnote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(Format.compactMinutes(journey.totalDuration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var distinctKinds: [PatternKind] {
        var seen: [PatternKind] = []
        for ride in journey.rides where !seen.contains(ride.kind) {
            seen.append(ride.kind)
        }
        return seen
    }

    private var accessibilityDescription: String {
        var parts: [String] = [summary.title]
        if !summary.detail.isEmpty { parts.append(summary.detail) }
        if !journey.isWalkOnly {
            parts.append("leave by \(Format.clock(journey.urgency.leaveBy))")
            parts.append("train departs \(Format.clock(journey.urgency.boardingDeparture))")
        }
        parts.append("arrive \(Format.clock(journey.arrivalTime))")
        parts.append("total \(Format.minutes(journey.totalDuration))")
        if comparison.isBest { parts.append("fastest option") }
        return parts.joined(separator: ", ")
    }
}
