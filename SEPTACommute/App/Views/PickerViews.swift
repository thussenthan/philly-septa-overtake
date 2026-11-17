import SwiftUI

/// Choose where the trip ends: a saved place, or any station on the line.
struct DestinationPickerView: View {
    var title: String
    @Binding var selection: Target?

    @EnvironmentObject private var model: CommuteModel
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var recents: RecentPlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @StateObject private var addresses = AddressSearch()

    var body: some View {
        NavigationStack {
            List {
                // Handing the choice back to the app. The guess is what makes the
                // home screen answer the question without being asked, so once a
                // rider has overridden it they need a way back.
                if model.hasManualTarget, search.isEmpty {
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

                let saved = StationSearch.places(places.places, matching: search)
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(saved) { place in
                            Button {
                                selection = .saved(place)
                                dismiss()
                            } label: {
                                PickerRow(
                                    symbol: place.role.symbol,
                                    title: place.name,
                                    subtitle: place.address,
                                    isSelected: selection == .saved(place)
                                )
                            }
                        }
                    }
                }

                AddressResultsSection(search: search, addresses: addresses) { place in
                    model.registerOneOff(place)
                    recents.record(place, saved: places.places)
                    selection = .saved(place)
                    dismiss()
                }

                if search.isEmpty {
                    RecentPlacesSection { place in
                        model.registerOneOff(place)
                        recents.record(place, saved: places.places)
                        selection = .saved(place)
                        dismiss()
                    }
                }

                if search.isEmpty {
                    NearbyStationsSection(isSelected: { selection == .station($0) }) { id in
                        selection = .station(id)
                        dismiss()
                    }
                }

                ForEach(filteredSections, id: \.line.id) { section in
                    Section {
                        ForEach(section.stations) { station in
                            Button {
                                selection = .station(station.id)
                                dismiss()
                            } label: {
                                PickerRow(
                                    symbol: "tram.fill",
                                    title: station.displayName,
                                    subtitle: station.intersection ?? "",
                                    isSelected: selection == .station(station.id),
                                    showsStepFree: station.isAccessible == true,
                                    tint: Theme.color(for: section.line)
                                )
                            }
                        }
                    } header: {
                        LineSectionHeader(line: section.line)
                    }
                }
            }
            .searchable(text: $search, prompt: "Station, address, place or lat, lon")
            .onChange(of: search) { _, new in addresses.query = new }
            .overlay {
                if filteredSections.isEmpty && !search.isEmpty
                    && StationSearch.places(places.places, matching: search).isEmpty
                    && addresses.allSuggestions.isEmpty && Coordinate.parse(search) == nil {
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

    private var filteredSections: [(line: Line, stations: [Station])] {
        StationSearch.sections(model.stationSections, matching: search)
    }
}

/// Choose where the trip starts.
struct OriginPickerView: View {
    @Binding var selection: Source

    @EnvironmentObject private var model: CommuteModel
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var recents: RecentPlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @StateObject private var addresses = AddressSearch()

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section {
                        Button {
                            selection = .currentLocation
                            model.locationService.requestPermissionIfNeeded()
                            dismiss()
                        } label: {
                            PickerRow(
                                symbol: "location.fill",
                                title: "Where I am now",
                                subtitle: currentLocationSubtitle,
                                isSelected: selection == .currentLocation
                            )
                        }
                    }
                }

                let saved = StationSearch.places(places.places, matching: search)
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(saved) { place in
                            Button {
                                selection = .saved(place)
                                dismiss()
                            } label: {
                                PickerRow(
                                    symbol: place.role.symbol,
                                    title: place.name,
                                    subtitle: place.address,
                                    isSelected: selection == .saved(place)
                                )
                            }
                        }
                    }
                }

                AddressResultsSection(search: search, addresses: addresses) { place in
                    model.registerOneOff(place)
                    recents.record(place, saved: places.places)
                    selection = .saved(place)
                    dismiss()
                }

                if search.isEmpty {
                    RecentPlacesSection { place in
                        model.registerOneOff(place)
                        recents.record(place, saved: places.places)
                        selection = .saved(place)
                        dismiss()
                    }
                }

                if search.isEmpty {
                    NearbyStationsSection(isSelected: { selection == .station($0) }) { id in
                        selection = .station(id)
                        dismiss()
                    }
                }

                ForEach(filteredSections, id: \.line.id) { section in
                    Section {
                        ForEach(section.stations) { station in
                            Button {
                                selection = .station(station.id)
                                dismiss()
                            } label: {
                                PickerRow(
                                    symbol: "tram.fill",
                                    title: station.displayName,
                                    subtitle: station.intersection ?? "",
                                    isSelected: selection == .station(station.id),
                                    showsStepFree: station.isAccessible == true,
                                    tint: Theme.color(for: section.line)
                                )
                            }
                        }
                    } header: {
                        LineSectionHeader(line: section.line)
                    }
                }
            }
            .searchable(text: $search, prompt: "Station, address, place or lat, lon")
            .onChange(of: search) { _, new in addresses.query = new }
            .overlay {
                if filteredSections.isEmpty && !search.isEmpty
                    && StationSearch.places(places.places, matching: search).isEmpty
                    && addresses.allSuggestions.isEmpty && Coordinate.parse(search) == nil {
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

    private var filteredSections: [(line: Line, stations: [Station])] {
        StationSearch.sections(model.stationSections, matching: search)
    }
}

// MARK: - Shared pieces

/// Places searched for before, for a repeat trip in one tap.
struct RecentPlacesSection: View {
    var onChoose: (SavedPlace) -> Void

    @EnvironmentObject private var recents: RecentPlaceStore
    @EnvironmentObject private var places: PlaceStore

    var body: some View {
        let recent = recents.recents(excluding: places.places)
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { item in
                    Button {
                        onChoose(recents.asPlace(item))
                    } label: {
                        PickerRow(symbol: "clock.arrow.circlepath", title: item.name,
                                  subtitle: item.address, isSelected: false)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { recents.remove(item) }
                    }
                }
            }
        }
    }
}

