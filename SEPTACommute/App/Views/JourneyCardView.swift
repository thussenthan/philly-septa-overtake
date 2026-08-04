import SwiftUI

/// One option in full: how to go, when to leave, when you arrive.
///
/// This is the "all options" card, not the home screen — the home screen shows the
/// recommendation and one line per alternative. Here the rider has asked to compare,
/// so the leg strip, the pattern chips and the footnote earn their space.
struct JourneyCardView: View {
    var journey: Journey
    var summary: JourneySummary
    var comparison: JourneyComparison
    var narrator: JourneyNarrator
    var network: Network
    /// "Delays on the B", when SEPTA is reporting something on this option's lines.
    var alertLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            legStrip
            if let alertLabel { alertChip(alertLabel) }
            advisoryBanner
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

    /// "Go now — miss this and you lose 12 min", or the opposite.
    ///
    /// Re-evaluated on a timer because it depends on how long is left, not just on
    /// the plan: an option that was relaxed a minute ago may be a run now.
    @ViewBuilder
    private var advisoryBanner: some View {
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

    /// Names the disruption, not SEPTA's paragraph about it — that is in the detail
    /// view, where a rider has already decided they want to read.
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
        if let alertLabel { parts.append(alertLabel) }
        return parts.joined(separator: ", ")
    }
}
