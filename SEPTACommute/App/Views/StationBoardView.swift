import SwiftUI

/// Every train leaving a station, whether or not it goes where you are going.
///
/// The home screen's board is built around a trip: it shows the trains that can get you
/// there, and greys the ones that skip your stop. This is the other thing a platform
/// sign does — says what is coming, in each direction — and most of these stations
/// have no sign to do it.
struct StationBoardView: View {
    @EnvironmentObject private var model: CommuteModel
    @Environment(\.dismiss) private var dismiss
    @State private var stationID: StationID?
    @State private var choosing = false

    /// Most trains shown per platform; the sign has room for a few, not a timetable.
    private let rowsPerPlatform = 5

    init(initial: StationID?) {
        _stationID = State(initialValue: initial)
    }

    private var station: Station? {
        stationID.flatMap { model.network.station($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let station {
                    board(for: station)
                } else {
                    VStack(spacing: 14) {
                        MessageCard(
                            symbol: "tram.fill",
                            title: "Choose a station",
                            message: "See every train leaving it, in each direction."
                        )
                        Button("Choose a station") { choosing = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(station?.name ?? "Station board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Change") { choosing = true }
                }
            }
            .sheet(isPresented: $choosing) {
                StationChooser { chosen in
                    stationID = chosen
                    choosing = false
                }
            }
        }
    }

    // MARK: - The board

    private func board(for station: Station) -> some View {
        // Redrawn every fifteen seconds: the countdowns are minutes, and a board that
        // is a minute stale shows a train that has gone.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let rows = model.stationBoard(at: station.id, asOf: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty {
                        MessageCard(
                            symbol: "moon.zzz",
                            title: "Nothing leaving soon",
                            message: "No trains in the next hour and a half. Service may have stopped for the night."
                        )
                    } else {
                        ForEach(platforms(from: rows), id: \.title) { platform in
                            platformCard(platform, now: context.date)
                        }
                    }
                    Text("Scheduled times, not live. A train may be running early or late.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
                .padding(12)
            }
        }
    }

    private struct Platform {
        var title: String
        var rows: [StationDeparture]
    }

    /// One card per direction, the way the platforms are laid out, ordered by whichever
    /// has a train leaving first.
    private func platforms(from rows: [StationDeparture]) -> [Platform] {
        var order: [String] = []
        var grouped: [String: [StationDeparture]] = [:]
        for row in rows {
            let key = row.platformTitle
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        return order.map { Platform(title: $0, rows: Array((grouped[$0] ?? []).prefix(rowsPerPlatform))) }
    }

    private func platformCard(_ platform: Platform, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: platform.title)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ForEach(Array(platform.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 52) }
                departureRow(row, now: now)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func departureRow(_ row: StationDeparture, now: Date) -> some View {
        let line = model.network.line(row.lineID)
        let remaining = row.departure.timeIntervalSince(now)
        return HStack(spacing: 10) {
            LineBadge(
                text: row.routeBadge,
                color: Theme.color(for: line),
                textColor: Theme.foreground(on: line),
                size: 28
            )
            Text(row.serviceHeadline)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(remaining <= 0 ? "now" : Format.countdown(remaining))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(Format.clock(row.departure))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(row, remaining: remaining))
    }

    private func spoken(_ row: StationDeparture, remaining: TimeInterval) -> String {
        var parts: [String] = [row.routeBadge, row.platformTitle, row.serviceHeadline]
        parts.append("leaves at \(Format.clock(row.departure))")
        if remaining > 0 { parts.append("in \(Format.minutes(remaining))") }
        return parts.joined(separator: ", ")
    }
}

/// A searchable list of every station, grouped by line.
private struct StationChooser: View {
    @EnvironmentObject private var model: CommuteModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var sections: [(line: Line, stations: [Station])] = []
    var onChoose: (StationID) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.line.id) { section in
                    Section(section.line.name) {
                        ForEach(section.stations) { station in
                            Button(station.name) { onChoose(station.id) }
                                .foregroundStyle(.primary)
                        }
                    }
                }
                if filtered.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Station name")
            .navigationTitle("Choose a station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Built once: ordering every station on every keystroke is the slow part.
            .task { if sections.isEmpty { sections = model.stationSections } }
        }
    }

    private var filtered: [(line: Line, stations: [Station])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.stations.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return matches.isEmpty ? nil : (line: section.line, stations: matches)
        }
    }
}
