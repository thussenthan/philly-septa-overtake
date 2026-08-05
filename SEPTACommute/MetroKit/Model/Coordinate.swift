import Foundation

/// A WGS-84 latitude/longitude pair.
///
/// `MetroKit` deliberately avoids importing CoreLocation so that the routing
/// engine can be unit-tested with `swift test` on any platform. The app layer
/// bridges `CLLocationCoordinate2D` to this type.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle ("crow flies") distance in meters.
    public func distance(to other: Coordinate) -> Double {
        // Mean Earth radius (IUGG).
        let radius = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180

        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let a = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        return 2 * radius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

public extension Coordinate {
    /// Meters in one mile, for display conversions.
    static let metersPerMile: Double = 1609.344
}

/// The word on the station entrance and the platform sign.
///
/// Not derived — taken from SEPTA's own `directions.txt`, one row per route and
/// direction, and carried through on `ServicePattern`. Deriving it from coordinates
/// was tried and is wrong: the feed calls the Media-Sharon Hill routes northbound
/// and southbound even though Media is mostly *west* of 69th St, and `direction_id`
/// 0 means southbound on route 59 but northbound on route 66. The operator's words
/// are the only thing that agrees with the operator's signs.
public enum CompassDirection: String, Sendable, Hashable, CaseIterable {
    case north, south, east, west

    /// "Southbound" — the form SEPTA prints.
    public var label: String { rawValue.capitalized + "bound" }
}
