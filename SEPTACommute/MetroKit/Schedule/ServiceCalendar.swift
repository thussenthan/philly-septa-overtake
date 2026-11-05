import Foundation

/// A single service day: the day it anchors to, and which timetable applies.
///
/// Schedule times are "seconds after midnight", but they are resolved against
/// **noon minus twelve hours** rather than literal midnight. That is the GTFS
/// convention, and it is what keeps a 10:00 AM train at 10:00 AM on the two days
/// a year when the clocks move.
public struct ServiceDay: Hashable, Sendable {
    /// Noon on the service day, in the agency's time zone.
    public var noon: Date
    /// The day of the week, or the holiday substitute (see ``ServiceCalendar``).
    /// What a timetable without dates is looked up by.
    public var dayType: DayType
    /// The dated timetable that runs on this day — an index into the network's
    /// ``ServiceDates`` — or nil when the calendar has no dates to go on.
    ///
    /// When set it wins over `dayType`: it is SEPTA's own answer for this exact date,
    /// holidays, timetable changes and one-off specials included.
    public var timetableKey: Int?

    public init(noon: Date, dayType: DayType, timetableKey: Int? = nil) {
        self.noon = noon
        self.dayType = dayType
        self.timetableKey = timetableKey
    }

    /// Clock time for a "seconds after midnight" schedule value.
    public func date(secondsAfterMidnight seconds: Int) -> Date {
        noon.addingTimeInterval(TimeInterval(seconds) - 12 * 3600)
    }

    /// Nominal midnight that starts this service day.
    public var start: Date { date(secondsAfterMidnight: 0) }
}

/// Maps wall-clock instants to service days, in the agency's time zone.
///
/// Two details matter for a subway that runs past midnight:
///
/// 1. A trip starting at 12:40 AM Saturday belongs to Friday's *weekday*
///    service day, at 88,800 seconds after midnight — not 2,400 on Saturday.
/// 2. So any query near midnight must consider more than one service day.
///    `serviceDays(overlapping:)` returns every day whose trips could be
///    running in the window.
public struct ServiceCalendar: Sendable {
    public var timeZone: TimeZone
    /// Whether the agency substitutes a weekend timetable on major holidays.
    public var usesHolidaySchedule: Bool
    /// The day type substituted on those holidays (SEPTA: Sunday service).
    public var holidayDayType: DayType
    /// The feed's date-by-date calendar. When present, every service day carries the
    /// ``ServiceDay/timetableKey`` SEPTA publishes for that date, and the weekday and
    /// holiday rules above only matter outside the dates it covers. `Timetable` fills
    /// this in from its network, so callers rarely set it themselves.
    public var serviceDates: ServiceDates?

    public init(
        timeZone: TimeZone = ServiceCalendar.easternTimeZone,
        usesHolidaySchedule: Bool = true,
        holidayDayType: DayType = .sunday,
        serviceDates: ServiceDates? = nil
    ) {
        self.timeZone = timeZone
        self.usesHolidaySchedule = usesHolidaySchedule
        self.holidayDayType = holidayDayType
        self.serviceDates = serviceDates
    }

    public static let easternTimeZone =
        TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    public func dayType(for date: Date) -> DayType {
        if usesHolidaySchedule, HolidayCalendar.isMajorHoliday(date, in: timeZone) {
            return holidayDayType
        }
        return DayType.from(calendarWeekday: calendar.component(.weekday, from: date))
    }

    /// Noon on the calendar day containing `date`.
    public func noon(for date: Date) -> Date {
        let cal = calendar
        let start = cal.startOfDay(for: date)
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: start)
            ?? start.addingTimeInterval(12 * 3600)
    }

    public func serviceDay(containing date: Date) -> ServiceDay {
        makeServiceDay(anchor: noon(for: date))
    }

    private func serviceDay(offsetDays: Int, from date: Date) -> ServiceDay? {
        guard let shifted = calendar.date(byAdding: .day, value: offsetDays, to: noon(for: date)) else { return nil }
        return makeServiceDay(anchor: noon(for: shifted))
    }

    private func makeServiceDay(anchor: Date) -> ServiceDay {
        let type = dayType(for: anchor)
        guard let dates = serviceDates else { return ServiceDay(noon: anchor, dayType: type) }
        let parts = calendar.dateComponents([.year, .month, .day], from: anchor)
        let key = dates.key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0, dayType: type)
        return ServiceDay(noon: anchor, dayType: type, timetableKey: key)
    }

    /// The service date of `date` (the calendar day of its noon), `yyyyMMdd`.
    public func serviceDateString(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: noon(for: date))
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Every service day whose trips could plausibly be running inside `window`,
    /// ascending. Includes the previous day (late-night trips spilling forward)
    /// and the next day (for windows that cross midnight).
    public func serviceDays(overlapping window: DateInterval) -> [ServiceDay] {
        var days: [ServiceDay] = []
        var seen = Set<Date>()
        for offset in -1...1 {
            guard let day = serviceDay(offsetDays: offset, from: window.start) else { continue }
            if seen.insert(day.noon).inserted { days.append(day) }
        }
        if let endDay = serviceDay(offsetDays: 0, from: window.end), seen.insert(endDay.noon).inserted {
            days.append(endDay)
        }
        if let endNext = serviceDay(offsetDays: 1, from: window.end), seen.insert(endNext.noon).inserted {
            days.append(endNext)
        }
        return days.sorted { $0.noon < $1.noon }
    }

    /// Seconds after midnight of the calendar day containing `date`.
    public func secondsAfterMidnight(for date: Date) -> Int {
        let day = serviceDay(containing: date)
        return Int(date.timeIntervalSince(day.start).rounded())
    }
}

