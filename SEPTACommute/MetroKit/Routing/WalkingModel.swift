import Foundation

/// Turns distance into a walking time.
///
/// Straight-line distance badly underestimates a walk in a gridded city, so the
/// model applies a circuity factor, and adds fixed overheads for getting out of
/// a building and down to a subway platform. Those overheads are the difference
/// between "the station is 300 m away" and "you will miss the train".
public struct WalkingModel: Sendable, Hashable {
    /// Walking speed. 1.35 m/s ≈ 3.0 mph, a typical unhurried adult pace.
    public var metersPerSecond: Double
    /// Multiplier applied to crow-flies distance to approximate street routing.
    /// ~1.25 fits a rectangular grid such as Center City Philadelphia.
    public var circuityFactor: Double
    /// Time to get from a doorway to the sidewalk and oriented.
    public var startupSeconds: TimeInterval
    /// Time from the sidewalk to the platform: stairs, fare gate, escalator.
    public var stationEntrySeconds: TimeInterval
    /// Time from platform to street at the far end.
    public var stationExitSeconds: TimeInterval

    public init(
        metersPerSecond: Double = 1.35,
        circuityFactor: Double = 1.25,
        startupSeconds: TimeInterval = 30,
        stationEntrySeconds: TimeInterval = 60,
        stationExitSeconds: TimeInterval = 45
    ) {
        self.metersPerSecond = metersPerSecond
        self.circuityFactor = circuityFactor
        self.startupSeconds = startupSeconds
        self.stationEntrySeconds = stationEntrySeconds
        self.stationExitSeconds = stationExitSeconds
    }

    /// Miles per hour, for a settings slider that speaks human.
    public var milesPerHour: Double {
        get { metersPerSecond * 3600 / Coordinate.metersPerMile }
        set { metersPerSecond = max(0.3, newValue * Coordinate.metersPerMile / 3600) }
    }

    /// Street-following distance estimate, in meters.
    public func routedMeters(straightLine meters: Double) -> Double {
        meters * circuityFactor
    }

    /// Pure walking time for a straight-line distance, excluding overheads.
    public func walkSeconds(straightLineMeters meters: Double) -> TimeInterval {
        guard metersPerSecond > 0 else { return .infinity }
        return routedMeters(straightLine: meters) / metersPerSecond
    }

    /// Time from a street address to standing on the platform.
    public func accessSeconds(straightLineMeters meters: Double) -> TimeInterval {
        startupSeconds + walkSeconds(straightLineMeters: meters) + stationEntrySeconds
    }

    /// Time from stepping off the train to arriving at a street address.
    public func egressSeconds(straightLineMeters meters: Double) -> TimeInterval {
        stationExitSeconds + walkSeconds(straightLineMeters: meters)
    }
}

/// Measured walking times that override the geometric estimate.
///
/// The app fills this from MapKit walking directions, which follow real streets.
/// The planner works fine without it — the estimate is the fallback, not a stub.
public struct WalkTimeOverrides: Sendable {
    public enum Kind: Hashable, Sendable {
        case access(StationID)
        case egress(StationID)
    }

    private var values: [Kind: TimeInterval]

    public init(_ values: [Kind: TimeInterval] = [:]) {
        self.values = values
    }

    public static let none = WalkTimeOverrides()

    public subscript(kind: Kind) -> TimeInterval? {
        get { values[kind] }
        set { values[kind] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }
}
