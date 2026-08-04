import Foundation

/// A concrete run of a `ServicePattern` on a specific day, with real clock times.
public struct Trip: Identifiable, Hashable, Sendable {
    public var patternID: PatternID
    /// The instant corresponding to offset 0 of the pattern.
    public var startTime: Date
    /// Seconds after midnight of the trip's start on its service day, retained
    /// so a timetable can be shown the way the operator publishes it.
    public var scheduledStartSecondsAfterMidnight: Int
    public var dayType: DayType

    public init(
        patternID: PatternID,
        startTime: Date,
        scheduledStartSecondsAfterMidnight: Int,
        dayType: DayType
    ) {
        self.patternID = patternID
        self.startTime = startTime
        self.scheduledStartSecondsAfterMidnight = scheduledStartSecondsAfterMidnight
        self.dayType = dayType
    }

    /// Stable identity: one pattern can only have one trip per start instant.
    public var id: String { "\(patternID.rawValue)@\(Int(startTime.timeIntervalSince1970))" }
}

public extension Trip {
    func departure(atOffset offset: TimeInterval) -> Date {
        startTime.addingTimeInterval(offset)
    }
}

/// Generates concrete trips from patterns + schedules.
///
/// Deliberately a value type with no caching of clock times: a `Timetable` is
/// cheap to build and safe to hold across day boundaries.
public struct Timetable: Sendable {
    public let network: Network
    public let calendar: ServiceCalendar

    public init(network: Network, calendar: ServiceCalendar = ServiceCalendar()) {
        self.network = network
        self.calendar = calendar
    }

    /// Every trip of `pattern` whose *start* falls inside `window`, ascending.
    ///
    /// Note the window applies to trip starts, not to the stop you care about.
    /// Use `trips(of:departingFrom:in:)` when you need departures from a station.
    public func trips(of pattern: ServicePattern, startingIn window: DateInterval) -> [Trip] {
        var result: [Trip] = []
        for day in calendar.serviceDays(overlapping: window) {
            for seconds in pattern.schedule.startTimes(on: day.dayType) {
                let start = day.date(secondsAfterMidnight: seconds)
                guard start >= window.start, start <= window.end else { continue }
                result.append(Trip(
                    patternID: pattern.id,
                    startTime: start,
                    scheduledStartSecondsAfterMidnight: seconds,
                    dayType: day.dayType
                ))
            }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }

    /// Trips of `pattern` that depart `station` inside `window`, ascending by departure.
    public func trips(
        of pattern: ServicePattern,
        departingFrom station: StationID,
        in window: DateInterval
    ) -> [Trip] {
        guard let index = pattern.stopIndex(of: station) else { return [] }
        let offset = pattern.stops[index].departureOffset
        // Shift the window back by the offset so we catch trips that started earlier.
        let startWindow = DateInterval(
            start: window.start.addingTimeInterval(-offset),
            end: window.end.addingTimeInterval(-offset)
        )
        return trips(of: pattern, startingIn: startWindow)
    }

    /// The first trip of `pattern` departing `station` at or after `time`.
    ///
    /// `searchHorizon` bounds how far ahead to look; returns `nil` when the
    /// pattern is done for the day (e.g. asking for an express train at 11 PM).
    public func nextTrip(
        of pattern: ServicePattern,
        departingFrom station: StationID,
        atOrAfter time: Date,
        within searchHorizon: TimeInterval = 4 * 3600
    ) -> Trip? {
        let window = DateInterval(start: time, end: time.addingTimeInterval(searchHorizon))
        return trips(of: pattern, departingFrom: station, in: window).first
    }

    /// The next `count` trips of `pattern` from `station` — used to show
    /// "and the one after that" without re-running the planner.
    public func upcomingTrips(
        of pattern: ServicePattern,
        departingFrom station: StationID,
        atOrAfter time: Date,
        count: Int,
        within searchHorizon: TimeInterval = 4 * 3600
    ) -> [Trip] {
        let window = DateInterval(start: time, end: time.addingTimeInterval(searchHorizon))
        return Array(trips(of: pattern, departingFrom: station, in: window).prefix(count))
    }
}

public extension Timetable {
    /// Departure time of `trip` from `station`, or `nil` if the pattern skips it.
    func departure(of trip: Trip, at station: StationID) -> Date? {
        guard let pattern = network.pattern(trip.patternID),
              let index = pattern.stopIndex(of: station) else { return nil }
        return trip.departure(atOffset: pattern.stops[index].departureOffset)
    }

    /// Arrival time of `trip` at `station`, or `nil` if the pattern skips it.
    func arrival(of trip: Trip, at station: StationID) -> Date? {
        guard let pattern = network.pattern(trip.patternID),
              let index = pattern.stopIndex(of: station) else { return nil }
        return trip.departure(atOffset: pattern.stops[index].arrivalOffset)
    }
}
