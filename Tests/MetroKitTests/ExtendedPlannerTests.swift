import Foundation
import XCTest
@testable import MetroKit

/// The all-of-SEPTA planner against the real bundled timetable.
///
/// Dates sit inside the generated feed's window; when the resource is regenerated
/// for a later feed, `serviceDay` is moved to a date the new feed covers.
final class ExtendedPlannerTests: XCTestCase {
    static let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SEPTACommute/Resources/SEPTAExtended.txt")

    static let network: ExtendedNetwork = {
        let text = try! String(contentsOf: resourceURL, encoding: .utf8)
        return try! ExtendedNetwork.decode(text)
    }()

    static let newYork = TimeZone(identifier: "America/New_York")!

    /// A weekday inside the window both feeds are authoritative for.
    func at(_ hour: Int, _ minute: Int, on yyyymmdd: String? = nil) -> Date {
        let day = yyyymmdd ?? Self.serviceDay
        var c = DateComponents()
        c.year = Int(day.prefix(4))
        c.month = Int(day.dropFirst(4).prefix(2))
        c.day = Int(day.suffix(2))
        c.hour = hour
        c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        return cal.date(from: c)!
    }

    /// The Tuesday after the feed's first day, so it is inside the authoritative window.
    static var serviceDay: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = newYork
        f.dateFormat = "yyyyMMdd"
        var day = f.date(from: network.validFrom)!.addingTimeInterval(7 * 86_400)
        while cal.component(.weekday, from: day) != 3 { day = day.addingTimeInterval(86_400) }
        return f.string(from: day)
    }

    var planner: ExtendedPlanner { ExtendedPlanner(network: Self.network, boardingMarginSeconds: 30) }

    // MARK: -

    func testDecodesWholeNetwork() {
        let net = Self.network
        XCTAssertGreaterThan(net.stopCount, 10_000)
        XCTAssertGreaterThan(net.patternCount, 1_000)
        XCTAssertGreaterThan(net.routes.count, 150)
        XCTAssertGreaterThan(net.weeklyTripCount, 50_000)
        XCTAssertGreaterThan(net.footpathCount, net.stopCount)
        for mode in ExtendedMode.allCases {
            XCTAssertTrue(net.routes.contains { $0.mode == mode }, "no \(mode) routes")
        }
        XCTAssertTrue(net.routes.contains { $0.shortName == "CHE" && $0.mode == .rail })
        XCTAssertTrue(net.routes.contains { $0.shortName == "47" && $0.mode == .bus })
        XCTAssertEqual(net.busFare, 2.90, accuracy: 0.001)
        XCTAssertEqual(net.validFrom.count, 8)
    }

    func testRejectsOtherText() {
        XCTAssertThrowsError(try ExtendedNetwork.decode("hello\n"))
    }

    func testRailFaresByZone() throws {
        let net = Self.network
        let jefferson = try XCTUnwrap(net.stopNames.firstIndex(of: "Jefferson Station"))
        let che = try XCTUnwrap(net.stopNames.firstIndex(of: "Chestnut Hill East"))
        XCTAssertTrue(net.isCenterCityRailStop(jefferson))
        XCTAssertFalse(net.isCenterCityRailStop(che))
        let weekday = try XCTUnwrap(net.railFare(fromStop: jefferson, toStop: che, weekend: false))
        let weekend = try XCTUnwrap(net.railFare(fromStop: jefferson, toStop: che, weekend: true))
        XCTAssertGreaterThanOrEqual(weekday, 5)
        XCTAssertLessThanOrEqual(weekday, 12)
        XCTAssertLessThanOrEqual(weekend, weekday)
        XCTAssertNil(net.railFare(fromStop: 0, toStop: che, weekend: false), "stop 0 is a Metro stop")
    }

    func testNearestStopsAreNearestFirst() {
        let city = Coordinate(latitude: 39.9524, longitude: -75.1636)
        let near = Self.network.nearestStops(to: city, within: 300)
        XCTAssertFalse(near.isEmpty)
        XCTAssertEqual(near.map(\.meters), near.map(\.meters).sorted())
        for n in near {
            XCTAssertEqual(Self.network.stopCoordinates[n.stop].distance(to: city), n.meters, accuracy: 15)
        }
    }

    /// Bustleton Ave, Northeast Philadelphia: no rail anywhere along it.
    func testBusCorridorTripRidesABus() throws {
        let from = Coordinate(latitude: 40.0518, longitude: -75.0613)   // Bustleton & Cottman
        let to = Coordinate(latitude: 40.0835, longitude: -75.0337)     // Bustleton & Grant
        let start = at(8, 0)
        let options = planner.plan(from: from, to: to, departAt: start)
        XCTAssertFalse(options.isEmpty)
        let bus = try XCTUnwrap(options.first { $0.rides.contains { $0.mode == .bus } })
        XCTAssertTrue(bus.usesBusOrRail)
        XCTAssertEqual(bus.fare, 2.90, accuracy: 0.001)
        XCTAssertLessThan(bus.arrival.timeIntervalSince(start), 75 * 60)
        assertFeasible(options, departAt: start, from: from, to: to)
    }

    /// Jefferson Station to Chestnut Hill East on a weekday morning: the CHE line.
    func testRegionalRailTripRidesTheTrainAndPaysAZoneFare() throws {
        let from = Coordinate(latitude: 39.9527, longitude: -75.1575)   // near Jefferson Station
        let to = Coordinate(latitude: 40.0805, longitude: -75.2068)     // near Chestnut Hill East
        let start = at(8, 0)
        let options = planner.plan(from: from, to: to, departAt: start)
        let rail = try XCTUnwrap(options.first { $0.rides.contains { $0.mode == .rail } },
                                 "options: \(options.map(describe))")
        XCTAssertTrue(rail.usesBusOrRail)
        let ride = try XCTUnwrap(rail.rides.first { $0.mode == .rail })
        XCTAssertEqual(ride.routeShortName, "CHE")
        XCTAssertGreaterThanOrEqual(ride.path.count, 5)
        XCTAssertEqual(ride.path.first, ride.boardCoordinate)
        XCTAssertEqual(ride.path.last, ride.alightCoordinate)
        XCTAssertGreaterThanOrEqual(rail.fare, 5)
        XCTAssertLessThanOrEqual(rail.fare, 15)
        XCTAssertLessThan(rail.arrival.timeIntervalSince(start), 80 * 60)
        assertFeasible(options, departAt: start, from: from, to: to)
    }

    /// Late at night the previous service day's after-midnight trips still count.
    func testAfterMidnightUsesOwlService() {
        let from = Coordinate(latitude: 39.9526, longitude: -75.1652)   // City Hall
        let to = Coordinate(latitude: 40.0090, longitude: -75.1505)     // Broad & Erie
        let start = at(2, 10)
        let options = planner.plan(from: from, to: to, departAt: start)
        XCTAssertFalse(options.filter { !$0.rides.isEmpty }.isEmpty, "no night service found")
        assertFeasible(options, departAt: start, from: from, to: to)
    }

    func testFeasibilityAcrossManyQueries() {
        let places = [
            Coordinate(latitude: 39.9526, longitude: -75.1652),  // City Hall
            Coordinate(latitude: 39.9566, longitude: -75.1820),  // 30th St
            Coordinate(latitude: 40.0390, longitude: -75.1450),  // Olney
            Coordinate(latitude: 39.9620, longitude: -75.2580),  // 69th St area
            Coordinate(latitude: 39.9180, longitude: -75.1700),  // South Philly
            Coordinate(latitude: 40.0230, longitude: -75.0780),  // Frankford
            Coordinate(latitude: 39.8770, longitude: -75.2420),  // Airport
            Coordinate(latitude: 40.1000, longitude: -75.3300),  // Norristown-ish
        ]
        for (i, a) in places.enumerated() {
            for b in places where a != b {
                let start = at(7 + i, 15)
                let options = planner.plan(from: a, to: b, departAt: start)
                XCTAssertFalse(options.isEmpty, "\(a) → \(b)")
                assertFeasible(options, departAt: start, from: a, to: b)
            }
        }
    }


    // MARK: - Service days, holidays, staleness

    func plannerKeepingStaleModes() -> ExtendedPlanner {
        var p = planner
        p.skipExpiredModes = false
        return p
    }

    /// Wall-clock HH:mm of a date, New York time.
    func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Self.newYork
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Every time a route's trips can be boarded at the stop at `coordinate`, as
    /// dates on the service day of `day` — the trips of that date's timetable key,
    /// placed with the GTFS noon − 12 h rule.
    func boardingTimes(route shortName: String, at coordinate: Coordinate, on day: Date) -> Set<Date> {
        let net = Self.network
        let frame = ServiceFrame(departAt: day, timeZone: Self.newYork)
        let start = frame.start
        var out = Set<Date>()
        for p in 0..<net.patternCount where net.routes[Int(net.patternRoute[p])].shortName == shortName {
            let key = net.timetableKey(rail: net.patternIsRail[p], dayNumber: frame.dayNumbers.1,
                                       dayType: frame.today.dayType, project: true)
            let count = Int(net.patternStart[p + 1] - net.patternStart[p])
            for pos in 0..<count where net.stopCoordinates[net.stop(p, pos)] == coordinate {
                for t in net.tripRange(pattern: p, key: key) {
                    out.insert(start.addingTimeInterval(TimeInterval(net.tripStarts[t] + net.boardOffset(p, pos))))
                }
            }
        }
        return out
    }

    func assertRidesRunAtScheduledTimes(_ options: [ExtendedItinerary], on day: Date,
                                        file: StaticString = #filePath, line: UInt = #line) -> Int {
        var checked = 0
        for ride in options.flatMap(\.rides) {
            let times = boardingTimes(route: ride.routeShortName, at: ride.boardCoordinate, on: day)
            XCTAssertTrue(times.contains(ride.departure),
                          "\(ride.routeShortName) at \(ride.boardName) \(clock(ride.departure)) is not a scheduled time; nearest: \(times.sorted().filter { abs($0.timeIntervalSince(ride.departure)) < 5400 }.map(clock))",
                          file: file, line: line)
            checked += 1
        }
        return checked
    }

    /// Route 58 on the Sunday the clocks spring forward: the search clock counts
    /// from noon − 12 h, so a 09:07 trip is boarded at 09:07, not 10:07.
    func testSpringForwardKeepsTripsAtTheirScheduledTimes() throws {
        try assertRoute58(on: "20270314")
    }

    /// … and on the Sunday they fall back.
    func testFallBackKeepsTripsAtTheirScheduledTimes() throws {
        try assertRoute58(on: "20261101")
    }

    func assertRoute58(on yyyymmdd: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let start = at(10, 0, on: yyyymmdd)
        let frame = ServiceFrame(departAt: start, timeZone: Self.newYork)
        XCTAssertEqual(frame.today.dayType, .sunday, file: file, line: line)
        // 10:00 is ten hours after the service day's nominal midnight.
        XCTAssertEqual(start.timeIntervalSince(frame.start), 10 * 3600, file: file, line: line)
        // Bustleton Ave between Cottman and Grant: route 58 runs along it.
        let from = Coordinate(latitude: 40.0518, longitude: -75.0613)
        let to = Coordinate(latitude: 40.0835, longitude: -75.0337)
        let p = plannerKeepingStaleModes()
        let options = p.plan(from: from, to: to, departAt: start)
        XCTAssertTrue(options.contains { !$0.rides.isEmpty }, file: file, line: line)
        XCTAssertGreaterThan(assertRidesRunAtScheduledTimes(options, on: start, file: file, line: line), 0,
                             file: file, line: line)
        assertFeasible(options, departAt: start, from: from, to: to, file: file, line: line)
    }

    func testServiceFrameAcrossClockChanges() {
        // Service days start at noon − 12 h, so the clock change (2 AM) falls between
        // Saturday's noon and Sunday's: Sunday's day starts 23 h after Saturday's in
        // the spring and 25 h after in the fall; Monday's starts 24 h after Sunday's.
        let spring = ServiceFrame(departAt: at(10, 0, on: "20270314"), timeZone: Self.newYork)
        XCTAssertEqual(spring.shift(to: spring.yesterday), -82_800)
        XCTAssertEqual(spring.shift(to: spring.tomorrow), 86_400)
        XCTAssertEqual(clock(spring.date(9 * 3600 + 7 * 60)), "09:07")
        let fall = ServiceFrame(departAt: at(10, 0, on: "20261101"), timeZone: Self.newYork)
        XCTAssertEqual(fall.shift(to: fall.yesterday), -90_000)
        XCTAssertEqual(fall.shift(to: fall.tomorrow), 86_400)
        XCTAssertEqual(clock(fall.date(9 * 3600 + 7 * 60)), "09:07")
        // Saturday night: Sunday's day starts 23 / 25 h later.
        XCTAssertEqual(ServiceFrame(departAt: at(23, 0, on: "20270313"), timeZone: Self.newYork).shift(to: spring.today), 82_800)
        XCTAssertEqual(ServiceFrame(departAt: at(23, 0, on: "20261031"), timeZone: Self.newYork).shift(to: fall.today), 90_000)
    }

    /// Thanksgiving runs the Sunday timetable, and the weekend Regional Rail fare.
    func testThanksgivingRunsSundayService() throws {
        let thanksgiving = at(10, 0, on: "20261126")
        let frame = ServiceFrame(departAt: thanksgiving, timeZone: Self.newYork)
        XCTAssertEqual(frame.today.dayType, .sunday)
        XCTAssertEqual(frame.yesterday.dayType, .wednesday)
        XCTAssertEqual(frame.tomorrow.dayType, .friday)
        XCTAssertTrue(frame.isWeekendFare(at: 10 * 3600))

        let from = Coordinate(latitude: 40.0518, longitude: -75.0613)
        let to = Coordinate(latitude: 40.0835, longitude: -75.0337)
        let holiday = planner.plan(from: from, to: to, departAt: thanksgiving)
        XCTAssertGreaterThan(assertRidesRunAtScheduledTimes(holiday, on: thanksgiving), 0)
        // Same as the Sunday before, minute for minute.
        let sunday = planner.plan(from: from, to: to, departAt: at(10, 0, on: "20261122"))
        XCTAssertEqual(holiday.map { $0.rides.map { "\($0.routeShortName) \(clock($0.departure))" } },
                       sunday.map { $0.rides.map { "\($0.routeShortName) \(clock($0.departure))" } })
        let thursday = planner.plan(from: from, to: to, departAt: at(10, 0, on: "20261119"))
        XCTAssertNotEqual(holiday.map { $0.rides.map { clock($0.departure) } },
                          thursday.map { $0.rides.map { clock($0.departure) } },
                          "Thursday and Sunday timetables should differ on route 58")

        // Rail on the holiday pays the weekend fare (the rail feed has lapsed by
        // then, so keep stale modes for this check).
        let rail = plannerKeepingStaleModes().plan(from: Coordinate(latitude: 39.9527, longitude: -75.1575),
                                                   to: Coordinate(latitude: 40.0805, longitude: -75.2068),
                                                   departAt: thanksgiving)
        let option = try XCTUnwrap(rail.first { $0.rides.count == 1 && $0.rides[0].mode == .rail })
        let ride = option.rides[0]
        let net = Self.network
        let board = try XCTUnwrap((0..<net.stopCount).first { net.stopCoordinates[$0] == ride.boardCoordinate && net.railFare(fromStop: $0, toStop: $0, weekend: true) != nil })
        let alight = try XCTUnwrap((0..<net.stopCount).first { net.stopCoordinates[$0] == ride.alightCoordinate && net.railFare(fromStop: $0, toStop: $0, weekend: true) != nil })
        XCTAssertEqual(option.fare, try XCTUnwrap(net.railFare(fromStop: board, toStop: alight, weekend: true)), accuracy: 0.001)
    }

    func testExpiredModesAreSkipped() throws {
        let net = Self.network
        XCTAssertEqual(net.busValidUntil.count, 8)
        XCTAssertEqual(net.railValidUntil.count, 8)
        XCTAssertGreaterThanOrEqual(max(net.busValidUntil, net.railValidUntil), net.validUntil)
        XCTAssertEqual(net.expiredModes(onServiceDate: net.validUntil), [])
        XCTAssertEqual(net.expiredModes(onServiceDate: "29991231"), Set(ExtendedMode.allCases))

        // A weekday after the rail feed ends but while the bus feed still runs.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = Self.newYork
        f.dateFormat = "yyyyMMdd"
        let (early, late) = net.railValidUntil < net.busValidUntil
            ? (net.railValidUntil, net.busValidUntil) : (net.busValidUntil, net.railValidUntil)
        var day = f.date(from: early)!.addingTimeInterval(86_400 + 12 * 3600)
        while cal.component(.weekday, from: day) != 3 { day = day.addingTimeInterval(86_400) }
        let yyyymmdd = f.string(from: day)
        // When both feeds end together (they do on v202611010: SEPTA's rail calendar
        // runs to the bus feed's end even though its feed_info stops in November),
        // the first Tuesday after the end has every mode expired.
        let expired: Set<ExtendedMode> = yyyymmdd > late ? Set(ExtendedMode.allCases)
            : net.railValidUntil < net.busValidUntil ? [.rail] : [.bus, .trolley, .metro]
        XCTAssertEqual(net.expiredModes(onServiceDate: yyyymmdd), expired)

        let from = Coordinate(latitude: 39.9527, longitude: -75.1575)   // near Jefferson Station
        let to = Coordinate(latitude: 40.0805, longitude: -75.2068)     // near Chestnut Hill East
        let start = at(8, 0, on: yyyymmdd)
        let skipping = planner.plan(from: from, to: to, departAt: start)
        XCTAssertFalse(skipping.flatMap(\.rides).contains { expired.contains($0.mode) }, skipping.map(describe).description)
        let keeping = plannerKeepingStaleModes().plan(from: from, to: to, departAt: start)
        XCTAssertTrue(keeping.flatMap(\.rides).contains { expired.contains($0.mode) }, keeping.map(describe).description)
    }

    // MARK: - Reconstruction

    /// Many random trips across the city: every leg starts where the previous one
    /// ended, every walk is as long as its distance needs, and the arrival is the
    /// sum of the legs (all checked by `assertFeasible`).
    func testRandomCityTripsHaveNoHiddenGaps() {
        var rng = SplitMix(seed: 0x5E97A)
        var footpathEgress = 0
        let p = planner
        for i in 0..<80 {
            let a = Coordinate(latitude: 39.90 + rng.unit() * 0.18, longitude: -75.26 + rng.unit() * 0.22)
            let b = Coordinate(latitude: 39.90 + rng.unit() * 0.18, longitude: -75.26 + rng.unit() * 0.22)
            let start = at(6 + i % 16, Int(rng.unit() * 59))
            let options = p.plan(from: a, to: b, departAt: start)
            assertFeasible(options, departAt: start, from: a, to: b)
            for o in options where o.legs.count >= 3 {
                if case .walk = o.legs[o.legs.count - 2] { footpathEgress += 1 }
            }
        }
        print("random trips: \(footpathEgress) itineraries end with a footpath before the final walk")
    }

    // MARK: - Early boarding

    func testBoardingIsNeverLaterThanTheMedianTime() {
        let net = Self.network
        XCTAssertEqual(net.patternBoardOffsets.count, net.patternOffsets.count)
        var earlier = 0
        for k in 0..<net.patternOffsets.count {
            XCTAssertLessThanOrEqual(net.patternBoardOffsets[k], net.patternOffsets[k])
            XCTAssertGreaterThanOrEqual(net.patternBoardOffsets[k], 0)
            if net.patternBoardOffsets[k] < net.patternOffsets[k] { earlier += 1 }
        }
        XCTAssertGreaterThan(earlier, 1000, "the generator should record fast trips")
    }

    // MARK: - Decoder robustness

    static let tiny = """
    SEPTAEXT\t1
    M\tb\tr\t20260101\t20260201\t20260301\t20260201
    R\t1\tOne\tbus\t
    S\tA\t39.95000\t-75.16000
    S\tB\t39.96000\t-75.16000
    P\t0\tB\tNorth\t0,1\t0,300\t\t\t\t1:120
    T\t12345\t3600,600
    """

    func testDecodesTinyNetworkWithEarlyBoarding() throws {
        let net = try ExtendedNetwork.decode(Self.tiny)
        XCTAssertEqual(net.stopCount, 2)
        XCTAssertEqual(net.patternOffsets, [0, 300])
        XCTAssertEqual(net.patternBoardOffsets, [0, 180])
        XCTAssertEqual(net.busValidUntil, "20260301")
        XCTAssertEqual(net.railValidUntil, "20260201")
        // An older M line without the per-feed dates falls back to valid_until.
        let old = try ExtendedNetwork.decode(Self.tiny.replacingOccurrences(of: "\t20260301\t20260201\n", with: "\n"))
        XCTAssertEqual(old.busValidUntil, "20260201")
        XCTAssertEqual(old.railValidUntil, "20260201")
    }

    func testRejectsMalformedNumbersAndPlaces() {
        func rejects(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
            let text = Self.tiny.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(text, Self.tiny, "substitution did nothing", file: file, line: line)
            XCTAssertThrowsError(try ExtendedNetwork.decode(text), file: file, line: line) { error in
                guard case .malformed? = error as? ExtendedNetworkError else {
                    return XCTFail("\(error)", file: file, line: line)
                }
            }
        }
        rejects("S\tA\t39.95000\t-75.16000", "S\t?\t0\t0")                 // the grid would span an ocean
        rejects("S\tA\t39.95000\t-75.16000", "S\tA\t39.95\t-122.4")
        rejects("S\tA\t39.95000\t-75.16000", "S\tA\t39.95000\t-75.16000\t70000")  // fare class > Int16
        rejects("0,300\t", "0,99999999999999999999999\t")                     // would overflow Int
        rejects("0,300\t", "0,3000000000\t")                                  // > Int32
        rejects("0,300\t\t", "0,300\t1:999\t")                               // flag bits > UInt8
        rejects("T\t12345\t3600,600", "T\t12345\t3600,-600")                   // starts out of order
        rejects("1:120", "1:-5")
    }

    func testZeroWalkingSpeedDoesNotTrap() {
        var p = planner
        p.walking = WalkingModel(metersPerSecond: 0)
        XCTAssertTrue(p.plan(from: Coordinate(latitude: 39.9526, longitude: -75.1652),
                             to: Coordinate(latitude: 40.0090, longitude: -75.1505), departAt: at(8, 0)).isEmpty)
        XCTAssertEqual(ExtendedPlanner.seconds(.infinity), ExtendedPlanner.unreachable)
        XCTAssertEqual(ExtendedPlanner.seconds(.nan), 0)
    }

    // MARK: - Route geometry

    func testShapesDecodeAndMostPatternsHaveOne() {
        let net = Self.network
        XCTAssertGreaterThan(net.shapeCount, 500)
        let shaped = (0..<net.patternCount).filter { net.patternShape[$0] >= 0 }.count
        XCTAssertGreaterThan(Double(shaped) / Double(net.patternCount), 0.98)
    }

    /// A ride's path follows the street: it starts and ends exactly at the stops,
    /// every stop ridden through lies on it, and on a winding route it is clearly
    /// longer than the straight line between the ends.
    func testRidePathFollowsTheRouteShape() throws {
        let net = Self.network
        // Route 61 winds along Ridge Avenue and Main Street, Manayunk.
        let route = try XCTUnwrap(net.routes.firstIndex { $0.shortName == "61" && $0.mode == .bus })
        let pattern = try XCTUnwrap((0..<net.patternCount)
            .filter { net.patternRoute[$0] == route && net.patternShape[$0] >= 0 }
            .max { net.patternStart[$0 + 1] - net.patternStart[$0] < net.patternStart[$1 + 1] - net.patternStart[$1] })
        let count = Int(net.patternStart[pattern + 1] - net.patternStart[pattern])
        let board = 2, alight = count - 3
        let path = net.ridePath(pattern: pattern, boardPos: board, alightPos: alight)
        let boardStop = net.stop(pattern, board), alightStop = net.stop(pattern, alight)
        XCTAssertEqual(path.first, net.stopCoordinates[boardStop])
        XCTAssertEqual(path.last, net.stopCoordinates[alightStop])
        let stops = (board...alight).map { net.stopCoordinates[net.stop(pattern, $0)] }
        XCTAssertGreaterThan(path.count, stops.count / 2)
        for stop in stops {
            XCTAssertLessThan(distance(from: stop, toPolyline: path), 60, "a stop is off the drawn path")
        }
        let straight = stops.first!.distance(to: stops.last!)
        XCTAssertGreaterThan(polylineLength(path), straight * 1.2)
        // Not a zig-zag either: within reach of the stop-to-stop polyline.
        XCTAssertLessThan(polylineLength(path), polylineLength(stops) * 1.25)
    }

    func testPlannedRidesCarryShapedPaths() throws {
        let from = Coordinate(latitude: 40.0518, longitude: -75.0613)   // Bustleton & Cottman
        let to = Coordinate(latitude: 40.0835, longitude: -75.0337)     // Bustleton & Grant
        let options = planner.plan(from: from, to: to, departAt: at(8, 0))
        let ride = try XCTUnwrap(options.flatMap(\.rides).first { $0.mode == .bus })
        XCTAssertEqual(ride.path.first, ride.boardCoordinate)
        XCTAssertEqual(ride.path.last, ride.alightCoordinate)
        XCTAssertEqual(ride.stopCoordinates.first, ride.boardCoordinate)
        XCTAssertEqual(ride.stopCoordinates.last, ride.alightCoordinate)
        XCTAssertEqual(ride.stopCount, ride.stopCoordinates.count - 1)
        XCTAssertGreaterThanOrEqual(ride.stopCount, 3)
        for stop in ride.stopCoordinates {
            XCTAssertLessThan(distance(from: stop, toPolyline: ride.path), 60)
        }
    }

    func testShapePathForBroadStreetLocal() throws {
        let metro = SEPTAData.network
        let pattern = try XCTUnwrap(metro.patterns.first {
            $0.routeID == "B1" && $0.direction == .northbound && $0.serves("city-hall") && $0.serves("erie")
        })
        let ids = pattern.stationIDs
        let from = try XCTUnwrap(ids.firstIndex(of: "city-hall")), to = try XCTUnwrap(ids.firstIndex(of: "erie"))
        let stations = try ids[from...to].map { try XCTUnwrap(metro.station($0)).coordinate }
        let path = try XCTUnwrap(Self.network.shapePath(routeShortName: "B1", through: stations))
        XCTAssertEqual(path.first, stations.first)
        XCTAssertEqual(path.last, stations.last)
        for station in stations {
            XCTAssertLessThan(distance(from: station, toPolyline: path), 150)
        }
        // Broad Street is straight: about as long as the stations' polyline, never much more.
        XCTAssertLessThan(polylineLength(path), polylineLength(stations) * 1.1)
        XCTAssertGreaterThan(polylineLength(path), polylineLength(stations) * 0.9)
        // Backwards along the same stations is the other direction's shape, still a match …
        XCTAssertNotNil(Self.network.shapePath(routeShortName: "B1", through: stations.reversed()))
        // … but the wrong route is not.
        XCTAssertNil(Self.network.shapePath(routeShortName: "L1", through: stations))
        XCTAssertNil(Self.network.shapePath(routeShortName: "NOPE", through: stations))
    }

    func testShapePathForMarketFrankford() throws {
        let metro = SEPTAData.network
        let pattern = try XCTUnwrap(metro.patterns.first {
            $0.routeID == "L1" && $0.serves("69th-st-transit-center") && $0.serves("8th-and-market")
                && $0.stationIDs.firstIndex(of: "69th-st-transit-center")! < $0.stationIDs.firstIndex(of: "8th-and-market")!
        })
        let ids = pattern.stationIDs
        let from = ids.firstIndex(of: "69th-st-transit-center")!, to = ids.firstIndex(of: "8th-and-market")!
        let stations = try ids[from...to].map { try XCTUnwrap(metro.station($0)).coordinate }
        let path = try XCTUnwrap(Self.network.shapePath(routeShortName: "L1", through: stations))
        XCTAssertEqual(path.first, stations.first)
        XCTAssertEqual(path.last, stations.last)
        // Market Street is mostly straight, so only check it is no coarser than the stations.
        XCTAssertGreaterThanOrEqual(path.count, stations.count)
        for station in stations {
            XCTAssertLessThan(distance(from: station, toPolyline: path), 150)
        }
        XCTAssertLessThan(polylineLength(path), polylineLength(stations) * 1.2)
    }

    /// Every Metro pattern the app can show — including the trolleys, trackless
    /// trolleys and the Owl bus — should find its geometry.
    func testShapePathCoversTheMetroPlannersPatterns() {
        let metro = SEPTAData.network
        var missing: [String] = []
        for pattern in metro.patterns {
            let stations = pattern.stationIDs.compactMap { metro.station($0)?.coordinate }
            let badge = pattern.kind == .nightBus ? "OWL" : pattern.routeID.rawValue
            if Self.network.shapePath(routeShortName: badge, through: stations) == nil {
                missing.append("\(badge) \(pattern.id)")
            }
        }
        print("shapePath: \(metro.patterns.count - missing.count) of \(metro.patterns.count) Metro patterns; missing \(missing)")
        XCTAssertLessThanOrEqual(missing.count, metro.patterns.count / 20, "no shape for: \(missing)")
    }

    func testTiming() {
        let text = try! String(contentsOf: Self.resourceURL, encoding: .utf8)
        var t = Date()
        _ = try! ExtendedNetwork.decode(text)
        let decode = Date().timeIntervalSince(t)

        let queries: [(Coordinate, Coordinate)] = [
            (Coordinate(latitude: 39.9527, longitude: -75.1575), Coordinate(latitude: 40.0805, longitude: -75.2068)),
            (Coordinate(latitude: 40.0518, longitude: -75.0613), Coordinate(latitude: 39.9526, longitude: -75.1652)),
            (Coordinate(latitude: 39.9180, longitude: -75.1700), Coordinate(latitude: 40.0390, longitude: -75.1450)),
            (Coordinate(latitude: 39.9620, longitude: -75.2580), Coordinate(latitude: 40.0230, longitude: -75.0780)),
        ]
        let p = planner
        _ = p.plan(from: queries[0].0, to: queries[0].1, departAt: at(8, 0))
        t = Date()
        var count = 0
        for q in queries {
            for hour in [8, 13, 18] {
                _ = p.plan(from: q.0, to: q.1, departAt: at(hour, 0))
                count += 1
            }
        }
        let perPlan = Date().timeIntervalSince(t) / Double(count)
        print(String(format: "ExtendedNetwork.decode: %.0f ms; plan: %.1f ms average over %d", decode * 1000, perPlan * 1000, count))
        #if DEBUG
        XCTAssertLessThan(decode, 5)
        XCTAssertLessThan(perPlan, 1.5)
        #else
        XCTAssertLessThan(decode, 1)
        XCTAssertLessThan(perPlan, 0.15)
        #endif
    }

    // MARK: - Helpers

    func polylineLength(_ points: [Coordinate]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// Metres from a point to the nearest segment of a polyline (local flat projection).
    func distance(from c: Coordinate, toPolyline line: [Coordinate]) -> Double {
        let (px, py) = ExtendedNetwork.project(c)
        var best = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let (ax, ay) = ExtendedNetwork.project(a), (bx, by) = ExtendedNetwork.project(b)
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0
            best = min(best, hypot(ax + t * dx - px, ay + t * dy - py))
        }
        if line.count == 1 { best = c.distance(to: line[0]) }
        return best
    }

    func describe(_ i: ExtendedItinerary) -> String {
        let f = DateFormatter()
        f.timeZone = Self.newYork
        f.dateFormat = "HH:mm"
        let rides = i.rides.map { "\($0.routeShortName) \($0.boardName) \(f.string(from: $0.departure)) → \($0.alightName) \(f.string(from: $0.arrival))" }
        return "leave \(f.string(from: i.leaveBy)) arrive \(f.string(from: i.arrival)) $\(i.fare): " + rides.joined(separator: " / ")
    }

    func assertFeasible(_ options: [ExtendedItinerary], departAt: Date, from: Coordinate, to: Coordinate,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(options.map(\.arrival), options.map(\.arrival).sorted(), file: file, line: line)
        XCTAssertEqual(Set(options.map(\.id)).count, options.count, "ids repeat", file: file, line: line)
        for option in options {
            let text = describe(option)
            XCTAssertGreaterThanOrEqual(option.leaveBy.timeIntervalSince(departAt), -1, text, file: file, line: line)
            guard case let .walk(first)? = option.legs.first, case let .walk(last)? = option.legs.last else {
                XCTFail("itinerary must start and end walking: \(text)", file: file, line: line)
                continue
            }
            XCTAssertEqual(first.from, from, file: file, line: line)
            XCTAssertEqual(last.to, to, file: file, line: line)
            // Walk the legs in order: nothing may depart before the rider can be there.
            var clock = option.leaveBy
            var rides = 0
            var here = from
            for (index, leg) in option.legs.enumerated() {
                switch leg {
                case let .walk(w):
                    XCTAssertGreaterThanOrEqual(w.seconds, 0, file: file, line: line)
                    // No hidden gaps: each leg starts where the last ended, and a walk
                    // takes at least as long as the walking model says for its length.
                    XCTAssertEqual(w.from, here, "walk starts away from the previous leg: \(text)", file: file, line: line)
                    let needed = planner.walking.walkSeconds(straightLineMeters: w.from.distance(to: w.to))
                    XCTAssertGreaterThanOrEqual(w.seconds, needed * 0.98 - 2,
                                                "walk \(w.fromName) → \(w.toName) too short: \(text)", file: file, line: line)
                    here = w.to
                    clock = clock.addingTimeInterval(w.seconds)
                    if index == 0, option.legs.count > 1 { clock = clock.addingTimeInterval(planner.boardingMarginSeconds) }
                case let .ride(r):
                    rides += 1
                    XCTAssertEqual(r.boardCoordinate, here, "ride boards away from the previous leg: \(text)", file: file, line: line)
                    here = r.alightCoordinate
                    XCTAssertLessThanOrEqual(clock.timeIntervalSince(r.departure), 1,
                                             "ride \(r.routeShortName) leaves before the rider arrives: \(text)",
                                             file: file, line: line)
                    XCTAssertLessThanOrEqual(r.departure, r.arrival, file: file, line: line)
                    clock = r.arrival
                }
            }
            XCTAssertLessThanOrEqual(abs(clock.timeIntervalSince(option.arrival)), 1, text, file: file, line: line)
            XCTAssertLessThanOrEqual(rides, 3, file: file, line: line)
        }
        // Pareto by rides: more rides only when strictly earlier.
        let sorted = options.sorted { $0.rides.count < $1.rides.count }
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] where b.rides.count > a.rides.count {
                XCTAssertLessThan(b.arrival, a.arrival, file: file, line: line)
            }
        }
    }
}

/// Deterministic random numbers for repeatable tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
