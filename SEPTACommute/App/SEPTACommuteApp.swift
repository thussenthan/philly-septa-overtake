import SwiftUI

@main
struct SEPTACommuteApp: App {
    @StateObject private var places: PlaceStore
    @StateObject private var model: CommuteModel
    @StateObject private var recents = RecentPlaceStore()

    init() {
        let store = PlaceStore()
        _places = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: CommuteModel(places: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(places)
                .environmentObject(model)
                .environmentObject(recents)
                .tint(Theme.accent)
                // Dark by default. Every colour in the app adapts, so switching
                // this changes the whole interface, not just the chrome.
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
    }
}

/// Shows onboarding until the rider says they are done with it.
///
/// Gating on "has any address" swapped this view out the moment the first one was
/// saved, halfway through a screen that asks for two.
struct RootView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var recents: RecentPlaceStore

    var body: some View {
        Group {
            if places.hasFinishedSetup {
                PlanView()
            } else {
                OnboardingView()
            }
        }
        // Asked once per place, after the third trip to it — not on every search.
        .alert(
            recents.favoriteOffer.map { "Make \($0.name) a favorite?" } ?? "",
            isPresented: Binding(get: { recents.favoriteOffer != nil }, set: { if !$0 { recents.favoriteOffer = nil } }),
            presenting: recents.favoriteOffer
        ) { offer in
            Button("Add to favorites") {
                places.save(recents.asPlace(offer))
                recents.remove(offer)
            }
            Button("Not now", role: .cancel) {}
        } message: { offer in
            Text("You've gone to \(offer.name) \(offer.uses) times. Favorites sit at the top of every picker. You can add, rename or remove them any time in Settings, under Places.")
        }
    }
}
