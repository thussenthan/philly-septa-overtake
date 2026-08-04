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

        var title: String {
            switch self {
            case .home: return "Home"
            case .school: return "Work / School"
            case .custom: return "Saved place"
            }
        }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var home: SavedPlace? { places.first { $0.role == .home } }
    var school: SavedPlace? { places.first { $0.role == .school } }
    var custom: [SavedPlace] { places.filter { $0.role == .custom } }

    /// True once the rider has told us where at least one of their anchors is.
    /// Until then the app has nothing to route to and shows onboarding.
    var isConfigured: Bool { home != nil || school != nil }

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

    func removeAll() {
        places.removeAll()
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