/// A feed's service calendar, date by date.
///
/// SEPTA's timetable is not a weekly one with a few holidays: its calendar files
/// change trips date by date — a timetable revision mid-feed, Christmas and New
/// Year's specials, Thanksgiving, a game at the stadiums. The generators group the
/// dates into *timetable keys*, one per distinct set of services SEPTA runs, and
/// each pattern lists its departures per key. This is the date → key table.
public struct ServiceDates: Sendable, Hashable {
    /// First date covered, as a day number (days since 1970-01-01).
    public let firstDay: Int
    /// `keys[i]` is the timetable key of `firstDay + i`.
    public let keys: [Int]
    /// Per weekday, Monday first: the key standing in for a date outside the table —
    /// the one that covers the most dates of that weekday. A projection, not
    /// SEPTA's word; the app says so (``PlanNote/scheduleOutOfDate(feedEndDate:)``).
    public let weekdayKeys: [Int]

    /// Number of distinct keys (one more than the largest).
    public let keyCount: Int

    public init(firstDay: Int, keys: [Int], weekdayKeys: [Int]) {
        self.firstDay = firstDay
        self.keys = keys
        self.weekdayKeys = weekdayKeys
        self.keyCount = max(keys.max() ?? -1, weekdayKeys.max() ?? -1) + 1
    }

    /// From `yyyyMMdd` and the key list; nil when malformed.
    public init?(first yyyymmdd: String, keys: [Int], weekdayKeys: [Int]) {
        guard let day = Self.dayNumber(yyyymmdd), weekdayKeys.count == 7, !keys.isEmpty else { return nil }
        self.init(firstDay: day, keys: keys, weekdayKeys: weekdayKeys)
    }

    /// Last date covered, as a day number.
    public var lastDay: Int { firstDay + keys.count - 1 }

    /// The key SEPTA publishes for a date, if the table covers it.
    public func exactKey(year: Int, month: Int, day: Int) -> Int? {
        let index = Self.dayNumber(year: year, month: month, day: day) - firstDay
        return keys.indices.contains(index) ? keys[index] : nil
    }

    /// The key for a date: exact inside the table, else the weekday's stand-in.
    public func key(year: Int, month: Int, day: Int, dayType: DayType) -> Int {
        if let exact = exactKey(year: year, month: month, day: day) { return exact }
        return weekdayKeys[DayType.allCases.firstIndex(of: dayType) ?? 0]
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
    /// days_from_civil), so a lookup costs no `Calendar` arithmetic.
    public static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// `yyyyMMdd` → day number; nil when malformed.
    public static func dayNumber(_ yyyymmdd: String) -> Int? {
        guard yyyymmdd.count == 8, let value = Int(yyyymmdd) else { return nil }
        let year = value / 10_000, month = value / 100 % 100, day = value % 100
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return dayNumber(year: year, month: month, day: day)
    }
}

/// The federal holidays on which SEPTA substitutes a weekend timetable.
///
/// Only consulted where there is no dated calendar to ask: the bundled timetables
/// carry SEPTA's own service for every date they cover, holidays included, so this
/// rule applies to hand-built networks and to dates past the end of the data.
/// Agencies do deviate — treat this as a sane default, not gospel.
public enum HolidayCalendar {
    public static func isMajorHoliday(_ date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .weekday, .weekdayOrdinal], from: date)
        guard let month = parts.month, let day = parts.day,
              let weekday = parts.weekday, let ordinal = parts.weekdayOrdinal else { return false }

        // Fixed-date holidays: New Year's Day, Juneteenth, Independence Day, Christmas.
        switch (month, day) {
        case (1, 1), (6, 19), (7, 4), (12, 25):
            return true
        default:
            break
        }

        // Memorial Day: last Monday in May.
        if month == 5, weekday == 2,
           let nextWeek = calendar.date(byAdding: .day, value: 7, to: date),
           calendar.component(.month, from: nextWeek) != 5 {
            return true
        }
        // Labor Day: first Monday in September.
        if month == 9, weekday == 2, ordinal == 1 { return true }
        // Thanksgiving: fourth Thursday in November.
        if month == 11, weekday == 5, ordinal == 4 { return true }

        return false
    }
}
