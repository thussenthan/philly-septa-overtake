import XCTest
@testable import MetroKit

final class ScheduleTests: XCTestCase {

    func testFrequencyBandExpandsInclusiveOfTheLastTrip() {
        let block = ScheduleBlock.frequency(from: 3600, until: 3600 + 1800, every: 600)
        XCTAssertEqual(block.startTimes, [3600, 4200, 4800, 5400])
    }

    func testFrequencyBandWithNoRoomYieldsOneTrip() {
        XCTAssertEqual(ScheduleBlock.frequency(from: 100, until: 100, every: 600).startTimes, [100])
    }

    func testDegenerateFrequencyBandIsEmptyRatherThanInfinite() {
        XCTAssertEqual(ScheduleBlock.frequency(from: 100, until: 500, every: 0).startTimes, [])
        XCTAssertEqual(ScheduleBlock.frequency(from: 500, until: 100, every: 60).startTimes, [])
    }

    func testBlocksAreMergedAndDeduplicated() {
        let schedule = Schedule(blocks: [
            .wednesday: [
                .departures([500, 100, 300]),
                .frequency(from: 300, until: 900, every: 300),
            ],
        ])
        XCTAssertEqual(schedule.startTimes(on: .wednesday), [100, 300, 500, 600, 900])
        XCTAssertEqual(schedule.startTimes(on: .sunday), [])
        XCTAssertTrue(schedule.runs(on: .wednesday))
        XCTAssertFalse(schedule.runs(on: .sunday))
    }

    func testSpanReportsFirstAndLastTrip() {
        let schedule = Schedule(blocks: [.saturday: [.departures([7200, 100, 3600])]])
        XCTAssertEqual(schedule.span(on: .saturday), 100...7200)
        XCTAssertNil(schedule.span(on: .wednesday))
    }
}

final class ServiceCalendarTests: XCTestCase {

    private let calendar = ServiceCalendar(usesHolidaySchedule: false)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        return gregorian.date(from: components)!
    }

    func testDayTypeMapping() {
        XCTAssertEqual(calendar.dayType(for: date(2026, 3, 4)), .wednesday)
        XCTAssertEqual(calendar.dayType(for: date(2026, 3, 7)), .saturday)
        XCTAssertEqual(calendar.dayType(for: date(2026, 3, 8)), .sunday)
    }

    func testMajorHolidaysFallBackToSundayService() {
        let holidays = ServiceCalendar(usesHolidaySchedule: true)
        XCTAssertEqual(holidays.dayType(for: date(2026, 7, 4)), .sunday)
        XCTAssertEqual(holidays.dayType(for: date(2026, 1, 1)), .sunday)
        XCTAssertEqual(holidays.dayType(for: date(2026, 11, 26)), .sunday) // 4th Thursday
        XCTAssertEqual(holidays.dayType(for: date(2026, 5, 25)), .sunday)  // last Monday in May
        XCTAssertEqual(holidays.dayType(for: date(2026, 9, 7)), .sunday)   // first Monday in Sept
        // A Monday in May that is not the last one is an ordinary weekday.
        XCTAssertEqual(holidays.dayType(for: date(2026, 5, 18)), .monday)
    }

    /// A trip listed at 88,800 s (12:40 AM) belongs to the previous service day.
    func testAfterMidnightTripsResolveAgainstThePreviousDay() {
        let query = DateInterval(start: date(2026, 3, 5, 0, 20), duration: 1800)
        let anchors = calendar.serviceDays(overlapping: query).map(\.noon)
        XCTAssertTrue(
            anchors.contains(calendar.noon(for: date(2026, 3, 4))),
            "the previous service day must be in scope near midnight, got \(anchors)"
        )

        let day = ServiceDay(noon: calendar.noon(for: date(2026, 3, 4)), dayType: .wednesday)
        XCTAssertEqual(day.date(secondsAfterMidnight: 88_800), date(2026, 3, 5, 0, 40))
    }

    /// Schedule times are anchored to noon, so a 10:00 AM train stays at 10:00 AM
    /// on the day the clocks move forward.
    func testDaylightSavingDoesNotShiftScheduledTimes() {
        // 2026-03-08 is the US spring-forward date.
        let day = ServiceDay(noon: calendar.noon(for: date(2026, 3, 8)), dayType: .sunday)
        let tenAM = day.date(secondsAfterMidnight: 10 * 3600)

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let components = gregorian.dateComponents([.hour, .minute], from: tenAM)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }
}

final class TimetableTests: XCTestCase {

    func testNextTripFromAMidPatternStationAccountsForTheOffset() throws {
        let timetable = Timetable(network: Fixture.network, calendar: Fixture.calendar)
        // The 08:00 local reaches C at 08:04, so at 08:03 that train is still catchable.
        let trip = try XCTUnwrap(timetable.nextTrip(
            of: Fixture.localSouth,
            departingFrom: "c",
            atOrAfter: Fixture.date(8, 3)
        ))
        XCTAssertEqual(timetable.departure(of: trip, at: "c"), Fixture.date(8, 4))
        XCTAssertEqual(timetable.departure(of: trip, at: "a"), Fixture.date(8, 0))
    }

