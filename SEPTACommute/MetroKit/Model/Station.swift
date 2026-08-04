import Foundation

public struct StationID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LineID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// The operator's own service identifier — `B1`, `B2`, `L1`, `T3`.
///
/// Distinct from `LineID`, which is the letter on the map. The Broad Street Line
/// is one line carrying three routes, and the difference matters: a rider can
/// change from a B1 to a B2 at Olney, but changing from one B1 to another is
/// never useful. The planner uses route identity to decide where a change of
/// train is even possible.
public struct RouteID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct PatternID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// A rapid-transit station.
public struct Station: Identifiable, Hashable, Sendable {
    public var id: StationID
    /// Rider-facing name, e.g. "Cecil B. Moore".
    public var name: String
    /// Optional secondary name, e.g. "Temple University".
    public var subtitle: String?
    /// Cross street, used in walking directions ("Broad St & Girard Ave").
    public var intersection: String?
    public var coordinate: Coordinate
    public var lines: [LineID]
    /// Whether the station has elevator access. `nil` means unknown.
    public var isAccessible: Bool?

    public init(
        id: StationID,
        name: String,
        subtitle: String? = nil,
        intersection: String? = nil,
        coordinate: Coordinate,
        lines: [LineID],
        isAccessible: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.intersection = intersection
        self.coordinate = coordinate
        self.lines = lines
        self.isAccessible = isAccessible
    }

    /// "Cecil B. Moore (Temple University)" when a subtitle exists.
    public var displayName: String {
        guard let subtitle, !subtitle.isEmpty else { return name }
        return "\(name) (\(subtitle))"
    }
}

/// A transit line (a color/letter on the map), e.g. the Broad Street Line.
public struct Line: Identifiable, Hashable, Sendable {
    public var id: LineID
    /// Short badge text, e.g. "B".
    public var badge: String
    /// Full name, e.g. "Broad Street Line".
    public var name: String
    /// Hex color as published by the operator, e.g. "F58426".
    public var colorHex: String

    public init(id: LineID, badge: String, name: String, colorHex: String) {
        self.id = id
        self.badge = badge
        self.name = name
        self.colorHex = colorHex
    }
}
