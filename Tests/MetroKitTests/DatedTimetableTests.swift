import Foundation
import XCTest
@testable import MetroKit

/// The bundled timetables are date-exact: each date runs the service SEPTA's
/// calendar files give for that date, not a sample of its weekday.
///
/// Every expected time below was read straight from SEPTA's GTFS v202611010
/// (calendar.txt + calendar_dates.txt + stop_times.txt), and each test picks a date
/// where the old one-date-per-weekday sampling gave a different answer. When the
/// bundled data is regenerated from a later feed these dates fall out of its window
/// and the tests skip; replace them with dates and times from the new feed
/// (`tools/verify_timetables.py` checks every date mechanically either way).
final class DatedTimetableTests: XCTestCase {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let feed = "v202611010"

    var extended: ExtendedNetwork { ExtendedPlannerTests.network }
    var metro: Network { SEPTAData.network }

    override func setUpWithError() throws {
        try XCTSkipUnless(SEPTAData.feedVersion == Self.feed && extended.busFeedVersion == Self.feed,
                          "times below are from feed \(Self.feed)")
    }

    func date(_ yyyymmdd: String, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = Int(yyyymmdd.prefix(4))
        c.month = Int(yyyymmdd.dropFirst(4).prefix(2))
        c.day = Int(yyyymmdd.suffix(2))
        c.hour = hour
        c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        return cal.date(from: c)!
    }

