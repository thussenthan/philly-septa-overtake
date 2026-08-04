import Foundation

/// Either end of a trip request.
public enum Endpoint: Sendable, Hashable {
    /// An arbitrary point — current location, a saved address, a dropped pin.
    case place(name: String, coordinate: Coordinate)
    /// A station, when the rider is already standing in one.
    case station(StationID)

    public var coordinate: Coordinate? {
        switch self {
        case .place(_, let coordinate): return coordinate
        case .station: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .place(let name, _): return name
        case .station(let id): return id.rawValue
        }
    }
}

/// A walk on foot, at either end of the journey or between stations.
public struct WalkLeg: Sendable, Hashable {
    public enum Purpose: String, Sendable {
        /// From the origin to the first platform.
        case access
        /// From the last platform to the destination.
        case egress
        /// Between two stations, on foot.
        case transfer
        /// The entire trip, no train involved.
        case direct
    }

    public var purpose: Purpose
    public var fromName: String
    public var toName: String
    /// Straight-line meters; `routedMeters` is the street-following estimate.
    public var straightLineMeters: Double
    public var routedMeters: Double
    public var duration: TimeInterval
    public var startTime: Date
    /// True when the duration came from real walking directions rather than the
    /// geometric estimate.
    public var isMeasured: Bool

    public var endTime: Date { startTime.addingTimeInterval(duration) }

    public init(
        purpose: Purpose,
        fromName: String,
        toName: String,
        straightLineMeters: Double,
        routedMeters: Double,
        duration: TimeInterval,
        startTime: Date,
        isMeasured: Bool = false
    ) {
        self.purpose = purpose
        self.fromName = fromName
        self.toName = toName
        self.straightLineMeters = straightLineMeters
        self.routedMeters = routedMeters
        self.duration = duration
        self.startTime = startTime
        self.isMeasured = isMeasured
    }
}

/// One train ride.
public struct RideLeg: Sendable, Hashable {
    public var trip: Trip
    public var patternID: PatternID
    public var lineID: LineID
    public var kind: PatternKind
    public var direction: Direction
    public var headsign: String
    public var boardStation: StationID
    public var alightStation: StationID
    public var departure: Date
    public var arrival: Date
    /// Stations passed through, board and alight inclusive.
    public var stationsServed: [StationID]

    public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    /// Number of station-to-station hops.
    public var stopCount: Int { max(0, stationsServed.count - 1) }

    public init(
        trip: Trip,
        patternID: PatternID,
        lineID: LineID,
        kind: PatternKind,
        direction: Direction,
        headsign: String,
        boardStation: StationID,
        alightStation: StationID,
        departure: Date,
        arrival: Date,
        stationsServed: [StationID]
    ) {
        self.trip = trip
        self.patternID = patternID
        self.lineID = lineID
        self.kind = kind
        self.direction = direction
        self.headsign = headsign
        self.boardStation = boardStation
        self.alightStation = alightStation
        self.departure = departure
        self.arrival = arrival
        self.stationsServed = stationsServed
    }
}

/// Time spent on a platform waiting for a train.
public struct WaitLeg: Sendable, Hashable {
    public var stationID: StationID
    public var startTime: Date
    public var duration: TimeInterval
    /// True when this wait is a deliberate "let the express pass you" hold
    /// rather than the unavoidable wait for your first train.
    public var isStrategicHold: Bool

    public var endTime: Date { startTime.addingTimeInterval(duration) }

    public init(stationID: StationID, startTime: Date, duration: TimeInterval, isStrategicHold: Bool) {
        self.stationID = stationID
        self.startTime = startTime
        self.duration = duration
        self.isStrategicHold = isStrategicHold
    }
}

public enum JourneyLeg: Sendable, Hashable {
    case walk(WalkLeg)
    case wait(WaitLeg)
    case ride(RideLeg)

    public var startTime: Date {
        switch self {
        case .walk(let leg): return leg.startTime
        case .wait(let leg): return leg.startTime
        case .ride(let leg): return leg.departure
        }
    }

    public var endTime: Date {
        switch self {
        case .walk(let leg): return leg.endTime
        case .wait(let leg): return leg.endTime
        case .ride(let leg): return leg.arrival
        }
    }

    public var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    public var ride: RideLeg? {
        if case .ride(let leg) = self { return leg }
        return nil
    }