    func testUpcomingTripsAreOrderedAndBounded() {
        let timetable = Timetable(network: Fixture.network, calendar: Fixture.calendar)
        let trips = timetable.upcomingTrips(
            of: Fixture.localSouth,
            departingFrom: "a",
            atOrAfter: Fixture.date(8, 1),
            count: 3
        )
        XCTAssertEqual(trips.count, 3)
        XCTAssertEqual(trips.map { timetable.departure(of: $0, at: "a") }, [
            Fixture.date(8, 10), Fixture.date(8, 20), Fixture.date(8, 30),
        ])
    }

    func testNoTripAfterServiceEnds() {
        let timetable = Timetable(network: Fixture.network, calendar: Fixture.calendar)
        XCTAssertNil(timetable.nextTrip(
            of: Fixture.expressSouth,
            departingFrom: "a",
            atOrAfter: Fixture.date(12, 0),
            within: 3600
        ))
    }

    func testPatternsSkippedByAStationReturnNoTrips() {
        let timetable = Timetable(network: Fixture.network, calendar: Fixture.calendar)
        // The express does not stop at B.
        XCTAssertNil(timetable.nextTrip(
            of: Fixture.expressSouth,
            departingFrom: "b",
            atOrAfter: Fixture.date(8, 0)
        ))
    }
}

final class WalkingModelTests: XCTestCase {

    func testCircuityAndOverheadsAreApplied() {
        var model = WalkingModel()
        model.metersPerSecond = 1.0
        model.circuityFactor = 1.25
        model.startupSeconds = 30
        model.stationEntrySeconds = 60

        XCTAssertEqual(model.walkSeconds(straightLineMeters: 400), 500, accuracy: 0.001)
        XCTAssertEqual(model.accessSeconds(straightLineMeters: 400), 590, accuracy: 0.001)
    }

    func testMilesPerHourRoundTrips() {
        var model = WalkingModel()
        model.milesPerHour = 3.0
        XCTAssertEqual(model.milesPerHour, 3.0, accuracy: 0.01)
        XCTAssertEqual(model.metersPerSecond, 1.341, accuracy: 0.01)
    }

    func testHaversineMatchesAKnownDistance() {
        // Erie to Allegheny on the Broad Street Line is about 850 m apart.
        let erie = Coordinate(latitude: 40.009234, longitude: -75.151250)
        let allegheny = Coordinate(latitude: 40.001589, longitude: -75.152922)
        XCTAssertEqual(erie.distance(to: allegheny), 858, accuracy: 25)
        XCTAssertEqual(erie.distance(to: erie), 0, accuracy: 0.001)
    }
}

final class FormatTests: XCTestCase {

    func testDurations() {
        XCTAssertEqual(Format.minutes(0), "under a minute")
        XCTAssertEqual(Format.minutes(240), "4 min")
        XCTAssertEqual(Format.minutes(3600), "1 hr")
        XCTAssertEqual(Format.minutes(4320), "1 hr 12 min")
        XCTAssertEqual(Format.compactMinutes(4320), "1h12m")
    }

    func testCountdown() {
        XCTAssertEqual(Format.countdown(-5), "now")
        XCTAssertEqual(Format.countdown(12), "0:12")
        XCTAssertEqual(Format.countdown(247), "4 min")
        XCTAssertEqual(Format.countdown(3725), "1 hr 2 min")
    }

    /// Seconds are for the last two minutes and nowhere else: a digit ticking eleven
    /// minutes out reads as urgent when there is nothing to be urgent about.
    func testCountdownOnlyShowsSecondsCloseIn() {
        XCTAssertEqual(Format.countdown(121), "2 min", "just outside the threshold")
        XCTAssertEqual(Format.countdown(120), "2:00", "exactly at it")
        XCTAssertEqual(Format.countdown(119), "1:59")
        XCTAssertEqual(Format.countdown(1), "0:01")
        XCTAssertEqual(Format.countdown(3600), "1 hr")
    }

    /// A countdown that rounds up promises time the rider hasn't got.
    func testCountdownFloorsRatherThanRounding() {
        XCTAssertEqual(Format.countdown(299), "4 min", "4:59 is four minutes, not five")
        XCTAssertEqual(Format.countdown(300), "5 min")
    }

    func testSignedMinutes() {
        XCTAssertEqual(Format.signedMinutes(0), "same time")
        XCTAssertEqual(Format.signedMinutes(180), "+3 min")
        XCTAssertEqual(Format.signedMinutes(-120), "−2 min")
    }

    func testRelativeLeave() {
        XCTAssertEqual(Format.relativeLeave(0), "now")
        XCTAssertEqual(Format.relativeLeave(45), "in about a minute")
        XCTAssertEqual(Format.relativeLeave(600), "in 10 min")
    }
}
