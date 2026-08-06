import SwiftUI

/// The platform sign, filtered to trains that can actually get you there.
///
/// The recommendation answers "which train". This answers the question a rider asks
/// next, standing on the platform with the app already open: *what else is coming, and
/// what does it cost me to wait for it.* It is deliberately unfiltered — the planner
/// hides an option that another beats outright, which is right for a recommendation
/// and wrong for a board. The slow train you'll take anyway because it's here now
/// belongs on it.
struct DepartureBoardView: View {
    @EnvironmentObject private var model: CommuteModel

    var body: some View {
        if !model.departures.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(Array(model.departures.enumerated()), id: \.element.id) { index, departure in
                    if index > 0 { Divider().padding(.leading, 52) }
                    row(departure)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: model.boardHeading)
            Spacer()
            Text("arrive")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func row(_ departure: BoardDeparture) -> some View {
        let recommended = model.isRecommended(departure)
        return HStack(spacing: 10) {
            badge(for: departure)
            service(departure, recommended: recommended)
            Spacer(minLength: 4)
            countdown(departure, recommended: recommended)
            arrival(departure, recommended: recommended)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Faded, not hidden. This train is really pulling in first and the rider can
        // see it; what they cannot see is that it will go straight past their stop.
        .opacity(departure.isUseful ? 1 : 0.45)
        .background(recommended ? Theme.accent.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel(for: departure, recommended: recommended))
    }

    private func badge(for departure: BoardDeparture) -> some View {
        let line = model.network.line(departure.lineID)
        return LineBadge(
            text: departure.routeBadge,
            color: Theme.color(for: line),
            textColor: Theme.foreground(on: line),
            size: 26
        )
    }

    private func service(_ departure: BoardDeparture, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // No direction here: the whole board is one platform and the header says
            // which. What is left is the part that differs between rows.
            Text(departure.serviceHeadline)
                .font(.caption.weight(recommended ? .semibold : .regular))
                .lineLimit(1)
            Text(subtitle(for: departure))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func subtitle(for departure: BoardDeparture) -> String {
        if let alight = departure.alightStation { return stationName(alight) }
        if let missed = departure.missedDestination { return "skips \(stationName(missed))" }
        return "no use to you"
    }

    /// The number a rider is actually reading, so it ticks.
    private func countdown(_ departure: BoardDeparture, recommended: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = departure.departure.timeIntervalSince(context.date)
            VStack(alignment: .trailing, spacing: 1) {
                Text(remaining <= 0 ? "gone" : Format.countdown(remaining))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(countdownColor(remaining: remaining, recommended: recommended))
                Text(Format.clock(departure.departure))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func arrival(_ departure: BoardDeparture, recommended: Bool) -> some View {
        if let arrival = departure.arrival {
            Text(Format.clock(arrival))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(recommended ? Color.primary : Color.secondary)
                .frame(width: 62, alignment: .trailing)
        } else {
            // An em dash rather than a blank, so the column still reads as a column.
            Text("—")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    /// Built with statements rather than one interpolated expression: concatenating
    /// four interpolations and a ternary is enough to time the type checker out.
    private func spokenLabel(for departure: BoardDeparture, recommended: Bool) -> String {
        var parts: [String] = [departure.routeBadge, departure.platformHeadline]
        parts.append("leaves \(Format.clock(departure.departure))")
        if let alight = departure.alightStation, let arrival = departure.arrival {
            parts.append("reaches \(stationName(alight)) at \(Format.clock(arrival))")
        } else if let missed = departure.missedDestination {
            parts.append("does not stop at \(stationName(missed))")
        }
        if recommended { parts.append("recommended") }
        return parts.joined(separator: ", ")
    }

    /// Three-way choice pulled out of the view body — `.tertiary` and `.primary` are
    /// a different type from `Theme.accent`, so inline it needs coercing anyway.
    private func countdownColor(remaining: TimeInterval, recommended: Bool) -> Color {
        if remaining <= 0 { return .secondary }
        return recommended ? Theme.accent : .primary
    }

    private func stationName(_ id: StationID) -> String {
        model.network.station(id)?.name ?? id.rawValue
    }
}
