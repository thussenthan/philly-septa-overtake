import Foundation

/// The static transit graph: stations, lines, and stopping patterns.
///
/// Everything the planner needs is here, so swapping in a different data
/// source (a GTFS-derived file, a different city) touches no routing code.
public struct Network: Sendable {
    public let lines: [Line]
    public let stations: [Station]
    public let patterns: [ServicePattern]
    /// Human-readable statement of where the schedule data came from and when.
    public let provenance: DataProvenance

    private let stationsByID: [StationID: Station]
    private let patternsByID: [PatternID: ServicePattern]
    private let patternsByStation: [StationID: [PatternID]]
    private let linesByID: [LineID: Line]

    public init(
        lines: [Line],
        stations: [Station],
        patterns: [ServicePattern],
        provenance: DataProvenance
    ) {
        self.lines = lines
        self.stations = stations
        self.patterns = patterns
        self.provenance = provenance

        self.stationsByID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.patternsByID = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.linesByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var index: [StationID: [PatternID]] = [:]
        for pattern in patterns {
            for stop in pattern.stops {
                index[stop.station, default: []].append(pattern.id)
            }
        }
        self.patternsByStation = index
    }

    public func station(_ id: StationID) -> Station? { stationsByID[id] }
    public func pattern(_ id: PatternID) -> ServicePattern? { patternsByID[id] }
    public func line(_ id: LineID) -> Line? { linesByID[id] }

    public func patterns(serving station: StationID) -> [ServicePattern] {
        (patternsByStation[station] ?? []).compactMap { patternsByID[$0] }
    }

    /// Stations within `radius` meters of `coordinate`, nearest first.
    public func stations(near coordinate: Coordinate, within radius: Double) -> [(station: Station, meters: Double)] {
        stations
            .map { (station: $0, meters: $0.coordinate.distance(to: coordinate)) }
            .filter { $0.meters <= radius }
            .sorted { $0.meters < $1.meters }
    }

    /// The single closest station, regardless of distance.
    public func nearestStation(to coordinate: Coordinate) -> (station: Station, meters: Double)? {
        stations
            .map { (station: $0, meters: $0.coordinate.distance(to: coordinate)) }
            .min { $0.meters < $1.meters }
    }

    public func stationsSorted(by direction: Direction, on lineID: LineID) -> [Station] {
        guard let pattern = patterns.first(where: { $0.lineID == lineID && $0.kind == .local && $0.direction == direction }) else {
            return stations.filter { $0.lines.contains(lineID) }
        }
        return pattern.stationIDs.compactMap { stationsByID[$0] }
    }
}

/// Where the bundled schedule came from, surfaced in the UI so a rider always
/// knows whether they are looking at a real timetable or an estimate.
public struct DataProvenance: Sendable, Hashable {
    public enum Fidelity: String, Sendable {
        /// Derived from the operator's published timetable or GTFS feed.
        case official
        /// Hand-built from published headways; departure minutes are estimates.
        case estimated
    }

    public var fidelity: Fidelity
    /// e.g. "SEPTA GTFS v202607261"
    public var source: String
    /// When the data was generated, `yyyy-MM-dd`.
    public var generated: String
    /// Last date the operator declares the timetable valid, `yyyyMMdd`.
    ///
    /// SEPTA's feed covers about two weeks at a time, so this is how the app
    /// knows to stop implying its departure times are gospel.
    public var validUntil: String?
    public var notes: String?

    public init(
        fidelity: Fidelity,
        source: String,
        generated: String,
        validUntil: String? = nil,
        notes: String? = nil
    ) {
        self.fidelity = fidelity
        self.source = source
        self.generated = generated
        self.validUntil = validUntil
        self.notes = notes
    }

    public var isEstimate: Bool { fidelity == .estimated }

    /// End of the last valid service day, in the agency's time zone.
    public var feedExpiryDate: Date? {
        guard let validUntil, validUntil.count == 8,
              let year = Int(validUntil.prefix(4)),
              let month = Int(validUntil.dropFirst(4).prefix(2)),
              let day = Int(validUntil.suffix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // Service on the final date runs into the small hours of the next one.
        components.hour = 27
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ServiceCalendar.easternTimeZone
        return calendar.date(from: components)
    }

    public func isStale(asOf date: Date) -> Bool {
        guard let expiry = feedExpiryDate else { return false }
        return date > expiry
    }

    public var shortDescription: String {
        switch fidelity {
        case .official: return "Official timetable · \(generated)"
        case .estimated: return "Estimated timetable · \(generated)"
        }
    }
}
