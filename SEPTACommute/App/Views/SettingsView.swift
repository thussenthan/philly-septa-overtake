import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: CommuteModel
    // Observed directly rather than through the model: a change to the store has
    // to redraw these rows, and CommuteModel does not republish it.
    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    /// The decimal pad has no return key; this is what the keyboard's Done clears.
    @FocusState private var editingValue: Bool

    var body: some View {
        NavigationStack {
            Form {
                placesSection
                walkingSection
                routingSection
                appearanceSection
                valueSection
                moreWaysSection
                dataSection
                aboutSection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingValue = false }
                }
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
                NavigationLink {
                    PlaceEditor(role: .custom, editing: place)
                } label: {
                    HStack {
                        Image(systemName: place.role.symbol).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name)
                            Text(place.address).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                // A swipe, with the confirmation that gives: a small red icon beside
                // the text deleted a saved place on a slightly-off tap, and VoiceOver
                // read it as nothing at all.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        places.remove(place)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            NavigationLink {
                PlaceEditor(role: .custom)
            } label: {
                Label("Add another place", systemImage: "plus.circle")
            }
        } header: {
            Text("Places")
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

    // MARK: - Value of time

    /// The rider's time, priced. Blank turns value ranking off.
    private var valueBinding: Binding<Double?> {
        Binding(
            get: { model.preferences.valueOfTimePerHour },
            set: { model.preferences.valueOfTimePerHour = ($0 ?? 0) > 0 ? $0 : nil }
        )
    }

    private var valueSection: some View {
        Section {
            HStack {
                Text("My time is worth")
                Spacer()
                TextField(
                    "",
                    value: valueBinding,
                    format: .currency(code: "USD").precision(.fractionLength(0...2)),
                    prompt: Text("$\(Int(RiderPreferences.defaultHourlyValue))")
                )
                .keyboardType(.decimalPad)
                .focused($editingValue)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                Text("/ hour").foregroundStyle(.secondary)
            }
            if model.preferences.valueOfTimePerHour == nil {
                Button("Use $\(Int(RiderPreferences.defaultHourlyValue))/hour") {
                    model.preferences.valueOfTimePerHour = RiderPreferences.defaultHourlyValue
                }
            }
        } header: {
            Text("Value of your time")
        } footer: {
            // Only a hint for an empty field. What the number does is explained
            // under About → How it works, not on the front of Settings.
            if model.preferences.valueOfTimePerHour == nil {
                Text("Try your hourly wage.")
            }
        }
    }

    // MARK: - More ways to go

    @ViewBuilder
    private var moreWaysSection: some View {
        Section {
            Toggle("Show alternative routes", isOn: $model.preferences.showAllSEPTA)
            Picker("Directions in", selection: $model.preferences.mapsApp) {
                ForEach(MapsApp.allCases) { app in
                    Text(app.label).tag(app)
                }
            }
            Toggle("Show Indego bike share", isOn: $model.preferences.showIndego)
            if model.preferences.showIndego {
                Picker("Indego pass", selection: $model.preferences.indegoPass) {
                    ForEach(IndegoPass.allCases) { pass in
                        Text(pass.label).tag(pass)
                    }
                }
            }
        } header: {
            Text("More ways to go")
        }

        Section {
            CarFields(hasCar: $model.preferences.hasCar, car: $model.preferences.car)
        } header: {
            Text("Your car")
        } footer: {
            if model.preferences.hasCar && model.preferences.valueOfTimePerHour == nil {
                Text("Set your time's value to compare driving.")
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
                    .accessibilityLabel("Walking pace")
                    .accessibilityValue(String(format: "%.1f miles per hour", model.preferences.walkingMilesPerHour))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Longest walk to a stop")
                    Spacer()
                    Text("\(Int(model.preferences.maxWalkMinutes)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.maxWalkMinutes, in: 5...40, step: 1)
                    .accessibilityLabel("Longest walk to a station, stop or bike dock")
                    .accessibilityValue("\(Int(model.preferences.maxWalkMinutes)) minutes")
            }
            Toggle("Use real walking directions", isOn: $model.preferences.useMeasuredWalkTimes)
        } header: {
            Text("Walking")
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
                    .accessibilityLabel("Safety margin before boarding")
                    .accessibilityValue("\(Int(model.preferences.boardingBufferSeconds)) seconds")
            }
        } header: {
            Text("Routing")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            LabeledContent("Source", value: model.network.provenance.source)
            LabeledContent("Generated", value: model.network.provenance.generated)
            if let until = model.network.provenance.validUntil {
                LabeledContent("Valid through", value: CommuteModel.humanDate(until))
            }
            LabeledContent("Stations", value: "\(model.network.stations.count)")
            LabeledContent("Stopping patterns", value: "\(model.network.patterns.count)")
            notesLink
            // Last, because it leaves the app.
            Link(destination: URL(string: "https://www.septa.org/alerts/")!) {
                Label("SEPTA service alerts", systemImage: "exclamationmark.bubble")
            }
        } header: {
            Text("Timetable")
        } footer: {
            Text("Times are scheduled, not live. Trains can run early or late.")
        }
    }

    /// The planner's caveats are background reading, so they sit last and look like
    /// every other row. A live SEPTA alert is not, and says what it is.
    @ViewBuilder
    private var notesLink: some View {
        NavigationLink {
            ServiceNotesView()
        } label: {
            if model.serviceAlerts.isEmpty {
                Label(model.noteMessages.count > 1 ? "Notes" : "Note", systemImage: "info.circle")
                    .foregroundStyle(Theme.accent)
            } else {
                Label(model.serviceStatusSummary, systemImage: model.serviceStatusSymbol)
            }
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
        }
    }

    /// Back to the first-launch screen, for a phone changing hands or a move.
    private var resetSection: some View {
        Section {
            Button("Reset saved places", role: .destructive) {
                confirmingReset = true
            }
            .confirmationDialog(
                "Remove all saved places?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Remove places", role: .destructive) {
                    // Closed first: wiping the store swaps the screen underneath this
                    // sheet for onboarding.
                    dismiss()
                    let store = places
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        store.removeAll()
                    }
                }
            } message: {
                Text("Home, \(places.school?.name ?? "work") and any other places are removed from this phone. Your settings are kept, and the app will walk you through setting places up again.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink("How it works") { RankingExplainerView() }
            NavigationLink("Data & credits") { CreditsView() }
            Link(destination: BugReport.url(network: model.network)) {
                Label("Report a bug", systemImage: "ladybug")
            }
        } header: {
            Text("About")
        }
    }
}

