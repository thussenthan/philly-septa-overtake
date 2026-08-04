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

    public init(station: StationID, arrivalOffset: TimeInterval, departureOffset: TimeInterval) {
        self.station = station
        self.arrivalOffset = arrivalOffset
        self.departureOffset = max(arrivalOffset, departureOffset)
    }

    public init(station: StationID, offset: TimeInterval, dwell: TimeInterval = 0) {
        self.init(station: station, arrivalOffset: offset, departureOffset: offset + dwell)
    }
}

/// A stopping pattern plus the schedule on which it operates.
///
/// A `ServicePattern` is a template. Combined with a trip start time it becomes
/// a concrete `Trip` with real clock times at every stop.
public struct ServicePattern: Identifiable, Sendable {
    public var id: PatternID
    public var lineID: LineID
    public var kind: PatternKind
    public var direction: Direction
    /// Terminus shown on the train, e.g. "NRG" or "Fern Rock TC".
    public var headsign: String
    /// Ordered stops in travel order.
    public var stops: [PatternStop]
    public var schedule: Schedule

    public init(
        id: PatternID,
        lineID: LineID,
        kind: PatternKind,
        direction: Direction,
        headsign: String,
        stops: [PatternStop],
        schedule: Schedule
    ) {
        self.id = id
        self.lineID = lineID
        self.kind = kind
        self.direction = direction
        self.headsign = headsign
        self.stops = stops
        self.schedule = schedule
    }

    public var stationIDs: [StationID] { stops.map(\.station) }

    public func stopIndex(of station: StationID) -> Int? {
        stops.firstIndex { $0.station == station }
    }

    public func serves(_ station: StationID) -> Bool {
        stopIndex(of: station) != nil
    }

    /// True when this pattern can carry a rider from `board` to `alight` in one ride.
    public func carries(from board: StationID, to alight: StationID) -> Bool {
        guard let b = stopIndex(of: board), let a = stopIndex(of: alight) else { return false }
        return b < a
    }

    /// End-to-end running time of the pattern.
    public var duration: TimeInterval {
        guard let first = stops.first, let last = stops.last else { return 0 }
        return last.arrivalOffset - first.departureOffset
    }
}
