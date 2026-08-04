import XCTest
@testable import MetroKit

/// Covers the lookups the planner leans on thousands of times per plan. These are
/// pure performance machinery, which is exactly why they need tests: a subtly
/// wrong binary search produces plausible departure times rather than a crash.
extension ServicePattern {
    /// First, middle and last stop — the zero-offset, mid-offset and full-offset
    /// cases. Enough to catch an indexing or offset bug without walking every stop
    /// of every pattern on a 585-station network.
    var sampledStops: [PatternStop] {
        guard stops.count > 2 else { return stops }
        return [stops[0], stops[stops.count / 2], stops[stops.count - 1]]
    }
}

final class ScheduleIndexTests: XCTestCase {

    private let schedule = Schedule(blocks: [
        .wednesday: [.departures([100, 300, 500, 900])],
    ])

    func testFirstStartIndexFindsTheEarliestAtOrAfter() {
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 0), 0)
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 100), 0, "at-or-after is inclusive")
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 101), 1)
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 300), 1)
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 899), 3)
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: 900), 3)
    }

    func testFirstStartIndexIsNilPastTheLastTrip() {
        XCTAssertNil(schedule.firstStartIndex(on: .wednesday, atOrAfter: 901))
        XCTAssertNil(schedule.firstStartIndex(on: .saturday, atOrAfter: 0), "no Saturday service")
    }

    func testNegativeThresholdIsHandled() {
        // A station early in the pattern can push the threshold below zero.
        XCTAssertEqual(schedule.firstStartIndex(on: .wednesday, atOrAfter: -5_000), 0)
    }

    /// The binary search has to agree with a plain scan over the whole day, at
    /// every second where the answer could change.
    func testBinarySearchAgreesWithALinearScan() {
        let dense = Schedule(blocks: [
            .wednesday: [
                .frequency(from: 5 * 3600, until: 9 * 3600, every: 420),
                .departures([13 * 3600, 13 * 3600 + 90]),
                .frequency(from: 16 * 3600, until: 18 * 3600, every: 600),
            ],
        ])
        let times = dense.startTimes(on: .wednesday)
        XCTAssertFalse(times.isEmpty)
        XCTAssertEqual(times, times.sorted(), "resolved times must be ascending")
        XCTAssertEqual(times.count, Set(times).count, "and de-duplicated")

        for threshold in stride(from: -600, through: 20 * 3600, by: 37) {
            let expected = times.firstIndex { $0 >= threshold }
            let actual = dense.firstStartIndex(on: .wednesday, atOrAfter: Double(threshold))
            XCTAssertEqual(actual, expected, "mismatch at threshold \(threshold)")
        }
    }

    func testFrequencyBandsAreResolvedOnceAndReturnedIdentically() {
        let dense = Schedule(blocks: [.wednesday: [.frequency(from: 0, until: 3600, every: 600)]])
        XCTAssertEqual(dense.startTimes(on: .wednesday), dense.startTimes(on: .wednesday))
        XCTAssertEqual(dense.startTimes(on: .wednesday), [0, 600, 1200, 1800, 2400, 3000, 3600])
    }
}

final class PatternIndexTests: XCTestCase {

    func testStopIndexMatchesAPlainSearch() {
        for pattern in SEPTAData.network.patterns {
            for stop in pattern.stops {
                XCTAssertEqual(
                    pattern.stopIndex(of: stop.station),
                    pattern.stops.firstIndex { $0.station == stop.station },
                    "\(pattern.id) disagrees about \(stop.station)"
                )
            }
            XCTAssertNil(pattern.stopIndex(of: "not-a-station"))
        }
    }

    /// Loop routes visit the same station twice. The Broad Street Line has none,
    /// but the wider Metro map does — 28 repeated stops across its patterns — and
    /// the index has to resolve to the *first* visit, the way a linear search
    /// would, or every departure time computed for those stations is wrong by the
    /// length of the loop.
    func testRepeatedStationResolvesToTheFirstVisit() {
        let looping = ServicePattern(
            id: "loop",
            lineID: "G",
            routeID: "G1",
            kind: .local,
            direction: .northbound,
            headsign: "Loop",
            stops: [
                PatternStop(station: "a", offset: 0),
                PatternStop(station: "b", offset: 120),
                PatternStop(station: "c", offset: 240),
                PatternStop(station: "b", offset: 360),  // back around the loop
            ],
            schedule: Schedule(everyDay: [.departures([8 * 3600])])
        )
        XCTAssertEqual(looping.stopIndex(of: "b"), 1)
        XCTAssertEqual(looping.stops[looping.stopIndex(of: "b")!].arrivalOffset, 120)
    }
}

final class NetworkIndexTests: XCTestCase {

    private let network = SEPTAData.network

