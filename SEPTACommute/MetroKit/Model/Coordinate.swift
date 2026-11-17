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

public extension Coordinate {
    /// A latitude and longitude typed or pasted by a person: "39.9715, -75.1595",
    /// "39.9715 -75.1595", "39.9715N 75.1595W".
    ///
    /// Longitude first ("-75.1595, 39.9715", as GeoJSON writes it) is accepted when
    /// the first number cannot be a latitude, or is a far-south latitude followed by
    /// a northern one, which no SEPTA rider means.
    /// Anything that isn't two numbers on Earth is `nil`: a street number like
    /// "1500 Market" must stay an address.
    static func parse(_ text: String) -> Coordinate? {
        var numbers: [(value: Double, hemisphere: Character?)] = []
        var i = text.startIndex
        let chars = text
        while i < chars.endIndex {
            let c = chars[i]
            if c.isNumber || ((c == "-" || c == "+" || c == "−") && chars.index(after: i) < chars.endIndex && chars[chars.index(after: i)].isNumber) || (c == "." && chars.index(after: i) < chars.endIndex && chars[chars.index(after: i)].isNumber) {
                var j = chars.index(after: i)
                while j < chars.endIndex, chars[j].isNumber || chars[j] == "." { j = chars.index(after: j) }
                let raw = String(chars[i..<j]).replacingOccurrences(of: "−", with: "-")
                guard let v = Double(raw) else { return nil }
                // A trailing hemisphere letter, with or without a degree sign or space.
                var k = j
                while k < chars.endIndex, chars[k] == "°" || chars[k] == " " { k = chars.index(after: k) }
                var hemi: Character?
                if k < chars.endIndex, "NSEWnsew".contains(chars[k]) {
                    let next = chars.index(after: k)
                    if next == chars.endIndex || !chars[next].isLetter { hemi = Character(chars[k].uppercased()); j = next }
                }
                numbers.append((v, hemi))
                i = j
            } else if c.isLetter && !"NSEWnsew".contains(c) {
                return nil
            } else {
                i = chars.index(after: i)
            }
        }
        guard numbers.count == 2 else { return nil }
        var a = numbers[0], b = numbers[1]
        func signed(_ n: (value: Double, hemisphere: Character?)) -> Double {
            (n.hemisphere == "S" || n.hemisphere == "W") ? -abs(n.value) : n.value
        }
        // Whole-number pairs are far likelier to be "1500 2000" than a position.
        guard text.contains(".") else { return nil }
        let hemisphereFirstIsLongitude = a.hemisphere == "E" || a.hemisphere == "W" || b.hemisphere == "N" || b.hemisphere == "S"
        a.0 = signed(a); b.0 = signed(b)
        var lat = a.0, lon = b.0
        if hemisphereFirstIsLongitude || abs(a.0) > 90 || (a.0 < -60 && b.0 > 0) { swap(&lat, &lon) }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}