    func clock(seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, seconds / 60 % 60)
    }

    func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Self.newYork
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: - All of SEPTA (SEPTAExtended.txt)

    /// Scheduled times of `route` at the stop named `stop`, on the service date
    /// `yyyymmdd`, between `from` and `to` ("HH:mm"), as the planner's clock sees
    /// them: the date's own timetable key, nothing projected.
    func extendedDepartures(_ route: String, at stop: String, on yyyymmdd: String,
                            from: String, to: String) -> [String] {
        let net = extended
        let frame = ServiceFrame(departAt: date(yyyymmdd), timeZone: Self.newYork)
        var out = Set<String>()
        for p in 0..<net.patternCount where net.routes[Int(net.patternRoute[p])].shortName == route {
            let key = net.timetableKey(rail: net.patternIsRail[p], dayNumber: frame.dayNumbers.1,
                                       dayType: frame.today.dayType, project: false)
            let count = Int(net.patternStart[p + 1] - net.patternStart[p])
            for pos in 0..<count - 1 where net.stopNames[net.stop(p, pos)] == stop {
                for t in net.tripRange(pattern: p, key: key) {
                    let time = clock(seconds: Int(net.tripStarts[t] + net.offset(p, pos)))
                    if time >= from, time < to { out.insert(time) }
                }
            }
        }
        return out.sorted()
    }

    /// Paoli/Thorndale weekday trains from Malvern: SEPTA retimed them from
    /// Monday 23 November. The old sampling baked in November's times for the
    /// whole window (and then dropped rail altogether after 21 November).
    func testRailWeekdayUsesTheTimetableInForceOnTheDate() {
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261117", from: "07:30", to: "08:00"),
                       ["07:34", "07:44"])
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261208", from: "07:30", to: "08:00"),
                       ["07:39", "07:49"])
    }

    func testRailSaturdayAndSundayUseTheTimetableInForceOnTheDate() {
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261114", from: "05:00", to: "07:00"),
                       ["05:33", "06:33", "06:58"])
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261212", from: "05:00", to: "07:00"),
                       ["05:38", "06:38", "06:58"])
        // On Sundays the 06:58 westbound ends at Malvern rather than running on to
        // Thorndale, so it is an arrival, not a departure.
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261115", from: "05:00", to: "07:00"),
                       ["05:33", "06:33"])
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20261213", from: "05:00", to: "07:00"),
                       ["05:38", "06:38"])
    }

    /// Christmas Day 2026 is a Friday with its own one-date rail service
    /// (SID1897939): the Airport Line runs hourly, not every half hour. (Trains
    /// from the airport that end at Suburban Station are arrivals, not listed.)
    func testChristmasRunsItsSpecialRailService() {
        XCTAssertEqual(extendedDepartures("AIR", at: "Suburban Station", on: "20261218", from: "06:00", to: "07:00"),
                       ["06:25", "06:35", "06:55"])
        XCTAssertEqual(extendedDepartures("AIR", at: "Suburban Station", on: "20261225", from: "06:00", to: "07:00"),
                       ["06:55"])
        XCTAssertEqual(extendedDepartures("AIR", at: "Suburban Station", on: "20261231", from: "06:00", to: "07:00"),
                       ["06:25", "06:35", "06:55"])
    }

    /// … and the planner rides it: at 06:15 on Christmas morning the next train to
    /// the airport is 06:55, where a Friday has one at 06:25.
    func testPlannerRidesTheChristmasTimetable() throws {
        let suburban = try XCTUnwrap(extended.stopNames.firstIndex(of: "Suburban Station"))
        let terminals = try XCTUnwrap(extended.stopNames.firstIndex(of: "Airport Terminals E & F"))
        var planner = ExtendedPlanner(network: extended)
        planner.excludedModes = [.bus, .trolley, .metro]
        func firstAirportTrain(_ day: String) throws -> String {
            let options = planner.plan(from: extended.stopCoordinates[suburban], to: extended.stopCoordinates[terminals],
                                       departAt: date(day, 6, 15))
            let ride = try XCTUnwrap(options.flatMap(\.rides).filter { $0.routeShortName == "AIR" }
                .min { $0.departure < $1.departure }, "no Airport Line ride on \(day)")
            return clock(ride.departure)
        }
        XCTAssertEqual(try firstAirportTrain("20261225"), "06:55")
        XCTAssertEqual(try firstAirportTrain("20261218"), "06:25")
    }

    /// Route 58 from Frankford Transit Center, weekday / Saturday / Sunday, and on
    /// Thanksgiving, which SEPTA runs on its Sunday bus timetable for this route.
    func testBusWeekdaySaturdaySundayAndHoliday() {
        let stop = "Frankford Transit Center - Rt 58"
        XCTAssertEqual(extendedDepartures("58", at: stop, on: "20261208", from: "07:00", to: "08:00"),
                       ["07:02", "07:14", "07:26", "07:38", "07:50"])
        XCTAssertEqual(extendedDepartures("58", at: stop, on: "20261212", from: "07:00", to: "08:00"),
                       ["07:08", "07:28", "07:46"])
        XCTAssertEqual(extendedDepartures("58", at: stop, on: "20261213", from: "07:00", to: "08:00"),
                       ["07:18", "07:45"])
        XCTAssertEqual(extendedDepartures("58", at: stop, on: "20261126", from: "07:00", to: "08:00"),
                       ["07:18", "07:45"])
    }

    /// Both feeds' calendars run to 20 February 2027 even though the rail
    /// feed_info stops on 21 November; past the end nothing is projected.
    func testServiceWindowsAreTheCalendarsNotFeedInfo() {
        XCTAssertEqual(extended.railValidUntil, "20270220")
        XCTAssertEqual(extended.busValidUntil, "20270220")
        XCTAssertEqual(extended.expiredModes(onServiceDate: "20261208"), [])
        XCTAssertEqual(extendedDepartures("PAO", at: "Malvern", on: "20270222", from: "00:00", to: "23:59"), [])
    }

    // MARK: - Metro planner (GeneratedSEPTAData.swift)

    /// Departures of `route` heading `direction` from `station` between the two
    /// clock times on a date, through the same `Timetable` the planner uses.
    func metroDepartures(_ route: RouteID, _ direction: Direction, from station: StationID,
                         on yyyymmdd: String, _ from: (Int, Int), _ to: (Int, Int)) -> [String] {
        let timetable = Timetable(network: metro)
        let window = DateInterval(start: date(yyyymmdd, from.0, from.1),
                                  end: date(yyyymmdd, to.0, to.1).addingTimeInterval(-1))
        var out = Set<String>()
        for pattern in metro.patterns(serving: station)
        where pattern.routeID == route && pattern.direction == direction && pattern.allowsBoarding(at: station) {
            for trip in timetable.trips(of: pattern, departingFrom: station, in: window) {
                if let departure = timetable.departure(of: trip, at: station) { out.insert(clock(departure)) }
            }
        }
        return out.sorted()
    }

    func testMetroWeekdaySaturdaySunday() {
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20261208", (7, 0), (8, 0)),
                       ["07:05", "07:12", "07:19", "07:26", "07:33", "07:40", "07:47", "07:54"])
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20261212", (7, 0), (8, 0)),
                       ["07:03", "07:14", "07:25", "07:35", "07:45", "07:55"])
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20261213", (7, 0), (8, 0)),
                       ["07:07", "07:19", "07:31", "07:43", "07:55"])
    }

    /// Thanksgiving: SEPTA adds B1 trips to its Sunday service (service 17, also
    /// New Year's Day). Substituting the plain Sunday timetable, as the app did,
    /// showed 09:27 and 09:37 trains that do not run and missed 09:25 / 09:33.
    func testMetroThanksgivingRunsItsHolidayService() {
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20261126", (9, 0), (10, 0)),
                       ["09:07", "09:17", "09:25", "09:33", "09:41", "09:49", "09:57"])
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20261122", (9, 0), (10, 0)),
                       ["09:07", "09:17", "09:27", "09:37", "09:47", "09:57"])
    }

    /// Game-day express: calendar_dates adds two B2 runs to NRG on Monday
    /// 2 November (18:10 and 18:20 from Fern Rock), and only then.
    func testMetroCalendarDatesExceptionMatchesExactly() {
        XCTAssertEqual(metroDepartures("B2", .southbound, from: "fern-rock", on: "20261102", (17, 30), (19, 0)),
                       ["17:33", "17:40", "17:47", "17:54", "18:01", "18:10", "18:20"])
        XCTAssertEqual(metroDepartures("B2", .southbound, from: "fern-rock", on: "20261109", (17, 30), (19, 0)),
                       ["17:33", "17:40", "17:47", "17:54", "18:01"])
    }

    /// Past the window the Metro planner still answers, on the weekday's most
    /// common timetable, and says the data has run out.
    func testMetroPastTheWindowProjectsTheWeekdayTimetable() {
        XCTAssertEqual(metroDepartures("B1", .southbound, from: "fern-rock", on: "20270302", (7, 0), (8, 0)),
                       metroDepartures("B1", .southbound, from: "fern-rock", on: "20261208", (7, 0), (8, 0)))
        XCTAssertTrue(metro.provenance.hasNoServiceData(asOf: date("20270302", 8, 0)))
        XCTAssertFalse(metro.provenance.hasNoServiceData(asOf: date("20270220", 8, 0)))
    }

    // MARK: - ServiceDates

    func testDayNumbersAndKeys() throws {
        XCTAssertEqual(ServiceDates.dayNumber(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(ServiceDates.dayNumber(year: 2000, month: 3, day: 1), 11_017)
        XCTAssertEqual(ServiceDates.dayNumber("20261101"), ServiceDates.dayNumber(year: 2026, month: 11, day: 1))
        XCTAssertNil(ServiceDates.dayNumber("2026110"))
        let dates = try XCTUnwrap(ServiceDates(first: "20261230", keys: [0, 1, 2], weekdayKeys: [3, 3, 3, 3, 3, 4, 5]))
        XCTAssertEqual(dates.keyCount, 6)
        XCTAssertEqual(dates.key(year: 2027, month: 1, day: 1, dayType: .friday), 2)
        XCTAssertEqual(dates.key(year: 2027, month: 1, day: 2, dayType: .saturday), 4, "outside: the weekday's key")
        XCTAssertNil(dates.exactKey(year: 2026, month: 12, day: 29))
    }

    func testCalendarCarriesTheKeyIntoServiceDays() throws {
        let dates = try XCTUnwrap(metro.serviceDates)
        let calendar = ServiceCalendar(serviceDates: dates)
        let christmas = calendar.serviceDay(containing: date("20261225", 9))
        XCTAssertEqual(christmas.dayType, .sunday, "the weekday rule still names the day")
        let index = ServiceDates.dayNumber(year: 2026, month: 12, day: 25) - dates.firstDay
        XCTAssertEqual(christmas.timetableKey, dates.keys[index])
        // After midnight is still the previous service day, with its key.
        let late = calendar.serviceDays(overlapping: DateInterval(start: date("20261226", 0, 30), duration: 600))
        XCTAssertTrue(late.contains { $0.timetableKey == dates.keys[index] })
    }
}
