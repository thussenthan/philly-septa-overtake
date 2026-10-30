import Foundation

/// One train on the board: what it is, when it leaves, and when it would get you
/// there.
public struct BoardDeparture: Sendable, Hashable, Identifiable {
    public var trip: Trip
    public var lineID: LineID
    public var routeID: RouteID
    public var kind: PatternKind
    public var compass: CompassDirection?
    public var headsign: String
    public var departure: Date
    /// Where this train would put the rider down, of the stations that work — or nil
    /// when it stops at none of them.
    ///
    /// Those trains are on the board on purpose. A board that quietly omitted them
    /// would disagree with the sign the rider is standing under, and the difference is
    /// the single most useful thing this app knows: the express pulling in first is no
    /// good to you *because it skips your stop*. Hiding it answers the question
    /// silently; showing it greyed out answers it out loud.
    public var alightStation: StationID?
    /// When it gets there, for the trains that do.
    public var arrival: Date?
    /// The stop it fails to make, so the row can say why it is no use.
    public var missedDestination: StationID?

    /// Whether this train is one the rider could actually take.
    public var isUseful: Bool { alightStation != nil }

    public var id: String { "\(trip.id)|\(alightStation?.rawValue ?? "skips")" }

    /// The one direction a board is for, when its trains agree on one.
    ///
    /// They almost always do — a board is built from a single platform — but a station
    /// where two routes diverge can offer both, and a header naming one of them would
    /// be worse than a header naming neither.
    public static func direction(of board: [BoardDeparture]) -> CompassDirection? {
        let compasses = Set(board.compactMap(\.compass))
        return compasses.count == 1 ? compasses.first : nil
    }

    /// "B2", or "OWL" for the night bus, matching the badge on a journey.
    public var routeBadge: String {
        kind == .nightBus ? "OWL" : routeID.rawValue
    }

    /// "Southbound · Express", the same phrasing the itinerary uses.
    public var platformHeadline: String {
        let parts = [compass?.label, kind == .local ? nil : kind.label].compactMap { $0 }
        return parts.isEmpty ? "toward \(headsign)" : parts.joined(separator: " · ")
    }

    /// The same line with the direction taken out.
    ///
    /// A board is one platform, so its direction is a property of the board and is
    /// said once at the top. Repeating "Southbound" down every row spends the widest
    /// part of each line on the one word they all share.
    public var serviceHeadline: String {
        kind == .local ? "toward \(headsign)" : kind.label
    }

    public init(
        trip: Trip,
        lineID: LineID,
        routeID: RouteID,
        kind: PatternKind,
        compass: CompassDirection?,
        headsign: String,
        departure: Date,
        alightStation: StationID?,
        arrival: Date?,
        missedDestination: StationID? = nil
    ) {
        self.trip = trip
        self.lineID = lineID
        self.routeID = routeID
        self.kind = kind
        self.compass = compass
        self.headsign = headsign
        self.departure = departure
        self.alightStation = alightStation
        self.arrival = arrival
        self.missedDestination = missedDestination
    }
}

public extension JourneyPlanner {

    /// A line and its feed direction: the platform, when there is no compass word.
    private static func platformKey(_ pattern: ServicePattern) -> String {
        "\(pattern.lineID.rawValue)|\(pattern.direction)"
    }

