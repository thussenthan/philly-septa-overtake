import SwiftUI

/// Choose where the trip ends: a saved place, or any station on the line.
struct DestinationPickerView: View {
    var title: String
    @Binding var selection: Target?

    @EnvironmentObject private var model: CommuteModel
    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                // Handing the choice back to the app. The guess is what makes the
                // home screen answer the question without being asked, so once a
                // rider has overridden it they need a way back.
                if model.hasManualTarget {
                    Section {
                        Button {
                            model.resumeAutomaticTarget()
                            dismiss()
                        } label: {
                            Label("Choose for me", systemImage: "wand.and.stars")
                        }
                    } footer: {
                        Text("Near home means you're heading out; anywhere else means you're heading home.")
                    }
                }

                if !places.places.isEmpty {
                    Section("Saved") {
                        ForEach(places.places) { place in
                            row(
                                symbol: place.role.symbol,
                                title: place.name,
                                subtitle: place.address,
                                isSelected: selection == .saved(place)
                            ) {
                                selection = .saved(place)
                                dismiss()
                            }
                        }
                    }
                }

                ForEach(filteredSections, id: \.line.id) { section in
                    Section {
                        ForEach(section.stations) { station in
                            row(
                                symbol: "tram.fill",
                                title: station.displayName,
                                subtitle: station.intersection ?? "",
                                isSelected: selection == .station(station.id),
                                accessory: station.isAccessible == true ? "figure.roll" : nil,
                                tint: Theme.color(for: section.line)
                            ) {
                                selection = .station(station.id)
                                dismiss()
                            }
                        }
                    } header: {
                        lineHeader(section.line)
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a station")
            .overlay {
                if filteredSections.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Sections of stations, one per line, filtered by the search text.
    private var filteredSections: [(line: Line, stations: [Station])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.stationSections.compactMap { section in
            guard !query.isEmpty else { return section }
            let matches = section.stations.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || ($0.intersection ?? "").localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : (line: section.line, stations: matches)
        }
    }

    /// A line's badge and name, as the section header.
    @ViewBuilder
    private func lineHeader(_ line: Line) -> some View {
        HStack(spacing: 7) {
            LineBadge(text: line.badge, color: Theme.color(for: line),
                      textColor: Theme.foreground(on: line), size: 19)
            Text(line.name)
        }
    }

    private func row(
        symbol: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        accessory: String? = nil,
        tint: Color = Theme.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let accessory {
                    Image(systemName: accessory)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Elevator access")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

/// Choose where the trip starts.
struct OriginPickerView: View {
    @Binding var selection: Source

    @EnvironmentObject private var model: CommuteModel
    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selection = .currentLocation
                        model.locationService.requestPermissionIfNeeded()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .frame(width: 22)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Where I am now").foregroundStyle(.primary)
                                Text(currentLocationSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selection == .currentLocation {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                if !places.places.isEmpty {
                    Section("Saved") {
                        ForEach(places.places) { place in
                            Button {
                                selection = .saved(place)
                                dismiss()
                            } label: {
                                labelRow(
                                    symbol: place.role.symbol,
                                    title: place.name,
                                    subtitle: place.address,
                                    isSelected: selection == .saved(place)
                                )
                            }
                        }
                    }
                }

                ForEach(filteredSections, id: \.line.id) { section in
                    Section {
                        ForEach(section.stations) { station in
                            Button {
                                selection = .station(station.id)
                                dismiss()
                            } label: {
                                labelRow(
                                    symbol: "tram.fill",
                                    title: station.displayName,
                                    subtitle: station.intersection ?? "",
                                    isSelected: selection == .station(station.id),
                                    tint: Theme.color(for: section.line)
                                )
                            }
                        }
                    } header: {
                        lineHeader(section.line)
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a station")
            .overlay {
                if filteredSections.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Starting from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var currentLocationSubtitle: String {
        if let station = model.currentStation {
            return "You're at \(station.displayName)"
        }
        return model.locationStatusSummary ?? "Uses your device location"
    }

    /// Sections of stations, one per line, filtered by the search text.
    private var filteredSections: [(line: Line, stations: [Station])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.stationSections.compactMap { section in
            guard !query.isEmpty else { return section }
            let matches = section.stations.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || ($0.intersection ?? "").localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : (line: section.line, stations: matches)
        }
    }

    /// A line's badge and name, as the section header.
    @ViewBuilder
    private func lineHeader(_ line: Line) -> some View {
        HStack(spacing: 7) {
            LineBadge(text: line.badge, color: Theme.color(for: line),
                      textColor: Theme.foreground(on: line), size: 19)
            Text(line.name)
        }
    }

    private func labelRow(
        symbol: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        tint: Color = Theme.accent
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}
