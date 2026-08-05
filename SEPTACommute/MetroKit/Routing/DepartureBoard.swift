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
    /// Where this train would put the rider down, of the stations that work.
    public var alightStation: StationID
    /// When it gets there. The board is sorted by departure, so this is what makes a
    /// later train visibly better or worse than an earlier one.
    public var arrival: Date

    public var id: String { "\(trip.id)|\(alightStation.rawValue)" }

    /// "B2", or "OWL" for the night bus, matching the badge on a journey.
    public var routeBadge: String {
        kind == .nightBus ? "OWL" : routeID.rawValue
    }

    /// "Southbound · Express", the same phrasing the itinerary uses.
    public var platformHeadline: String {
        let parts = [compass?.label, kind == .local ? nil : kind.label].compactMap { $0 }
        return parts.isEmpty ? "toward \(headsign)" : parts.joined(separator: " · ")
    }

    public init(
        trip: Trip,
        lineID: LineID,
        routeID: RouteID,
        kind: PatternKind,
        compass: CompassDirection?,
        headsign: String,
        departure: Date,
        alightStation: StationID,
        arrival: Date
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
    }
}

public extension JourneyPlanner {

    /// Every train leaving this station soon that can get the rider to one of these
    /// stations, in departure order.
    ///
    /// Deliberately *not* the planner's ranked list. `plan` answers "what should I
    /// do", which means hiding options that another option beats outright — right for
    /// a recommendation, wrong for a board. A platform sign shows you everything and
    /// lets you look at it; the slow train you're going to take anyway because it's
    /// here now belongs on the board even though the express beats it.
    ///
    /// One entry per train, taking the earliest station it serves of the ones offered,
    /// because that is the one a rider would use.
    func departureBoard(
        from origin: StationID,
        to destinations: Set<StationID>,
        after time: Date,
        limit: Int = 8,
        horizon: TimeInterval = 90 * 60
    ) -> [BoardDeparture] {
        guard !destinations.isEmpty else { return [] }
        let window = DateInterval(start: time, end: time.addingTimeInterval(horizon))

        var board: [BoardDeparture] = []
        for pattern in network.patterns(serving: origin) {
            guard let boardIndex = pattern.stopIndex(of: origin),
                  pattern.stops[boardIndex].allowsBoarding else { continue }

            // The first station of the offered set this train reaches after boarding.
            var alightIndex: Int?
            for destination in destinations {
                guard let index = pattern.stopIndex(of: destination),
                      index > boardIndex,
                      pattern.stops[index].allowsAlighting else { continue }
                if alightIndex == nil || index < alightIndex! { alightIndex = index }
            }
            guard let alightIndex else { continue }

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
                    alightStation: pattern.stops[alightIndex].station,
                    arrival: trip.departure(atOffset: pattern.stops[alightIndex].arrivalOffset)
                ))
            }
        }

        board.sort { lhs, rhs in
            lhs.departure == rhs.departure ? lhs.arrival < rhs.arrival : lhs.departure < rhs.departure
        }
        return Array(board.prefix(limit))
    }
}
