import Foundation

/// Which way a train runs. Names are line-agnostic; the rider-facing string
/// comes from `ServicePattern.headsign`.
public enum Direction: String, Codable, Sendable, CaseIterable {
    case southbound
    case northbound

    public var opposite: Direction {
        self == .southbound ? .northbound : .southbound
    }
}

/// How a pattern relates to the stopping pattern of the line.
public enum PatternKind: String, Codable, Sendable, CaseIterable {
    /// Stops at every station on the line.
    case local
    /// Skips stops; typically faster and typically peak-only.
    case express
    /// A branch that leaves the trunk (e.g. the Broad-Ridge Spur).
    case spur
    /// A surface bus that replaces the line overnight (SEPTA's B1 Owl).
    case nightBus

    public var label: String {
        switch self {
        case .local: return "Local"
        case .express: return "Express"
        case .spur: return "Spur"
        case .nightBus: return "Owl Bus"
        }
    }

    /// True when the rider boards a bus at the curb rather than a train underground.
    public var isSurface: Bool { self == .nightBus }
}

/// One stop on a `ServicePattern`, with times measured from the start of the trip.
public struct PatternStop: Hashable, Sendable {
    public var station: StationID
    /// Seconds from the trip's start time to arrival at this station.
    public var arrivalOffset: TimeInterval
    /// Seconds from the trip's start time to departure from this station.
    /// Always `>= arrivalOffset`; the difference is the dwell.
    public var departureOffset: TimeInterval
    /// False where SEPTA marks the stop `pickup_type = 1`: the train calls, but not
    /// for you. Rare — three places on the Metro map — and all of them mid-route,
    /// so there is no shortcut of assuming it only happens at a terminus.
    public var allowsBoarding: Bool
    /// False where SEPTA marks the stop `drop_off_type = 1`.
    public var allowsAlighting: Bool

    public init(
        station: StationID,
        arrivalOffset: TimeInterval,
        departureOffset: TimeInterval,
        allowsBoarding: Bool = true,
        allowsAlighting: Bool = true
    ) {
        self.station = station
        self.arrivalOffset = arrivalOffset
        self.departureOffset = max(arrivalOffset, departureOffset)
        self.allowsBoarding = allowsBoarding
        self.allowsAlighting = allowsAlighting
    }

    public init(
        station: StationID,
        offset: TimeInterval,
        dwell: TimeInterval = 0,
        allowsBoarding: Bool = true,
        allowsAlighting: Bool = true
    ) {
        self.init(
            station: station,
            arrivalOffset: offset,
            departureOffset: offset + dwell,
            allowsBoarding: allowsBoarding,
            allowsAlighting: allowsAlighting
        )
    }
}

/// A stopping pattern plus the schedule on which it operates.
///
/// A `ServicePattern` is a template. Combined with a trip start time it becomes
/// a concrete `Trip` with real clock times at every stop.
public struct ServicePattern: Identifiable, Sendable {
    public let id: PatternID
    public let lineID: LineID
    /// The operator's route this pattern belongs to (`B1`, `B2`, `L1`, …).
    public let routeID: RouteID
    public let kind: PatternKind
    public let direction: Direction
    /// Terminus shown on the train, e.g. "NRG" or "Fern Rock TC".
    public let headsign: String
    /// The word SEPTA prints for this direction, taken from its own
    /// `directions.txt` rather than derived from the coordinates. The feed calls the
    /// Media-Sharon Hill routes northbound and southbound even though Media is
    /// mostly *west* of 69th St, and no amount of measuring arrives at that.
    public let compass: CompassDirection?
    /// Percentage of this pattern's stop times SEPTA publishes rather than
    /// interpolating between timing points. 100 on the subway; about 15 on the
    /// trolleys, where most intermediate times are the agency's own estimate.
    public let publishedTimePercent: Int
    /// Ordered stops in travel order.
    ///
    /// Immutable because `positions` indexes it: a mutable `stops` could be
    /// reassigned on a copy and silently desync the index from the stop list.
    public let stops: [PatternStop]
    public let schedule: Schedule

    /// Station → position, built once at init.
    ///
    /// `stopIndex(of:)` is the single most-called function in the planner — a
    /// linear scan over up to 62 stops, several times per station per search
    /// round. As a dictionary it stops mattering.
    private let positions: [StationID: Int]

    public init(
        id: PatternID,
        lineID: LineID,
        routeID: RouteID? = nil,
        kind: PatternKind,
        direction: Direction,
        compass: CompassDirection? = nil,
        headsign: String,
        publishedTimePercent: Int = 100,
        stops: [PatternStop],
        schedule: Schedule
    ) {
        self.id = id
        self.lineID = lineID
        // Falls back to the line so hand-written patterns stay concise; generated
        // data always supplies the real route.
        self.routeID = routeID ?? RouteID(lineID.rawValue)
        self.kind = kind
        self.direction = direction
        self.compass = compass
        self.headsign = headsign
        self.publishedTimePercent = publishedTimePercent
        self.stops = stops
        self.schedule = schedule

        var positions: [StationID: Int] = [:]
        positions.reserveCapacity(stops.count)
        for (index, stop) in stops.enumerated() where positions[stop.station] == nil {
            positions[stop.station] = index
        }
        self.positions = positions
    }

    public var stationIDs: [StationID] { stops.map(\.station) }

    public func stopIndex(of station: StationID) -> Int? {
        positions[station]
    }

    public func serves(_ station: StationID) -> Bool {
        stopIndex(of: station) != nil
    }

    /// True when this pattern can carry a rider from `board` to `alight` in one ride.
    ///
    /// "Can" includes the doors: SEPTA marks a handful of mid-route stops as no
    /// pickup or no drop-off, and a plan that ignores them sends a rider to a stop
    /// where the train calls but won't take them.
    public func carries(from board: StationID, to alight: StationID) -> Bool {
        guard let b = stopIndex(of: board), let a = stopIndex(of: alight), b < a else { return false }
        return stops[b].allowsBoarding && stops[a].allowsAlighting
    }

    /// Whether a rider may board here at all.
    public func allowsBoarding(at station: StationID) -> Bool {
        guard let index = stopIndex(of: station) else { return false }
        return stops[index].allowsBoarding
    }

    /// Whether a rider may get off here at all.
    public func allowsAlighting(at station: StationID) -> Bool {
        guard let index = stopIndex(of: station) else { return false }
        return stops[index].allowsAlighting
    }

    /// True when SEPTA interpolates most of this pattern's intermediate times.
    ///
    /// The threshold is deliberately generous: at 50% the timetable is as much
    /// estimate as schedule, and a countdown built on it should say so.
    public var hasMostlyEstimatedTimes: Bool { publishedTimePercent < 50 }

    /// End-to-end running time of the pattern.
    public var duration: TimeInterval {
        guard let first = stops.first, let last = stops.last else { return 0 }
        return last.arrivalOffset - first.departureOffset
    }
}
