import SwiftUI

/// First launch. The app has no idea where anyone lives until this is filled in.
struct OnboardingView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var model: CommuteModel

    @State private var page = 0
    /// What the rider calls the far end of their day. Defaults to "Work" on save.
    @State private var awayName = ""
    /// While typing an address the suggestions need the room; the footer, which
    /// the keyboard pushes up over them, steps aside.
    @State private var isTyping = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                addresses.tag(1)
            }
            // The system page dots float over the content, and with the keyboard
            // up they landed on the address suggestions. Drawn in the footer instead.
            .tabViewStyle(.page(indexDisplayMode: .never))

            if !isTyping { footer }
        }
        .background(Color(.systemGroupedBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { isTyping = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { isTyping = false }
        }
    }

    // MARK: - Pages

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Wordmark(height: 34)
                    Text(AppIdentity.tagline)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The fastest way door to door, worked out minute by minute.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    bullet("clock.badge.exclamationmark",
                           "Wait, or go now?",
                           "The local now, or the express in a few minutes.")
                    bullet("arrow.triangle.swap",
                           "Half and half",
                           "Ride the local, let the express overtake you.")
                    bullet("figure.walk",
                           "Door to door",
                           "Walking counts at both ends.")
                    bullet("bicycle",
                           "More ways",
                           "Buses • Regional Rail • Indego bikes.")
                    bullet("wand.and.stars",
                           "Open it and go",
                           "Near home, it plans the trip out; anywhere else, home.")
                    bullet("hand.raised.fill",
                           "Stays on your phone",
                           "Your addresses never leave the device.")
                }
            }
            .padding(24)
        }
    }

    private var addresses: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your two ends of the day")
                        .font(.title2.weight(.bold))
                    Text("So the app knows which way you're heading. Change them any time in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                addressSection(role: .home, prompt: "Home address")
                addressSection(role: .school, prompt: "Work or school address")
            }
            .padding(24)
        }
    }

    private func addressSection(role: SavedPlace.Role, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: places.place(for: role)?.name ?? role.unsetTitle)
            if let existing = places.place(for: role) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.color(for: .relaxed))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(existing.address)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(nearestStationBlurb(for: existing))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // "Change", not "Edit": it clears the address for a new one rather
                    // than opening this one for editing, and the label should say so.
                    Button("Change") { places.remove(existing) }
                        .font(.footnote)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Clears this address so you can enter another")
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                if role == .school {
                    // Asked here rather than after the fact: naming it is one tap, and
                    // the name is what every later screen calls this end of the trip.
                    PlaceNameField(role: role, name: $awayName, showsLabel: false)
                }
                AddressField(role: role, prompt: prompt) { address, coordinate in
                    let typed = awayName.trimmingCharacters(in: .whitespaces)
                    places.save(SavedPlace(
                        role: role,
                        name: role == .school && !typed.isEmpty ? typed : role.title,
                        address: address,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ))
                }
            }
        }
    }

    /// Nudges towards adding both without making the second one compulsory — a
    /// rider who only ever goes one way should still be able to get past this screen.
    private var doneButtonTitle: String {
        if !places.isConfigured { return "Add an address to continue" }
        if places.home == nil || places.school == nil { return "Continue with one address" }
        return "Done"
    }

    private func nearestStationBlurb(for place: SavedPlace) -> String {
        guard let nearest = model.network.nearestStation(to: place.coordinate) else {
            return "No SEPTA Metro station nearby"
        }
        // Past a half-hour walk "about 94 min on foot" is a number nobody would act
        // on; the distance says the same thing honestly.
        guard nearest.meters <= 2_500 else {
            return "Nearest Metro station is \(nearest.station.name), \(Format.distance(meters: nearest.meters)) away"
        }
        let walk = WalkingModel().egressSeconds(straightLineMeters: nearest.meters)
        return "\(nearest.station.name) • \(Format.minutes(walk)) walk"
    }

    private func bullet(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<2) { index in
                    Circle()
                        .fill(index == page ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of 2")
            if page == 0 {
                Button {
                    withAnimation { page = 1 }
                } label: {
                    Text("Get started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
            } else {
                Button {
                    model.locationService.requestPermissionIfNeeded()
                    places.finishSetup()
                } label: {
                    Text(doneButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(!places.isConfigured)

                Text("Location finds your nearest stop. You can also pick one by hand.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}
