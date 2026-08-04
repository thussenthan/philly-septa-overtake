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

                Section("Stations, north to south") {
                    ForEach(filteredStations) { station in
                        row(
                            symbol: "tram.fill",
                            title: station.displayName,
                            subtitle: station.intersection ?? "",
                            isSelected: selection == .station(station.id),
                            accessory: station.isAccessible == true ? "figure.roll" : nil
                        ) {
                            selection = .station(station.id)
                            dismiss()
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a station")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filteredStations: [Station] {
        let stations = model.stationsNorthToSouth
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return stations }
        return stations.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.intersection ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func row(
        symbol: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        accessory: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(Theme.accent)
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

                Section("Start from a station") {
                    ForEach(filteredStations) { station in
                        Button {
                            selection = .station(station.id)
                            dismiss()
                        } label: {
                            labelRow(
                                symbol: "tram.fill",
                                title: station.displayName,
                                subtitle: station.intersection ?? "",
                                isSelected: selection == .station(station.id)
                            )
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a station")
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

    private var filteredStations: [Station] {
        let stations = model.stationsNorthToSouth
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return stations }
        return stations.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.intersection ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func labelRow(symbol: String, title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(Theme.accent)
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
