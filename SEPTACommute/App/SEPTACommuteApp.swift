import SwiftUI

@main
struct SEPTACommuteApp: App {
    @StateObject private var places: PlaceStore
    @StateObject private var model: CommuteModel

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
                .tint(Theme.accent)
                // Dark by default. Every colour in the app adapts, so switching
                // this changes the whole interface, not just the chrome.
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
    }
}

/// Shows onboarding until the rider has told us where at least one anchor is.
struct RootView: View {
    @EnvironmentObject private var places: PlaceStore

    var body: some View {
        if places.isConfigured {
            PlanView()
        } else {
            OnboardingView()
        }
    }
}
