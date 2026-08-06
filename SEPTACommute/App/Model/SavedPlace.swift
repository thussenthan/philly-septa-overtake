import Foundation

/// A place the rider has told us about.
///
/// The app ships with no addresses in it. Home and School are asked for on first
/// launch and live only in this device's `UserDefaults` — nothing is uploaded,
/// because nothing in this app talks to a server.
struct SavedPlace: Identifiable, Codable, Hashable {
    enum Role: String, Codable, CaseIterable, Identifiable {
        case home
        case school
        case custom

        var id: String { rawValue }

        /// The default name for a place in this role, before the rider renames it.
        ///
        /// The second anchor is one place, not two — but what to call it depends on
        /// whose phone this is. "Work / School" was a slash standing in for a choice
        /// nobody had been asked to make, so the rider makes it and this is only
        /// where it starts.
        var title: String {
            switch self {
            case .home: return "Home"
            case .school: return "Work"
            case .custom: return "Saved place"
            }
        }

        /// What to call the row while the rider hasn't set it yet, where naming it
        /// "Work" would be presuming.
        var unsetTitle: String {
            self == .school ? "Work or school" : title
        }

        /// Whether the rider gets to name a place in this role.
        var isRenameable: Bool { self != .home }

        /// One tap instead of typing, for the two that cover almost everyone.
        static let awayLabelSuggestions = ["Work", "School", "Hospital", "Campus"]

        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .school: return "building.columns.fill"
            case .custom: return "mappin.circle.fill"
            }
        }
    }

    var id: UUID
    var role: Role
    /// What the rider calls it. Defaults to the role's title.
    var name: String
    /// The address as entered or as returned by search, shown back for confirmation.
    var address: String
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), role: Role, name: String? = nil, address: String, latitude: Double, longitude: Double) {
        self.id = id
        self.role = role
        self.name = name ?? role.title
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    var endpoint: Endpoint {
        .place(name: name, coordinate: coordinate)
    }
}

/// Persists saved places on the device.
@MainActor
final class PlaceStore: ObservableObject {
    @Published private(set) var places: [SavedPlace] = []

    private let defaults: UserDefaults
    private let storageKey = "savedPlaces.v1"
    private let setupKey = "hasFinishedSetup.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // Installs from before this flag existed have already been through setup, and
        // sending them back through it would be a worse bug than the one being fixed.
        // Both anchors present is the state onboarding was trying to reach, so it
        // counts as having reached it.
        if defaults.object(forKey: setupKey) == nil, home != nil, school != nil {
            defaults.set(true, forKey: setupKey)
        }
        hasFinishedSetup = defaults.bool(forKey: setupKey)
    }

    var home: SavedPlace? { places.first { $0.role == .home } }
    var school: SavedPlace? { places.first { $0.role == .school } }
    var custom: [SavedPlace] { places.filter { $0.role == .custom } }

    /// True once the rider has told us where at least one of their anchors is.
    /// Below this the app has nothing at all to route to.
    var isConfigured: Bool { home != nil || school != nil }

    /// Whether setup is behind us.
    ///
    /// Deliberately not "has an address". Onboarding asks for two, and gating the
    /// root view on `isConfigured` meant saving the first one tore the screen away
    /// mid-flow — the rider never reached the second field, and the Done button
    /// underneath it could not be pressed because it no longer existed. Finishing is
    /// now something the rider does, not something that happens to them.
    @Published private(set) var hasFinishedSetup: Bool = false

    /// Called by onboarding's Done button.
    func finishSetup() {
        guard !hasFinishedSetup else { return }
        hasFinishedSetup = true
        defaults.set(true, forKey: setupKey)
    }

    func place(for role: SavedPlace.Role) -> SavedPlace? {
        places.first { $0.role == role }
    }

    /// Home and School are singular; saving a new one replaces the old.
    func save(_ place: SavedPlace) {
        if place.role != .custom {
            places.removeAll { $0.role == place.role }
        } else {
            places.removeAll { $0.id == place.id }
        }
        places.append(place)
        places.sort { lhs, rhs in
            let order: [SavedPlace.Role] = [.home, .school, .custom]
            let lhsIndex = order.firstIndex(of: lhs.role) ?? 99
            let rhsIndex = order.firstIndex(of: rhs.role) ?? 99
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.name < rhs.name
        }
        persist()
    }

    func remove(_ place: SavedPlace) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    /// Wipes the rider's places and puts them back at setup.
    ///
    /// Leaving `hasFinishedSetup` standing would strand them on a plan screen with
    /// nowhere to plan to and no way back to the screen that asks.
    func removeAll() {
        places.removeAll()
        hasFinishedSetup = false
        defaults.removeObject(forKey: setupKey)
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        places = (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
