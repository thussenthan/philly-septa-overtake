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
    /// The operator's route — `B1`, `B2`, `B3`, `L1`. This is what the map, the
    /// platform sign and the front of the train all say, and it is the difference
    /// between the train a rider wants and the one on the next track. The line
    /// letter alone can't distinguish them.
    public var routeID: RouteID
    public var kind: PatternKind
    public var direction: Direction
    /// Which way this ride actually travels, measured from the two stations. What
    /// the station entrance and the platform sign say.
    public var compass: CompassDirection?
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

    /// What to look for on the platform: the route as the signs write it.
    ///
    /// The Owl bus is filed as `B1_OWL`, which is a feed identifier and not
    /// something painted on anything, so it gets the word riders actually use.
    public var routeBadge: String {
        kind == .nightBus ? "OWL" : routeID.rawValue
    }

    /// "Southbound · Express" — how a rider picks the right platform, then the
    /// right train on it.
    ///
    /// The stopping pattern is only named when it is the point: every ordinary train
    /// is a local, so saying so on all of them buries the one word that matters.
    public var platformHeadline: String {
        let parts = [compass?.label, kind == .local ? nil : kind.label].compactMap { $0 }
        return parts.isEmpty ? "toward \(headsign)" : parts.joined(separator: " · ")
    }

    /// The terminus painted on the front of the train.
    public var headsignPhrase: String { "toward \(headsign)" }

    /// Both cues in one line, for the widget and for VoiceOver.
    public var platformDescription: String {
        platformHeadline.hasPrefix("toward")
            ? platformHeadline
            : "\(platformHeadline) · \(headsignPhrase)"
    }

    public init(
        trip: Trip,
        patternID: PatternID,
        lineID: LineID,
        routeID: RouteID,
        kind: PatternKind,
        direction: Direction,
        compass: CompassDirection? = nil,
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
        self.routeID = routeID
        self.kind = kind
        self.direction = direction
        self.compass = compass
        self.headsign = headsign
        self.boardStation = boardStation
        self.alightStation = alightStation
        self.departure = departure
        self.arrival = arrival
        self.stationsServed = stationsServed
    }
}

/// Evidence that a rider was overtaken: they boarded one train, got off, and
/// caught a faster one that had been *behind* them.
///
/// This is checked against the timetable rather than inferred from the shape of
/// the itinerary. Two trains on the same line in the same direction is not
/// enough — riding the express to Girard and finishing on a local looks
/// identical structurally, but nothing overtook anybody. Claiming otherwise puts
/// a sentence on screen ("a faster train catches up with you here") that is
/// simply false.
/// The test is not "did the second train leave the boarding station later" — on
/// this line the fast train usually doesn't call at the boarding station at all,
/// which is exactly why the rider is on the slow one. What makes it an overtake
/// is simpler and observable: the train they got *off* also goes where they are
/// going, and gets there later than the train they got *on*. It was ahead of them
/// at the platform where they switched, and it loses.
public struct Overtake: Sendable, Hashable {
    /// Where the rider first got on.
    public var boardedAt: StationID
    /// Where they stepped off to let the faster train take over.
    public var switchedAt: StationID
    /// The station the two trains are compared at — where the rider finally gets
    /// off. Recorded so the saving is never measured against a different stop.
    public var comparedAt: StationID
    /// When the train they abandoned reaches `comparedAt`.
    public var arrivalIfTheyHadStayedPut: Date
    /// When they actually get there.
    public var arrival: Date

    public init(
        boardedAt: StationID,
        switchedAt: StationID,
        comparedAt: StationID,
        arrivalIfTheyHadStayedPut: Date,
        arrival: Date
    ) {
        self.boardedAt = boardedAt
        self.switchedAt = switchedAt
        self.comparedAt = comparedAt
        self.arrivalIfTheyHadStayedPut = arrivalIfTheyHadStayedPut
        self.arrival = arrival
    }

    /// What the switch is worth. Positive by construction — an overtake that
    /// saved nothing is not an overtake.
    public var timeSaved: TimeInterval {
        arrivalIfTheyHadStayedPut.timeIntervalSince(arrival)
    }
}

/// Time spent on a platform waiting for a train.
public struct WaitLeg: Sendable, Hashable {
    public var stationID: StationID
    public var startTime: Date
    public var duration: TimeInterval
    /// Set when the rider got off to let a verified faster train take over.
    public var overtake: Overtake?

    public var endTime: Date { startTime.addingTimeInterval(duration) }

    /// True only when a faster train genuinely caught the rider up here, as
    /// opposed to any wait that happens to follow a ride.
    public var isStrategicHold: Bool { overtake != nil }

    public init(stationID: StationID, startTime: Date, duration: TimeInterval, overtake: Overtake? = nil) {
        self.stationID = stationID
        self.startTime = startTime
        self.duration = duration
        self.overtake = overtake
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

/// What missing this train actually costs.
///
/// Urgency alone cannot tell a rider whether to run. Two minutes of slack means
/// nothing if the next train is three minutes behind, and means everything if the
/// one you are looking at is the last express before the midday gap. This is the
/// second half of that sentence.
public struct MissedTrainCost: Sendable, Hashable {
    /// When you would arrive on the best option still open to you.
    public var fallbackArrival: Date
    /// When that option leaves, or `nil` if it is walking.
    public var fallbackBoarding: Date?
    /// How much later than this journey that is. Always positive.
    public var penalty: TimeInterval
    /// True when the fallback involves no train at all.
    public var fallbackIsWalking: Bool { fallbackBoarding == nil }

    public init(fallbackArrival: Date, fallbackBoarding: Date?, penalty: TimeInterval) {
        self.fallbackArrival = fallbackArrival
        self.fallbackBoarding = fallbackBoarding
        self.penalty = penalty
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
    /// Filled in after ranking, once every alternative is known.
    public var missedCost: MissedTrainCost?

    public init(
        legs: [JourneyLeg],
        departureTime: Date,
        arrivalTime: Date,
        urgency: Urgency,
        missedCost: MissedTrainCost? = nil
    ) {
        self.legs = legs
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.urgency = urgency
        self.missedCost = missedCost
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

    /// The verified overtake on this journey, if a faster train caught the rider
    /// up partway along.
    public var overtake: Overtake? {
        for leg in legs {
            if case .wait(let wait) = leg, let overtake = wait.overtake { return overtake }
        }
        return nil
    }

    /// True when the rider gets off one train specifically to catch a faster one
    /// that was running behind them.
    public var hasStrategicHold: Bool { overtake != nil }

    /// How much the overtake saves against staying on the slower train.
    public var overtakeSaving: TimeInterval? { overtake?.timeSaved }

    /// The platform wait where the overtake happens.
    public var overtakeWait: WaitLeg? {
        for leg in legs {
            if case .wait(let wait) = leg, wait.overtake != nil { return wait }
        }
        return nil
    }
}
