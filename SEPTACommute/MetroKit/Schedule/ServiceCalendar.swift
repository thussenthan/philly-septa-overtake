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
    public var dayType: DayType

    public init(noon: Date, dayType: DayType) {
        self.noon = noon
        self.dayType = dayType
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

    public init(
        timeZone: TimeZone = ServiceCalendar.easternTimeZone,
        usesHolidaySchedule: Bool = true,
        holidayDayType: DayType = .sunday
    ) {
        self.timeZone = timeZone
        self.usesHolidaySchedule = usesHolidaySchedule
        self.holidayDayType = holidayDayType
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
        let anchor = noon(for: date)
        return ServiceDay(noon: anchor, dayType: dayType(for: anchor))
    }

    private func serviceDay(offsetDays: Int, from date: Date) -> ServiceDay? {
        guard let shifted = calendar.date(byAdding: .day, value: offsetDays, to: noon(for: date)) else { return nil }
        let anchor = noon(for: shifted)
        return ServiceDay(noon: anchor, dayType: dayType(for: anchor))
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

/// The federal holidays on which SEPTA substitutes a weekend timetable.
///
/// Computed rather than table-driven so the app does not silently go stale.
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
