import Foundation

/// The day a transit schedule is keyed on.
///
/// Every day of the week, not the usual weekday/Saturday/Sunday triple. Rail
/// timetables are identical Monday to Friday, so three would be enough for the
/// subway — but SEPTA's trolley routes carry services scoped to particular
/// weekdays, and collapsing the week dropped 435 of 7,163 trips from the wider
/// network. Unioning them instead would be worse: it would promise a rider on a
/// Monday a trip that only runs on Fridays.
public enum DayType: String, Codable, Sendable, CaseIterable {
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    public var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    public var isWeekend: Bool { self == .saturday || self == .sunday }

    /// From `Calendar`'s weekday component, where 1 is Sunday.
    public static func from(calendarWeekday: Int) -> DayType {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
    }

    public static let weekdays: [DayType] = [.monday, .tuesday, .wednesday, .thursday, .friday]
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

/// When a pattern runs: per dated timetable key, and per day type.
///
/// Generated data is *dated*: it carries the departures for each timetable key of
/// the network's ``ServiceDates``, and a ``ServiceDay`` with a key is answered from
/// those, exactly. The day-type view is what a key-less day sees — hand-built
/// networks, and the weekday stand-ins for dates past the end of the data.
public struct Schedule: Sendable {
    public let blocks: [DayType: [ScheduleBlock]]

    /// Expanded, sorted, de-duplicated trip start times per day type.
    ///
    /// Resolved once at init rather than per lookup. That is the single biggest
    /// win available in this engine: `startTimes(on:)` sits inside the planner's
    /// innermost loop, and expanding a `.frequency` band there meant allocating
    /// and sorting a fresh array of every departure of the day, thousands of times
    /// per plan.
    private let resolved: [DayType: [Int]]
    /// Per timetable key; empty for a schedule without dates.
    private let resolvedByKey: [Int: [Int]]

    /// True when the schedule carries departures per timetable key.
    public var isDated: Bool { !resolvedByKey.isEmpty }

    public init(blocks: [DayType: [ScheduleBlock]]) {
        self.blocks = blocks
        self.resolved = blocks.compactMapValues(Self.resolve)
        self.resolvedByKey = [:]
    }

    /// A dated schedule: departures per timetable key, with the day-type view taken
    /// from `weekdayKeys` (Monday first), the keys that stand in for each weekday.
    public init(keyed: [Int: [ScheduleBlock]], weekdayKeys: [Int]) {
        let byKey = keyed.compactMapValues(Self.resolve)
        var blocks: [DayType: [ScheduleBlock]] = [:]
        var resolved: [DayType: [Int]] = [:]
        for (index, dayType) in DayType.allCases.enumerated() where index < weekdayKeys.count {
            let key = weekdayKeys[index]
            if let times = byKey[key] {
                blocks[dayType] = keyed[key]
                resolved[dayType] = times   // shared storage, not a copy
            }
        }
        self.blocks = blocks
        self.resolved = resolved
        self.resolvedByKey = byKey
    }

    /// Expanded, sorted, de-duplicated start times; nil when there are none.
    private static func resolve(_ dayBlocks: [ScheduleBlock]) -> [Int]? {
        var seen = Set<Int>()
        var times: [Int] = []
        for block in dayBlocks {
            for time in block.startTimes where seen.insert(time).inserted {
                times.append(time)
            }
        }
        return times.isEmpty ? nil : times.sorted()
    }

    /// Start times on a service day: from its timetable key when both it and this
    /// schedule have dates, else from its day type.
    @inline(__always)
    private func times(on day: ServiceDay) -> [Int]? {
        if let key = day.timetableKey, !resolvedByKey.isEmpty { return resolvedByKey[key] }
        return resolved[day.dayType]
    }

    /// Ascending, de-duplicated trip start times on a service day. O(1).
    public func startTimes(on day: ServiceDay) -> [Int] {
        times(on: day) ?? []
    }

    /// Whether the pattern runs at all on a service day.
    public func runs(on day: ServiceDay) -> Bool {
        times(on: day) != nil
    }

    /// Departures for one timetable key; empty for a schedule without dates.
    public func startTimes(forKey key: Int) -> [Int] {
        resolvedByKey[key] ?? []
    }

    /// The timetable keys this pattern runs on, ascending.
    public var activeKeys: [Int] { resolvedByKey.keys.sorted() }

    /// Convenience for service that runs identically every day.
    public init(everyDay: [ScheduleBlock]) {
        self.init(blocks: Dictionary(uniqueKeysWithValues: DayType.allCases.map { ($0, everyDay) }))
    }

    /// Convenience for the common case: one timetable shared by several days.
    ///
    /// Keeps the generated data compact, since a rail pattern usually runs the
    /// identical timetable Monday to Friday.
    public init(_ groups: [([DayType], [ScheduleBlock])]) {
        var blocks: [DayType: [ScheduleBlock]] = [:]
        for (days, dayBlocks) in groups {
            for day in days {
                blocks[day, default: []].append(contentsOf: dayBlocks)
            }
        }
        self.init(blocks: blocks)
    }

    /// Every day type this pattern runs on, in week order.
    public var activeDays: [DayType] {
        DayType.allCases.filter { runs(on: $0) }
    }

    public static let never = Schedule(blocks: [:])

    /// Ascending, de-duplicated trip start times for a day type. O(1).
    public func startTimes(on dayType: DayType) -> [Int] {
        resolved[dayType] ?? []
    }

    public func runs(on dayType: DayType) -> Bool {
        resolved[dayType] != nil
    }

    /// The service span on a day type, as seconds after midnight.
    public func span(on dayType: DayType) -> ClosedRange<Int>? {
        guard let times = resolved[dayType], let first = times.first, let last = times.last else { return nil }
        return first...last
    }

    /// Index of the first start time at or after `secondsAfterMidnight`, by binary
    /// search. `nil` when the pattern is done for the day.
    func firstStartIndex(on dayType: DayType, atOrAfter secondsAfterMidnight: Double) -> Int? {
        Self.firstIndex(in: resolved[dayType], atOrAfter: secondsAfterMidnight)
    }

    /// As above, for a service day (its timetable key when it has one).
    func firstStartIndex(on day: ServiceDay, atOrAfter secondsAfterMidnight: Double) -> Int? {
        Self.firstIndex(in: times(on: day), atOrAfter: secondsAfterMidnight)
    }

    private static func firstIndex(in times: [Int]?, atOrAfter secondsAfterMidnight: Double) -> Int? {
        guard let times, !times.isEmpty else { return nil }
        var low = 0
        var high = times.count
        while low < high {
            let mid = low + (high - low) / 2
            if Double(times[mid]) < secondsAfterMidnight {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < times.count ? low : nil
    }
}