    func testRouteCountsReflectTheOperatorsRoutes() {
        // Olney is where a rider changes between the local, the express and the
        // Spur, which is the whole reason route identity is modelled separately
        // from the line letter.
        XCTAssertGreaterThan(network.routeCount(at: "olney"), 1)
        XCTAssertTrue(network.isInterchange("olney"))
        XCTAssertTrue(network.isInterchange("girard"))
        XCTAssertEqual(network.routeCount(at: "not-a-station"), 0)
        XCTAssertFalse(network.isInterchange("not-a-station"))
    }

    /// Every station where the planner needs to offer a change must be flagged as
    /// an interchange, or the transfer is silently unreachable.
    func testEveryStationServedByMoreThanOneRouteIsAnInterchange() {
        for station in network.stations {
            let routes = Set(network.patterns(serving: station.id).map(\.routeID))
            XCTAssertEqual(network.routeCount(at: station.id), routes.count, station.id.rawValue)
            XCTAssertEqual(network.isInterchange(station.id), routes.count > 1, station.id.rawValue)
        }
    }

    func testPatternsServingAStationAreComplete() {
        for pattern in network.patterns {
            for stop in pattern.stops {
                XCTAssertTrue(
                    network.patterns(serving: stop.station).contains { $0.id == pattern.id },
                    "\(pattern.id) missing from the index at \(stop.station)"
                )
            }
        }
    }
}

final class TimetableIndexTests: XCTestCase {

    private let network = SEPTAData.network
    private lazy var timetable = Timetable(network: network)
    private let calendar = ServiceCalendar()

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        return gregorian.date(from: components)!
    }

    /// The fast overload takes pre-resolved service days. If it ever disagreed
    /// with the convenience version, the planner and the rest of the app would be
    /// reading different timetables.
    func testPreResolvedServiceDaysGiveTheSameAnswer() {
        let horizon: TimeInterval = 4 * 3600
        // Across a weekday, a Saturday, and either side of midnight.
        let instants = [
            date(8, 5, 6, 12), date(8, 5, 8, 15), date(8, 5, 13, 40),
            date(8, 5, 23, 55), date(8, 6, 0, 30), date(8, 6, 2, 15),
            date(8, 8, 11, 0), date(8, 9, 15, 30),
        ]
        // Every pattern, but the interesting stops rather than all of them: first,
        // middle and last exercise the zero, mid- and full-offset cases, which is
        // where this can differ. Exhausting 585 stations' worth of stops took 13
        // seconds of a 20-second suite for no extra coverage.
        for pattern in network.patterns {
            for stop in pattern.sampledStops {
                for instant in instants {
                    let window = DateInterval(start: instant, end: instant.addingTimeInterval(horizon))
                    let fast = timetable.nextTrip(
                        of: pattern,
                        departingFrom: stop.station,
                        atOrAfter: instant,
                        within: horizon,
                        serviceDays: calendar.serviceDays(overlapping: window)
                    )
                    let plain = timetable.nextTrip(
                        of: pattern,
                        departingFrom: stop.station,
                        atOrAfter: instant,
                        within: horizon
                    )
                    XCTAssertEqual(fast?.id, plain?.id, "\(pattern.id) at \(stop.station), \(instant)")
                }
            }
        }
    }

    /// The trip returned must genuinely depart at or after the requested time,
    /// and inside the horizon — the two properties every countdown depends on.
    func testNextTripRespectsItsBounds() {
        let horizon: TimeInterval = 3600
        for pattern in network.patterns {
            for stop in pattern.sampledStops {
                for hour in [5, 8, 17, 1] {
                    let instant = date(8, 5, hour, 7)
                    guard let trip = timetable.nextTrip(
                        of: pattern,
                        departingFrom: stop.station,
                        atOrAfter: instant,
                        within: horizon
                    ) else { continue }
                    guard let departure = timetable.departure(of: trip, at: stop.station) else { continue }
                    XCTAssertGreaterThanOrEqual(departure, instant, "\(pattern.id) at \(stop.station)")
                    XCTAssertLessThanOrEqual(departure, instant.addingTimeInterval(horizon))
                }
            }
        }
    }

    /// It must find the *earliest* qualifying trip, not merely a qualifying one.
    func testNextTripIsTheEarliestNotJustAny() {
        let station = StationID("erie")
        let pattern = network.patterns.first {
            $0.kind == .local && $0.direction == .southbound && $0.stops.count == 22
        }!
        let instant = date(8, 5, 8, 15)
        let trip = timetable.nextTrip(of: pattern, departingFrom: station, atOrAfter: instant, within: 3600)!
        let departure = timetable.departure(of: trip, at: station)!

        let all = timetable.trips(
            of: pattern,
            departingFrom: station,
            in: DateInterval(start: instant, end: instant.addingTimeInterval(3600))
        )
        let earliest = all.compactMap { timetable.departure(of: $0, at: station) }.min()
        XCTAssertEqual(departure, earliest)
    }
}
