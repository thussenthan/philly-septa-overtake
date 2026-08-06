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
    /// What a ride costs, and whether a change of train is included in it.
    public let fare: FareRules

    private let stationsByID: [StationID: Station]
    private let patternsByID: [PatternID: ServicePattern]
    private let patternsByStation: [StationID: [ServicePattern]]
    private let linesByID: [LineID: Line]
    /// How many distinct operator routes call at each station.
    ///
    /// This is what tells the planner where changing trains is even conceivable.
    /// On the full Metro map only 69 of 590 stations are served by more than one
    /// route; the rest are mid-line stops where a change can never help, and
    /// skipping them removes most of the search.
    private let routeCountByStation: [StationID: Int]

    public init(
        lines: [Line],
        stations: [Station],
        patterns: [ServicePattern],
        provenance: DataProvenance,
        fare: FareRules = FareRules(amount: 0)
    ) {
        self.lines = lines
        self.stations = stations
        self.patterns = patterns
        self.provenance = provenance
        self.fare = fare

        self.stationsByID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.patternsByID = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.linesByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var index: [StationID: [ServicePattern]] = [:]
        var routes: [StationID: Set<RouteID>] = [:]
        for pattern in patterns {
            for stop in pattern.stops {
                index[stop.station, default: []].append(pattern)
                routes[stop.station, default: []].insert(pattern.routeID)
            }
        }
        self.patternsByStation = index
        self.routeCountByStation = routes.mapValues(\.count)
    }

    public func station(_ id: StationID) -> Station? { stationsByID[id] }
    public func pattern(_ id: PatternID) -> ServicePattern? { patternsByID[id] }
    public func line(_ id: LineID) -> Line? { linesByID[id] }

    /// Patterns calling at a station. Pre-resolved, so this is a dictionary hit
    /// rather than a lookup per pattern.
    public func patterns(serving station: StationID) -> [ServicePattern] {
        patternsByStation[station] ?? []
    }

    /// Number of distinct operator routes calling at a station.
    public func routeCount(at station: StationID) -> Int {
        routeCountByStation[station] ?? 0
    }

    /// Whether changing trains here could possibly achieve anything.
    ///
    /// One route means every train through here goes the same way, and the next
    /// one is by definition later than the one you are on — so getting off can
    /// only ever lose time.
    public func isInterchange(_ station: StationID) -> Bool {
        routeCount(at: station) > 1
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

    /// A line's stations in travel order.
    ///
    /// Taken from the line's longest pattern, since that is the one that visits the
    /// most of them; anything a shorter branch adds is appended. "North to south"
    /// only meant something while the app covered a single north-south line.
    public func stationsInOrder(on lineID: LineID) -> [Station] {
        let onLine = patterns.filter { $0.lineID == lineID }
        guard let spine = onLine.max(by: { $0.stops.count < $1.stops.count }) else { return [] }

        var seen = Set<StationID>()
        var ordered: [Station] = []
        for id in spine.stationIDs where seen.insert(id).inserted {
            if let station = station(id) { ordered.append(station) }
        }
        // Branches the spine misses, in the order the other patterns visit them.
        for pattern in onLine where pattern.id != spine.id {
            for id in pattern.stationIDs where seen.insert(id).inserted {
                if let station = station(id) { ordered.append(station) }
            }
        }
        return ordered
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
    /// Last date the operator declares the timetable *authoritative*, `yyyyMMdd`.
    ///
    /// SEPTA commits to about a fortnight at a time, so this is how the app knows
    /// to stop implying its departure times are gospel.
    public var validUntil: String?
    /// Last date the feed defines any service at all, `yyyyMMdd`.
    ///
    /// SEPTA publishes two windows and labels the difference itself: `feed_info.txt`
    /// carries the authoritative fortnight, while `calendar.txt` runs a couple of
    /// weeks further as "advisory only" — timetables it expects to hold but has not
    /// committed to. Past `validUntil` the times are a projection, which is worth
    /// saying quietly. Past *this* there is nothing left to route on, which is worth
    /// saying loudly, and the two should not be confused.
    public var servicesUntil: String?
    public var notes: String?

    public init(
        fidelity: Fidelity,
        source: String,
        generated: String,
        validUntil: String? = nil,
        servicesUntil: String? = nil,
        notes: String? = nil
    ) {
        self.fidelity = fidelity
        self.source = source
        self.generated = generated
        self.validUntil = validUntil
        self.servicesUntil = servicesUntil
        self.notes = notes
    }

    public var isEstimate: Bool { fidelity == .estimated }

    /// End of the last authoritative service day, in the agency's time zone.
    public var feedExpiryDate: Date? { Self.endOfServiceDay(validUntil) }

    /// End of the last day the feed describes any service for.
    public var serviceExpiryDate: Date? { Self.endOfServiceDay(servicesUntil) }

    private static func endOfServiceDay(_ yyyymmdd: String?) -> Date? {
        guard let yyyymmdd, yyyymmdd.count == 8,
              let year = Int(yyyymmdd.prefix(4)),
              let month = Int(yyyymmdd.dropFirst(4).prefix(2)),
              let day = Int(yyyymmdd.suffix(2)) else { return nil }
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

    /// Past the fortnight SEPTA commits to. The times are its own projection now.
    public func isStale(asOf date: Date) -> Bool {
        guard let expiry = feedExpiryDate else { return false }
        return date > expiry
    }

    /// Past every date the feed describes, so there is nothing left to route on.
    ///
    /// This is the one worth interrupting a rider for. Being merely `isStale` is not:
    /// SEPTA's rail timetables change a few times a year while its feed windows are a
    /// fortnight wide, so an app that cried out every fortnight would be crying wolf
    /// for months at a stretch and be ignored by the time it mattered.
    public func hasNoServiceData(asOf date: Date) -> Bool {
        // Fall back to the authoritative end when the feed didn't state an advisory
        // one — better to over-warn than to route on data that isn't there.
        guard let expiry = serviceExpiryDate ?? feedExpiryDate else { return false }
        return date > expiry
    }

    public var shortDescription: String {
        switch fidelity {
        case .official: return "Official timetable · \(generated)"
        case .estimated: return "Estimated timetable · \(generated)"
        }
    }
}