/// Addresses and places anywhere SEPTA runs, found as the rider types.
///
/// Stations and saved places only covered where the rider already knew to look;
/// a trip to somewhere new (an office, a friend's house, "Conshohocken") had no
/// way in. A choice here is a one-off place: it plans the trip but is not added to
/// the saved list.
struct AddressResultsSection: View {
    var search: String
    @ObservedObject var addresses: AddressSearch
    var onChoose: (SavedPlace) -> Void

    @State private var resolving: String?

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let typed = Coordinate.parse(query).map {
            AddressSearch.Suggestion(
                title: String(format: "%.5f, %.5f", $0.latitude, $0.longitude),
                subtitle: "Coordinates", coordinate: $0)
        }
        let found = (typed.map { [$0] } ?? []) + addresses.allSuggestions
        if !query.isEmpty, !found.isEmpty {
            Section("Addresses and places") {
                ForEach(found.prefix(10)) { suggestion in
                    Button {
                        choose(suggestion)
                    } label: {
                        HStack {
                            PickerRow(symbol: suggestion.subtitle == "Coordinates" ? "scope" : "mappin.circle.fill",
                                      title: suggestion.title,
                                      subtitle: suggestion.subtitle,
                                      isSelected: false)
                            if resolving == suggestion.id { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(resolving != nil)
                }
            }
        }
        if let error = addresses.errorMessage, !query.isEmpty {
            Section { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func choose(_ suggestion: AddressSearch.Suggestion) {
        resolving = suggestion.id
        Task {
            if let found = await addresses.resolve(suggestion) {
                let place = SavedPlace(role: .custom, name: suggestion.title,
                                       address: suggestion.subtitle == "Coordinates" ? suggestion.title : found.address,
                                       latitude: found.coordinate.latitude, longitude: found.coordinate.longitude)
                onChoose(place)
            }
            resolving = nil
        }
    }
}

/// The search every picker runs, in one place so they can't drift apart.
enum StationSearch {
    static func sections(
        _ sections: [(line: Line, stations: [Station])],
        matching search: String
    ) -> [(line: Line, stations: [Station])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let found = section.stations.filter { Self.matches($0, query) }
            return found.isEmpty ? nil : (line: section.line, stations: found)
        }
    }

    /// Saved places are searched too: typing "work" into a list headed "Find a
    /// station" and getting nothing was the one place that stayed put.
    static func places(_ places: [SavedPlace], matching search: String) -> [SavedPlace] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return places }
        return places.filter {
            $0.name.localizedStandardContains(query) || $0.address.localizedStandardContains(query)
        }
    }

    /// Case- and accent-insensitive, against the name and the cross streets — riders
    /// know "Broad & Erie" as well as they know "Erie".
    static func matches(_ station: Station, _ query: String) -> Bool {
        station.displayName.localizedStandardContains(query)
            || (station.intersection ?? "").localizedStandardContains(query)
    }
}

/// The stations within a short walk, nearest first, with how far each is.
///
/// Empty — and so absent — without a location fix.
struct NearbyStationsSection: View {
    var isSelected: (StationID) -> Bool
    var onChoose: (StationID) -> Void

    @EnvironmentObject private var model: CommuteModel

    var body: some View {
        let nearby = model.nearbyStations()
        if !nearby.isEmpty {
            Section("Nearby") {
                ForEach(nearby, id: \.station.id) { entry in
                    Button {
                        onChoose(entry.station.id)
                    } label: {
                        PickerRow(
                            symbol: "location.circle.fill",
                            title: entry.station.displayName,
                            subtitle: subtitle(for: entry.station, meters: entry.meters),
                            isSelected: isSelected(entry.station.id),
                            showsStepFree: entry.station.isAccessible == true,
                            tint: Theme.color(for: entry.station.lines.first.flatMap { model.network.line($0) })
                        )
                    }
                }
            }
        }
    }

    private func subtitle(for station: Station, meters: Double) -> String {
        let badges = station.lines.compactMap { model.network.line($0)?.badge }
        var parts = [meters < 60 ? "You're here" : Format.distance(meters: meters)]
        if !badges.isEmpty { parts.append(badges.joined(separator: " · ")) }
        return parts.joined(separator: " · ")
    }
}

/// A line's badge and name, as a section header.
struct LineSectionHeader: View {
    var line: Line

    var body: some View {
        HStack(spacing: 7) {
            LineBadge(text: line.badge, color: Theme.color(for: line),
                      textColor: Theme.foreground(on: line), size: 19)
            Text(line.name)
        }
    }
}

/// One choosable row: an icon, a name, a line of detail, and a tick if it's current.
struct PickerRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var isSelected: Bool
    var showsStepFree = false
    var tint: Color = Theme.accent

    var body: some View {
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
            if showsStepFree {
                Image(systemName: "figure.roll")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Elevator access")
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
