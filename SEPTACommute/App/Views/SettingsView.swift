import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: CommuteModel
    // Observed directly rather than through the model: a change to the store has
    // to redraw these rows, and CommuteModel does not republish it.
    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                placesSection
                walkingSection
                routingSection
                appearanceSection
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
                NavigationLink {
                    PlaceEditor(role: role)
                } label: {
                    placeRow(role: role)
                }
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
            NavigationLink {
                PlaceEditor(role: .custom)
            } label: {
                Label("Add another place", systemImage: "plus.circle")
            }
        } header: {
            Text("Places")
        } footer: {
            Text("Stored on this device only. Nothing is uploaded — the app has no server and makes no network calls other than Apple's map lookups.")
        }
    }

    private func placeRow(role: SavedPlace.Role) -> some View {
        HStack {
            Image(systemName: role.symbol).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                // The rider's own name for it once they have given one.
                Text(places.place(for: role)?.name ?? role.unsetTitle)
                    .foregroundStyle(.primary)
                Text(places.place(for: role)?.address ?? "Not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            Toggle("Step-free routes only", isOn: $model.preferences.stepFreeOnly)
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
            Text("Turning off train changes hides the local-then-express trick, which is often the fastest way out of a station the express skips.\n\nStep-free routing uses only stations SEPTA lists as having elevators, for changes as well as for the two ends. On the Broad Street Line that rules out Erie and Fairmount, so it can change the answer rather than just narrow it — the app says when it costs you time.")
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

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $model.preferences.appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Line colours keep SEPTA's hues in both themes, lightened or darkened only as far as they need to be to stay readable.")
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
                paragraph("Two options that get you there the same minute are shown as one: the one that takes less time to make. Arriving together, the longer of the two only asks you to set off earlier for nothing — usually it is the nearer station, where you'd stand on the platform for the difference.")
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

/// Sets or replaces one saved place.
///
/// Pushed onto the Settings stack rather than presented as a sheet. Settings is
/// itself a sheet, and a sheet presenting a sheet is the arrangement that was
/// closing both of them — a push has no such problem, and reads better besides:
/// this is a detail of the row you tapped, not a separate errand.
struct PlaceEditor: View {
    var role: SavedPlace.Role

    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var chosenName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if role.isRenameable {
                    PlaceNameField(role: role, name: $chosenName)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Address")
                    AddressField(role: role, prompt: promptText) { address, coordinate in
                        let typed = chosenName.trimmingCharacters(in: .whitespaces)
                        places.save(SavedPlace(
                            role: role,
                            name: resolvedName(typed: typed, address: address),
                            address: address,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        ))
                        dismiss()
                    }
                }

                if let existing = places.place(for: role) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Currently")
                        Text(existing.address)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Start typing and pick a match. Results are biased to the Philadelphia area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Pre-filled with whatever it is called now, so reopening the row to correct
        // an address doesn't silently rename the place.
        .onAppear {
            if chosenName.isEmpty {
                chosenName = places.place(for: role)?.name ?? (role == .custom ? "" : role.title)
            }
        }
    }

    /// A custom place falls back to its address, which is at least identifiable. The
    /// second anchor falls back to the role's default, since a blank label would
    /// leave an unnamed row on the home screen.
    private func resolvedName(typed: String, address: String) -> String {
        if !typed.isEmpty { return typed }
        return role == .custom ? address : role.title
    }

    private var navigationTitle: String {
        switch role {
        case .home: return role.title
        case .school: return places.place(for: role)?.name ?? role.unsetTitle
        case .custom: return "New place"
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

/// Names a saved place: tap a common one, or type your own.
///
/// The second anchor used to be labelled "Work / School" — a slash standing in for a
/// choice nobody had been asked to make, and which read as two places when it is one.
/// A resident calls it the hospital; a student calls it campus. So it asks.
struct PlaceNameField: View {
    var role: SavedPlace.Role
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Call it")
            TextField(placeholder, text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

            if role == .school {
                HStack(spacing: 8) {
                    ForEach(SavedPlace.Role.awayLabelSuggestions, id: \.self) { suggestion in
                        Button {
                            name = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    name == suggestion ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                                .foregroundStyle(name == suggestion ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var placeholder: String {
        role == .custom ? "Clinic, gym, a friend's place…" : "Work"
    }
}
