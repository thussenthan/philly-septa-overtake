import SwiftUI
import UIKit

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
                    Text("Longest walk to a station")
                    Spacer()
                    Text("\(Int(model.preferences.maxWalkMinutes)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.maxWalkMinutes, in: 5...30, step: 1)
                    .accessibilityLabel("Longest walk to a station")
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
                LabeledContent("Valid through", value: until)
            }
            LabeledContent("Stations", value: "\(model.network.stations.count)")
            LabeledContent("Stopping patterns", value: "\(model.network.patterns.count)")
            Link(destination: URL(string: "https://www.septa.org/alerts/")!) {
                Label("SEPTA service alerts", systemImage: "exclamationmark.bubble")
            }
        } header: {
            Text("Timetable")
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

    private var aboutSection: some View {
        Section {
            NavigationLink("How the ranking works") { RankingExplainerView() }
            Link(destination: BugReport.url(network: model.network)) {
                Label("Report a bug", systemImage: "ladybug")
            }
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
                paragraph("Two options that get you there the same minute are shown as one. Arriving together, the longer of the two only asks you to set off earlier for nothing — usually it is the nearer station, where you'd stand on the platform for the difference.")
                paragraph("Below arrival time, the order is: the trip that takes less of your day, then the one that walks you less, then the one that keeps you on a train for less of it, then the one that leaves you waiting less.")
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

        var components = URLComponents(string: "https://github.com/thussenthan/philly-septa/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: ""),
            URLQueryItem(name: "body", value: body),
        ]
        // Falls back to the plain issues page: a button that opens the wrong thing is
        // still better than one that does nothing.
        return components.url ?? URL(string: "https://github.com/thussenthan/philly-septa/issues")!
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
