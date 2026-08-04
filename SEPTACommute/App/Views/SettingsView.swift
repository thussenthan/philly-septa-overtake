import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: CommuteModel
    // Observed directly rather than through the model: a change to the store has
    // to redraw these rows, and CommuteModel does not republish it.
    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var addingRole: SavedPlace.Role?

    var body: some View {
        NavigationStack {
            Form {
                placesSection
                walkingSection
                routingSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Places

    private var placesSection: some View {
        Section {
            ForEach([SavedPlace.Role.home, .school], id: \.self) { role in
                placeRow(role: role)
            }
            ForEach(places.custom) { place in
                HStack {
                    Image(systemName: place.role.symbol).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name)
                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        places.remove(place)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                addingRole = .custom
            } label: {
                Label("Add another place", systemImage: "plus.circle")
            }
        } header: {
            Text("Places")
        } footer: {
            Text("Stored on this device only. Nothing is uploaded — the app has no server and makes no network calls other than Apple's map lookups.")
        }
        .sheet(item: $addingRole) { role in
            AddPlaceSheet(role: role).environmentObject(places)
        }
    }

    private func placeRow(role: SavedPlace.Role) -> some View {
        Button {
            addingRole = role
        } label: {
            HStack {
                Image(systemName: role.symbol).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.title).foregroundStyle(.primary)
                    Text(places.place(for: role)?.address ?? "Not set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Walking

    private var walkingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Walking pace")
                    Spacer()
                    Text(String(format: "%.1f mph", model.preferences.walkingMilesPerHour))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.walkingMilesPerHour, in: 2.0...4.5, step: 0.1)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Longest walk to a station")
                    Spacer()
                    Text("\(Int(model.preferences.maxWalkMinutes)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.maxWalkMinutes, in: 5...30, step: 1)
            }
            Toggle("Use real walking directions", isOn: $model.preferences.useMeasuredWalkTimes)
        } header: {
            Text("Walking")
        } footer: {
            Text("With walking directions off, walks are estimated from straight-line distance with an allowance for the street grid — accurate enough to choose between stations, and it works with no signal.")
        }
    }

    // MARK: - Routing

    private var routingSection: some View {
        Section {
            Toggle("Suggest changing trains", isOn: $model.preferences.allowTransfers)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Safety margin before boarding")
                    Spacer()
                    Text("\(Int(model.preferences.boardingBufferSeconds))s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.boardingBufferSeconds, in: 0...180, step: 15)
            }
        } header: {
            Text("Routing")
        } footer: {
            Text("Turning off train changes hides the local-then-express trick, which is often the fastest way out of a station the express skips.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            LabeledContent("Source", value: model.network.provenance.source)
            LabeledContent("Generated", value: model.network.provenance.generated)
            if let until = model.network.provenance.validUntil {
                LabeledContent("Valid through", value: until)
            }
            LabeledContent("Stations", value: "\(model.network.stations.count)")
            LabeledContent("Stopping patterns", value: "\(model.network.patterns.count)")
            Link(destination: URL(string: "https://www.septa.org/alerts/")!) {
                Label("SEPTA service alerts", systemImage: "exclamationmark.bubble")
            }
        } header: {
            Text("Timetable")
        } footer: {
            Text("Built from SEPTA's published GTFS feed. These are scheduled times — the app does not know about delays, so check SEPTA's alerts if something looks wrong.")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink("How the ranking works") { RankingExplainerView() }
        } header: {
            Text("About")
        }
    }
}

/// Explains the ordering so a rider can trust it — or overrule it.
struct RankingExplainerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Options are sorted by when you actually arrive at the door, not by which train leaves first.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                paragraph("Every option shown is one you can still catch. If the walk to the station is longer than the time until the train leaves, it isn't listed.")
                paragraph("An option is hidden only when another is at least as good on all of: arrival time, number of train changes, walking time, and how late you can leave. That last one is why a slower train sometimes still appears — it may let you leave ten minutes later.")
                paragraph("\"Leave in …\" counts down to the last moment you can set off and still make the train, including the walk and a safety margin you can adjust.")
                paragraph("On the Broad Street Line, the express skips fourteen of the line's twenty-two stations and only runs weekday peaks between Fern Rock and Walnut-Locust. It never goes to South Philadelphia, so for anything south of Walnut-Locust the local is the only train.")
                paragraph("The Broad-Ridge Spur also runs fast on Broad St and stops at Fairmount, which the express skips — so for some trips the Spur beats both.")
                paragraph("Between about midnight and 5 AM the trains stop and SEPTA runs the B1 Owl bus along Broad St at street level. Those trips are shown too, boarding at the curb rather than in the station.")
            }
            .padding(20)
        }
        .navigationTitle("Ranking")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sheet for setting or replacing one saved place.
struct AddPlaceSheet: View {
    var role: SavedPlace.Role

    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if role == .custom {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Name")
                            TextField("Clinic, gym, a friend's place…", text: $customName)
                                .padding(12)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Address")
                        AddressField(role: role, prompt: promptText) { address, coordinate in
                            places.save(SavedPlace(
                                role: role,
                                name: role == .custom
                                    ? (customName.isEmpty ? address : customName)
                                    : role.title,
                                address: address,
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude
                            ))
                            dismiss()
                        }
                    }

                    Text("Start typing and pick a match. Results are biased to the Philadelphia area.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle(role == .custom ? "New place" : role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var promptText: String {
        switch role {
        case .home: return "Home address"
        case .school: return "Work or school address"
        case .custom: return "Address"
        }
    }
}
