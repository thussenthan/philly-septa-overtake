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
            SectionLabel(text: model.boardStationName.map { "Leaving \($0)" } ?? "Departures")
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
        let line = model.network.line(departure.lineID)
        let recommended = model.isRecommended(departure)
        return HStack(spacing: 10) {
            LineBadge(
                text: departure.routeBadge,
                color: Theme.color(for: line),
                textColor: Theme.foreground(on: line),
                size: 26
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(departure.platformHeadline)
                    .font(.caption.weight(recommended ? .semibold : .regular))
                    .lineLimit(1)
                Text(stationName(departure.alightStation))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            // The countdown is the number a rider is actually reading, so it ticks.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = departure.departure.timeIntervalSince(context.date)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(remaining <= 0 ? "gone" : Format.countdown(remaining))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(remaining <= 0 ? .tertiary : (recommended ? Theme.accent : .primary))
                    Text(Format.clock(departure.departure))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Text(Format.clock(departure.arrival))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(recommended ? .primary : .secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            recommended ? Theme.accent.opacity(0.12) : Color.clear
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(departure.routeBadge) \(departure.platformHeadline), leaves "
                + "\(Format.clock(departure.departure)), reaches "
                + "\(stationName(departure.alightStation)) at \(Format.clock(departure.arrival))"
                + (recommended ? ", recommended" : "")
        )
    }

    private func stationName(_ id: StationID) -> String {
        model.network.station(id)?.name ?? id.rawValue
    }
}
