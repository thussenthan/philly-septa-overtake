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

/// Which pair of words a line uses for its two ends.
///
/// A property of the *line*, not of any one ride. SEPTA calls the Broad Street Line
/// northbound and southbound and the Market-Frankford Line eastbound and westbound,
/// and the only way to agree with them is to ask how the line as a whole is laid out.
public enum TransitAxis: Sendable, Hashable {
    case northSouth
    case eastWest

    /// Taken from the full extent of a line, end to end.
    public init(from origin: Coordinate, to destination: Coordinate) {
        let (northSouth, eastWest) = Coordinate.offsetMeters(from: origin, to: destination)
        self = abs(northSouth) >= abs(eastWest) ? .northSouth : .eastWest
    }
}

/// The word on the station entrance and the platform sign.
///
/// Two measurements, deliberately: the *axis* from the line's full extent, and the
/// *sense* from the ride. Using the ride alone gets Philadelphia wrong — Frankford
/// is 7.8 km north of City Hall and only 7.4 km east of it, so a trip up the
/// Market-Frankford Line measures as northbound while every sign in the station says
/// eastbound. The line is east–west; this particular ride merely also goes uphill.
public enum CompassDirection: String, Sendable, Hashable, CaseIterable {
    case north, south, east, west

    /// "Southbound" — the form SEPTA prints.
    public var label: String { rawValue.capitalized + "bound" }

    /// Which way a ride runs, named in the terms its line uses.
    ///
    /// `nil` when there is no net movement worth announcing — a loop route can put
    /// a rider off near where they got on, and inventing a heading for that is worse
    /// than staying quiet.
    public init?(travelling origin: Coordinate, to destination: Coordinate, along axis: TransitAxis) {
        let (northSouth, eastWest) = Coordinate.offsetMeters(from: origin, to: destination)
        let along = axis == .northSouth ? northSouth : eastWest
        guard abs(along) >= 200 else { return nil }

        switch axis {
        case .northSouth: self = along > 0 ? .north : .south
        case .eastWest: self = along > 0 ? .east : .west
        }
    }
}

extension Coordinate {
    /// North and east offsets in metres.
    ///
    /// Both in metres because degrees aren't comparable: a degree of longitude is
    /// about 23% shorter than a degree of latitude at Philadelphia's latitude, which
    /// is more than enough to mistake one axis for the other.
    static func offsetMeters(from origin: Coordinate, to destination: Coordinate) -> (north: Double, east: Double) {
        let metersPerDegree = 111_320.0
        let north = (destination.latitude - origin.latitude) * metersPerDegree
        let east = (destination.longitude - origin.longitude)
            * cos(origin.latitude * .pi / 180) * metersPerDegree
        return (north, east)
    }
}
