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
            for (index, leg) in option.legs.enumerated() {
                switch leg {
                case let .walk(w):
                    XCTAssertGreaterThanOrEqual(w.seconds, 0, file: file, line: line)
                    clock = clock.addingTimeInterval(w.seconds)
                    if index == 0, option.legs.count > 1 { clock = clock.addingTimeInterval(planner.boardingMarginSeconds) }
                case let .ride(r):
                    rides += 1
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
