import Foundation

/// The kind of day a transit schedule is keyed on.
public enum DayType: String, Codable, Sendable, CaseIterable {
    case weekday
    case saturday
    case sunday

    public var label: String {
        switch self {
        case .weekday: return "Weekday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
}

/// One chunk of a day's service for a pattern.
///
/// Times are **seconds after midnight of the service day** and may exceed
/// 86,400 for trips that run after midnight (a 12:40 AM train on the Friday
/// schedule is 88,800, not 2,400 on Saturday). `ServiceDay` handles the rollover.
public enum ScheduleBlock: Sendable, Hashable {
    /// Explicit trip start times — what a real timetable gives you.
    case departures([Int])
    /// A frequency band: a trip every `every` seconds, starting at `from`,
    /// with the last trip at or before `until`.
    case frequency(from: Int, until: Int, every: Int)

    /// Trip start times, seconds after midnight, ascending.
    public var startTimes: [Int] {
        switch self {
        case .departures(let times):
            return times.sorted()
        case .frequency(let from, let until, let every):
            guard every > 0, until >= from else { return [] }
            var result: [Int] = []
            var t = from
            while t <= until {
                result.append(t)
                t += every
            }
            return result
        }
    }
}

/// When a pattern runs, keyed by day type.
public struct Schedule: Sendable {
    public var blocks: [DayType: [ScheduleBlock]]

    public init(blocks: [DayType: [ScheduleBlock]]) {
        self.blocks = blocks
    }

    /// Convenience for service that runs identically every day.
    public init(everyDay: [ScheduleBlock]) {
        self.blocks = Dictionary(uniqueKeysWithValues: DayType.allCases.map { ($0, everyDay) })
    }

    public static let never = Schedule(blocks: [:])

    /// Ascending, de-duplicated trip start times for a day type.
    public func startTimes(on dayType: DayType) -> [Int] {
        guard let blocks = blocks[dayType] else { return [] }
        var seen = Set<Int>()
        var result: [Int] = []
        for block in blocks {
            for t in block.startTimes where seen.insert(t).inserted {
                result.append(t)
            }
        }
        return result.sorted()
    }

    public func runs(on dayType: DayType) -> Bool {
        !startTimes(on: dayType).isEmpty
    }

    /// The service span on a day type, as seconds after midnight.
    public func span(on dayType: DayType) -> ClosedRange<Int>? {
        let times = startTimes(on: dayType)
        guard let first = times.first, let last = times.last else { return nil }
        return first...last
    }
}