/// Where the data comes from, and who this app is not.
struct CreditsView: View {
    var body: some View {
        List {
            Section("SEPTA") {
                Text("Timetables, fares, route shapes · service alerts")
                Link("Developer licence", destination: URL(string: "https://www.septa.org/license-agreement/")!)
            }
            Section("Indego") {
                Text("Live dock counts · published prices")
                Link("Indego pricing", destination: URL(string: "https://www.rideindego.com/pricing/")!)
            }
            Section("Maps") {
                Text("Apple Maps · elevation from Open-Meteo")
            }
            Section {
                Text("Not affiliated with SEPTA, Indego, the City of Philadelphia, Bicycle Transit Systems or BCycle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data & credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// How the app decides, in short bullets grouped by topic.
struct RankingExplainerView: View {
    var body: some View {
        List {
            topic("Fares", symbol: "creditcard", [
                "Every fare assumes you tap a contactless card or phone, or SEPTA Key.",
                "That makes changes free within 2 hours, up to 2 of them.",
                "Cash and Quick Trip pay again at every boarding; the app doesn't count that.",
            ])
            topic("The answer", symbol: "clock", [
                "Sorted by when you reach the door, not by which train leaves first.",
                "Only trains you can still catch, walk included.",
                "\u{201C}Leave in\u{201D} counts down to the last moment to set off, safety margin included.",
                "A slower train stays listed if it lets you leave later.",
            ])
            topic("Broad Street Line", symbol: "tram", [
                "The B2 express skips 14 of 22 stations and runs weekday peaks only.",
                "It never goes south of Walnut-Locust.",
                "The B3 Spur also runs fast, and stops at Fairmount.",
                "Late at night the B1 Owl bus runs along Broad St instead.",
            ])
            topic("Alternative routes", symbol: "arrow.triangle.branch", [
                "Buses, trolleys, Metro and Regional Rail, searched on equal terms.",
                "Shown only if nothing else is both cheaper and sooner.",
                "SEPTA Key fares · published schedule, not live.",
            ])
            topic("Indego", symbol: "bicycle", [
                "Live dock counts · walk, ride and walk all counted.",
                "Ride time includes the climb; uphill, the e-bike is suggested.",
                "Price is what the ride adds to your pass.",
            ])
            Section {
                ForEach(IndegoPass.allCases) { pass in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pass.label).font(.subheadline)
                        Text(pass.passPriceNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Indego passes")
            }
            topic("Best value", symbol: "dollarsign.circle", [
                "Fare + door-to-door time at your hourly rate.",
                "Climbing on a classic bike counts twice: time and effort.",
                "Driving: up to six routes with live traffic, plus the best toll-free one.",
                "Cost: gas from your mpg, 10¢/mi wear, parking and tolls.",
                "Tolls come from HERE, priced with a transponder (E-ZPass). Add a free HERE key under Your car.",
                "Without a key, routes with tolls are left out rather than guessed.",
                "Walking the whole way counts too, timed by Apple Maps.",
                "Doesn't change the main answer.",
            ])
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topic(_ title: String, symbol: String, _ points: [String]) -> some View {
        Section {
            ForEach(points, id: \.self) { point in
                Text(point).font(.subheadline)
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Sets, renames or replaces one saved place.
///
/// Pushed onto the Settings stack rather than presented as a sheet. Settings is
/// itself a sheet, and a sheet presenting a sheet is the arrangement that was
/// closing both of them — a push has no such problem, and reads better besides:
/// this is a detail of the row you tapped, not a separate errand.
struct PlaceEditor: View {
    var role: SavedPlace.Role
    /// The place being changed. Home and Work are found by role; an extra place has
    /// to be named, because there can be any number of them — looking one up by role
    /// opened "add another place" pre-filled with the first one.
    var editing: SavedPlace?

    @EnvironmentObject private var places: PlaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var chosenName = ""
    @State private var confirmingRemoval = false

    init(role: SavedPlace.Role, editing: SavedPlace? = nil) {
        self.role = role
        self.editing = editing
    }

    /// What is on file now, if anything.
    private var existing: SavedPlace? {
        if let editing { return places.places.first { $0.id == editing.id } ?? editing }
        return role == .custom ? nil : places.place(for: role)
    }

    private var typedName: String {
        chosenName.trimmingCharacters(in: .whitespaces)
    }

    /// A new name for a place that already has an address doesn't need the address
    /// typed again.
    private var canRename: Bool {
        guard role.isRenameable, let existing else { return false }
        return !typedName.isEmpty && typedName != existing.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if role.isRenameable {
                    PlaceNameField(role: role, name: $chosenName)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: existing == nil ? "Address" : "New address")
                    AddressField(role: role, prompt: promptText) { address, coordinate in
                        places.save(SavedPlace(
                            // Kept, so anything pointing at this place follows the edit.
                            id: existing?.id ?? UUID(),
                            role: role,
                            name: resolvedName(typed: typedName, address: address),
                            address: address,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        ))
                        dismiss()
                    }
                }

                if let existing {
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

                // Home stays: it is what the whole guess about direction hangs on.
                if let existing, role != .home {
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Remove \(existing.name)", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .padding(.top, 6)
                    .confirmationDialog(
                        "Remove \(existing.name)?",
                        isPresented: $confirmingRemoval,
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            places.remove(existing)
                            dismiss()
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canRename, let existing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var renamed = existing
                        renamed.name = typedName
                        places.save(renamed)
                        dismiss()
                    }
                }
            }
        }
        // Pre-filled with whatever it is called now, so reopening the row to correct
        // an address doesn't silently rename the place.
        .onAppear {
            if chosenName.isEmpty {
                chosenName = existing?.name ?? (role == .custom ? "" : role.title)
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
        case .school: return existing?.name ?? role.unsetTitle
        case .custom: return existing?.name ?? "New place"
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
    /// Off where the section header already says what this is.
    var showsLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel { SectionLabel(text: "Call it") }
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
        role == .custom ? "Clinic, gym, a friend’s place…" : "Name it, e.g. Work"
    }
}


/// Where a bug report goes, and what rides along with it.
///
/// A GitHub issue rather than an email: there is no server behind this app and no
/// address worth publishing in it, and an issue is somewhere the fix can be tracked
/// in the open.
///
/// The body is pre-filled with the four things every report needs and nobody thinks
/// to include. None of them say anything about the rider — not where they live, not
/// where they were, not where they were going. A bug report is exactly the moment an
/// app is most tempted to collect all of that, and it doesn't.
enum BugReport {
    static func url(network: Network) -> URL {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body = """
        **What happened?**


        **What did you expect?**


        ---
        \(AppIdentity.name.capitalized) \(version) (\(build))
        iOS \(UIDevice.current.systemVersion) · \(deviceModel)
        Timetable \(network.provenance.source)
        """

        var components = URLComponents(string: "https://github.com/thussenthan/philly-septa-overtake/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: ""),
            URLQueryItem(name: "body", value: body),
        ]
        // Falls back to the plain issues page: a button that opens the wrong thing is
        // still better than one that does nothing.
        return components.url ?? URL(string: "https://github.com/thussenthan/philly-septa-overtake/issues")!
    }

    /// The hardware identifier — "iPhone15,3" — which is what actually distinguishes
    /// a layout bug on a Pro Max from one everywhere.
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            raw.prefix { $0 != 0 }.map { Character(UnicodeScalar($0)) }
        }
        return String(identifier)
    }
}