    public var walk: WalkLeg? {
        if case .walk(let leg) = self { return leg }
        return nil
    }
}

/// How soon the rider has to move.
public struct Urgency: Sendable, Hashable {
    public enum Level: Int, Sendable, Comparable {
        /// Already gone; the planner filters these out.
        case missed = 0
        /// Leave this second.
        case leaveNow = 1
        /// Under three minutes of slack.
        case leaveSoon = 2
        /// Comfortable.
        case relaxed = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The latest instant the rider can leave the origin and still make this train.
    public var leaveBy: Date
    /// When the first train actually pulls out.
    public var boardingDeparture: Date
    /// Spare time between now and `leaveBy`.
    public var slack: TimeInterval

    public init(leaveBy: Date, boardingDeparture: Date, slack: TimeInterval) {
        self.leaveBy = leaveBy
        self.boardingDeparture = boardingDeparture
        self.slack = slack
    }

    /// For an option with no timetable to miss, such as walking the whole way.
    /// A year of slack is effectively infinite while staying a formattable date.
    public static func unconstrained(from departure: Date) -> Urgency {
        let year: TimeInterval = 365 * 24 * 3600
        return Urgency(
            leaveBy: departure.addingTimeInterval(year),
            boardingDeparture: departure,
            slack: year
        )
    }

    public var isUnconstrained: Bool { slack >= 300 * 24 * 3600 }

    public var level: Level {
        if slack < -30 { return .missed }
        if slack < 60 { return .leaveNow }
        if slack < 180 { return .leaveSoon }
        return .relaxed
    }

    public func secondsUntilLeaveBy(asOf now: Date) -> TimeInterval {
        leaveBy.timeIntervalSince(now)
    }

    public func secondsUntilBoarding(asOf now: Date) -> TimeInterval {
        boardingDeparture.timeIntervalSince(now)
    }
}

/// One complete door-to-door option.
public struct Journey: Identifiable, Sendable, Hashable {
    public var legs: [JourneyLeg]
    /// When the rider must leave the origin.
    public var departureTime: Date
    /// When the rider reaches the destination.
    public var arrivalTime: Date
    public var urgency: Urgency

    public init(legs: [JourneyLeg], departureTime: Date, arrivalTime: Date, urgency: Urgency) {
        self.legs = legs
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.urgency = urgency
    }

    /// Stable across replans as long as the underlying trips are the same, so
    /// SwiftUI keeps card identity (and animations) when the plan refreshes.
    public var id: String {
        let ridePart = rides.map { "\($0.trip.id)|\($0.boardStation)|\($0.alightStation)" }.joined(separator: ">")
        let walkPart = "\(Int(walkingTime))"
        return ridePart.isEmpty ? "walk-\(walkPart)" : ridePart
    }

    public var rides: [RideLeg] { legs.compactMap(\.ride) }
    public var walks: [WalkLeg] { legs.compactMap(\.walk) }

    /// Door-to-door time, including the wait before the first train.
    public var totalDuration: TimeInterval { arrivalTime.timeIntervalSince(departureTime) }

    /// Time actually spent moving on foot.
    public var walkingTime: TimeInterval { walks.reduce(0) { $0 + $1.duration } }
    public var ridingTime: TimeInterval { rides.reduce(0) { $0 + $1.duration } }
    public var waitingTime: TimeInterval {
        legs.reduce(0) { total, leg in
            if case .wait(let wait) = leg { return total + wait.duration }
            return total
        }
    }

    public var transferCount: Int { max(0, rides.count - 1) }
    public var isWalkOnly: Bool { rides.isEmpty }

    public var boardStation: StationID? { rides.first?.boardStation }
    public var alightStation: StationID? { rides.last?.alightStation }

    /// The final walk from the last platform to the destination, if any.
    public var finalWalk: WalkLeg? {
        walks.last(where: { $0.purpose == .egress })
    }

    /// True when any leg rides an express pattern.
    public var usesExpress: Bool { rides.contains { $0.kind == .express } }
    /// True when the rider gets off one train to catch a faster one.
    public var hasStrategicHold: Bool {
        legs.contains { leg in
            if case .wait(let wait) = leg { return wait.isStrategicHold }
            return false
        }
    }
}
