import SwiftUI

/// First launch. The app has no idea where anyone lives until this is filled in.
struct OnboardingView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var model: CommuteModel

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                addresses.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Pages

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    LineBadge(text: "B", size: 52)
                    Text("Which train, right now")
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("SEPTA runs local trains, express trains that skip half the stops, trolleys and the Broad-Ridge Spur, often over the same tracks. Which one gets you where you're going fastest changes minute by minute.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    bullet("clock.badge.exclamationmark",
                           "Wait, or go now?",
                           "Compares boarding the local that's about to leave against holding out for the express.")
                    bullet("arrow.triangle.swap",
                           "Half and half",
                           "Sometimes the trick is riding the local a few stops and letting the express overtake you.")
                    bullet("figure.walk",
                           "Door to door",
                           "Counts the walk at both ends, so \"faster train\" doesn't mean \"longer trip\".")
                    bullet("wand.and.stars",
                           "Open it and you're done",
                           "It guesses where you're going from where you are — near home means you're heading out, anywhere else means you're heading home.")
                    bullet("hand.raised.fill",
                           "Stays on your phone",
                           "Timetables are built in. Your addresses never leave the device.")
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
                    Text("Add both and the app can guess which way you're going the moment you open it. You can change these any time in Settings.")
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
            SectionLabel(text: role.title)
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
                    Button("Change") { places.remove(existing) }
                        .font(.footnote)
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                AddressField(role: role, prompt: prompt) { address, coordinate in
                    places.save(SavedPlace(
                        role: role,
                        address: address,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ))
                }
            }
        }
    }

    private func nearestStationBlurb(for place: SavedPlace) -> String {
        guard let nearest = model.network.nearestStation(to: place.coordinate) else {
            return "No SEPTA Metro station nearby"
        }
        let walk = WalkingModel().egressSeconds(straightLineMeters: nearest.meters)
        return "Nearest station: \(nearest.station.name), about \(Format.minutes(walk)) on foot"
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
                } label: {
                    Text(places.isConfigured ? "Done" : "Add an address to continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(!places.isConfigured)

                Text("Location access lets the app work out where you're starting from. You can also pick a station by hand.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}