    /// Every train leaving this station soon on the platform the rider wants, in
    /// departure order, each one marked with whether it is any use.
    ///
    /// Deliberately *not* the planner's ranked list. `plan` answers "what should I
    /// do", which means hiding options that another option beats outright — right for
    /// a recommendation, wrong for a board. A platform sign shows you everything and
    /// lets you look at it; the slow train you're going to take anyway because it's
    /// here now belongs on the board even though the express beats it.
    ///
    /// It goes one further and keeps the trains that cannot help at all, greyed by the
    /// view rather than dropped. Omitting them made the app disagree with the sign the
    /// rider is standing under — the express really is pulling in first — and left the
    /// most useful fact on the platform unsaid, which is *why* that express is no good
    /// to them. Only trains going the same way are kept: a northbound train at this
    /// station is a different platform, not a worse option.
    ///
    /// One entry per train, taking the earliest station it serves of the ones offered,
    /// because that is the one a rider would use.
    func departureBoard(
        from origin: StationID,
        to destinations: Set<StationID>,
        after time: Date,
        /// The stop the rider is actually aiming at, named on the rows that miss it.
        /// Without it those rows can say they are no use but not why.
        aimingAt: StationID? = nil,
        limit: Int = 8,
        horizon: TimeInterval = 90 * 60
    ) -> [BoardDeparture] {
        guard !destinations.isEmpty else { return [] }
        let window = DateInterval(start: time, end: time.addingTimeInterval(horizon))

        // Which patterns can do the job, and where each would drop the rider.
        var alightIndexByPattern: [PatternID: Int] = [:]
        // Which platform is "the rider's". By the signed compass word where there is
        // one, because `direction_id` is only comparable within a line: 0 is east on
        // the L and west on the G1, so judging by it put westbound trolleys on an
        // eastbound L board as trains that "skip your stop".
        var usefulCompasses: Set<CompassDirection> = []
        var usefulLineDirections: Set<String> = []
        let boarding = network.patterns(serving: origin).filter { pattern in
            // A train that ends here, or won't open its doors here, isn't a departure.
            guard let boardIndex = pattern.stopIndex(of: origin),
                  boardIndex + 1 < pattern.stops.count,
                  pattern.stops[boardIndex].allowsBoarding else { return false }
            var best: Int?
            for destination in destinations {
                guard let index = pattern.stopIndex(of: destination),
                      index > boardIndex,
                      pattern.stops[index].allowsAlighting else { continue }
                if best == nil || index < best! { best = index }
            }
            if let best {
                alightIndexByPattern[pattern.id] = best
                if let compass = pattern.compass { usefulCompasses.insert(compass) }
                usefulLineDirections.insert(Self.platformKey(pattern))
            }
            return true
        }

        // Nothing works from here, so there is no platform to show and no direction to
        // judge the rest against.
        guard !usefulLineDirections.isEmpty else { return [] }

        func sharesPlatform(_ pattern: ServicePattern) -> Bool {
            if let compass = pattern.compass, !usefulCompasses.isEmpty {
                return usefulCompasses.contains(compass)
            }
            return usefulLineDirections.contains(Self.platformKey(pattern))
        }

        // Only name the stop being missed when the caller said which one matters. Any
        // other choice out of the offered set would be arbitrary, and a row that named
        // the wrong station would be worse than one that named none.
        let missed = aimingAt.flatMap { destinations.contains($0) ? $0 : nil }

        var board: [BoardDeparture] = []
        for pattern in boarding {
            let alightIndex = alightIndexByPattern[pattern.id]
            // A train that helps is always shown. One that doesn't is shown only if it
            // leaves from the same platform, where the rider will watch it go past.
            guard alightIndex != nil || sharesPlatform(pattern) else { continue }

            for trip in timetable.trips(of: pattern, departingFrom: origin, in: window) {
                guard let departure = timetable.departure(of: trip, at: origin) else { continue }
                board.append(BoardDeparture(
                    trip: trip,
                    lineID: pattern.lineID,
                    routeID: pattern.routeID,
                    kind: pattern.kind,
                    compass: pattern.compass,
                    headsign: pattern.headsign,
                    departure: departure,
                    alightStation: alightIndex.map { pattern.stops[$0].station },
                    arrival: alightIndex.map { trip.departure(atOffset: pattern.stops[$0].arrivalOffset) },
                    missedDestination: alightIndex == nil ? missed : nil
                ))
            }
        }

        board.sort { lhs, rhs in
            if lhs.departure != rhs.departure { return lhs.departure < rhs.departure }
            // Same minute: the one you can take goes first.
            if lhs.isUseful != rhs.isUseful { return lhs.isUseful }
            return (lhs.arrival ?? .distantFuture) < (rhs.arrival ?? .distantFuture)
        }
        return Array(board.prefix(limit))
    }
}

// MARK: - The whole station

/// One train leaving a station, whatever it is for.
///
/// `BoardDeparture` answers "which of these gets me there"; this answers the question
/// a platform sign exists for, which is simply "what is leaving". Most of the Metro's
/// stations have no sign at all, so for them this is the sign.
public struct StationDeparture: Sendable, Hashable, Identifiable {
    public var trip: Trip
    public var lineID: LineID
    public var routeID: RouteID
    public var kind: PatternKind
    public var compass: CompassDirection?
    public var direction: Direction
    public var headsign: String
    public var departure: Date

    public var id: String { trip.id }

    /// "B2", or "OWL" for the night bus, matching the badge on a journey.
    public var routeBadge: String {
        kind == .nightBus ? "OWL" : routeID.rawValue
    }

    /// Which platform: "Southbound", or the terminus where the feed gives no compass
    /// direction.
    public var platformTitle: String {
        compass?.label ?? "toward \(headsign)"
    }

    /// What differs between trains on one platform: where it is going, or that it is
    /// an express.
    public var serviceHeadline: String {
        kind == .local ? "toward \(headsign)" : "\(kind.label) · \(headsign)"
    }

    public init(
        trip: Trip,
        lineID: LineID,
        routeID: RouteID,
        kind: PatternKind,
        compass: CompassDirection?,
        direction: Direction,
        headsign: String,
        departure: Date
    ) {
        self.trip = trip
        self.lineID = lineID
        self.routeID = routeID
        self.kind = kind
        self.compass = compass
        self.direction = direction
        self.headsign = headsign
        self.departure = departure
    }
}

public extension JourneyPlanner {

    /// Every train that will let a rider on at `station` in the next while, in
    /// departure order, regardless of where it is going.
    ///
    /// A train that ends here, or whose doors don't open for boarding at this stop, is
    /// not a departure and is left out — the same rule the planner and the trip board
    /// apply.
    func stationBoard(
        at station: StationID,
        after time: Date,
        horizon: TimeInterval = 90 * 60,
        limit: Int = 60
    ) -> [StationDeparture] {
        let window = DateInterval(start: time, end: time.addingTimeInterval(horizon))
        var rows: [StationDeparture] = []

        for pattern in network.patterns(serving: station) {
            guard let index = pattern.stopIndex(of: station),
                  index + 1 < pattern.stops.count,
                  pattern.stops[index].allowsBoarding else { continue }

            for trip in timetable.trips(of: pattern, departingFrom: station, in: window) {
                guard let departure = timetable.departure(of: trip, at: station) else { continue }
                rows.append(StationDeparture(
                    trip: trip,
                    lineID: pattern.lineID,
                    routeID: pattern.routeID,
                    kind: pattern.kind,
                    compass: pattern.compass,
                    direction: pattern.direction,
                    headsign: pattern.headsign,
                    departure: departure
                ))
            }
        }

        rows.sort { lhs, rhs in
            if lhs.departure != rhs.departure { return lhs.departure < rhs.departure }
            return lhs.id < rhs.id
        }
        return Array(rows.prefix(limit))
    }
}
