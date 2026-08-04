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
