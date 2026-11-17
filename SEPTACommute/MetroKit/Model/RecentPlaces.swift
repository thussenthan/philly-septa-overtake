import Foundation

/// A place the rider searched for and went to, but never saved.
public struct RecentPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var latitude: Double
    public var longitude: Double
    /// How many times it has been chosen as an end of a trip.
    public var uses: Int
    /// The rider has already been offered to make it a favorite; never ask twice.
    public var prompted: Bool
    public var lastUsed: Date

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// The last few places searched for, most recent first, with a count of how often.
///
/// Searching for "Aldi" every week should not mean typing it every week, and it is
/// the repetition, not the first visit, that says a place is worth saving. So the
/// log counts, and says when a place has earned a single polite offer to become a
/// favorite — never a prompt on every choice.
public struct RecentPlaceLog: Codable, Equatable, Sendable {
    public static let capacity = 8
    /// Choices before the rider is offered to save the place.
    public static let promptAfter = 3
    /// Two searches this close are the same place (one store, two spellings).
    public static let samePlaceMeters = 40.0

    public private(set) var places: [RecentPlace] = []

    public init() {}

    /// Records a choice and returns the place as now stored (its id is stable).
    @discardableResult
    public mutating func record(name: String, address: String, coordinate: Coordinate,
                                id: UUID = UUID(), at now: Date = Date()) -> RecentPlace {
        if let i = places.firstIndex(where: { $0.coordinate.distance(to: coordinate) <= Self.samePlaceMeters }) {
            places[i].uses += 1
            places[i].lastUsed = now
            places[i].name = name
            places[i].address = address
            let updated = places[i]
            sort()
            return updated
        }
        let new = RecentPlace(id: id, name: name, address: address, latitude: coordinate.latitude,
                              longitude: coordinate.longitude, uses: 1, prompted: false, lastUsed: now)
        places.append(new)
        sort()
        return new
    }

    /// Whether this place has been chosen often enough, and not yet asked about.
    public func shouldOfferFavorite(_ place: RecentPlace) -> Bool {
        place.uses >= Self.promptAfter && !place.prompted
    }

    public mutating func markPrompted(_ id: UUID) {
        if let i = places.firstIndex(where: { $0.id == id }) { places[i].prompted = true }
    }

    public mutating func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
    }

    private mutating func sort() {
        places.sort { $0.lastUsed > $1.lastUsed }
        if places.count > Self.capacity { places = Array(places.prefix(Self.capacity)) }
    }
}
