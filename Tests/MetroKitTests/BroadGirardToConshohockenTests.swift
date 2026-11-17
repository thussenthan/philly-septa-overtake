import XCTest
@testable import MetroKit

/// A real trip a rider asked about: Broad & Girard to Conshohocken, which no Metro
/// line reaches, so only the all-of-SEPTA planner can answer it. It pins the three
/// things that matter about the answer: the cheapest way is buses, the fastest is
/// the Metro plus Regional Rail, and the rail fare depends on where you board.
final class BroadGirardToConshohockenTests: XCTestCase {
    static let origin = Coordinate(latitude: 39.971485504343015, longitude: -75.15946492144217)
    static let destination = Coordinate(latitude: 40.07137733338268, longitude: -75.29961345861341)

    private var network: ExtendedNetwork { ExtendedPlannerTests.network }

    private func stop(_ name: String) throws -> Int {
        try XCTUnwrap(network.stopNames.firstIndex(of: name), name)
    }

    /// Every mode searched on its own footing, as the app does, so a slower but
    /// cheaper bus trip is not hidden behind the faster train.
    private func options(at hour: Int, _ minute: Int) -> [ExtendedItinerary] {
        let day = ExtendedPlannerTests.serviceDay
        var c = DateComponents()
        c.year = Int(day.prefix(4)); c.month = Int(day.dropFirst(4).prefix(2)); c.day = Int(day.suffix(2))
        c.hour = hour; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ExtendedPlannerTests.newYork
        let departAt = cal.date(from: c)!

        var planner = ExtendedPlanner(network: network, boardingMarginSeconds: 30)
        var seen = Set<String>()
        var found: [ExtendedItinerary] = []
        for excluded in [[], [.rail], [.metro, .trolley], [.bus], [.rail, .metro, .trolley]] as [Set<ExtendedMode>] {
            planner.excludedModes = excluded
            for it in planner.plan(from: Self.origin, to: Self.destination, departAt: departAt) where !it.rides.isEmpty {
                if seen.insert(it.id).inserted { found.append(it) }
            }
        }
        return found
    }

    func testRailFareDependsOnWhereYouBoard() throws {
        let conshohocken = try stop("Conshohocken")
        let northBroad = try stop("North Broad")   // Zone 1
        let temple = try stop("Temple University") // Center City
        XCTAssertFalse(network.isCenterCityRailStop(northBroad))
        XCTAssertTrue(network.isCenterCityRailStop(temple))
        XCTAssertEqual(try XCTUnwrap(network.railFare(fromStop: northBroad, toStop: conshohocken, weekend: false)), 5.00, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(network.railFare(fromStop: temple, toStop: conshohocken, weekend: false)), 7.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(network.railFare(fromStop: temple, toStop: conshohocken, weekend: true)), 7.00, accuracy: 0.001)
        // Different lines are priced as two legs through Center City, joined as one
        // extended trip, so Wayne Junction costs more than Center City does.
        let wayne = try stop("Wayne Junction")
        XCTAssertEqual(try XCTUnwrap(network.railFare(fromStop: wayne, toStop: conshohocken, weekend: false)), 8.75, accuracy: 0.001)
    }

    func testCheapestIsBusesAndFastestIsMetroPlusTrain() throws {
        let all = options(at: 16, 37).filter(\.fareIsKnown)
        let cheapest = try XCTUnwrap(all.min { ($0.fare, $0.arrival) < ($1.fare, $1.arrival) })
        let fastest = try XCTUnwrap(all.min { $0.arrival < $1.arrival })

        XCTAssertEqual(cheapest.fare, 2.90, accuracy: 0.001)
        XCTAssertTrue(cheapest.rides.allSatisfy { $0.mode != .rail }, "the cheapest way has no train")
        XCTAssertTrue(cheapest.rides.contains { $0.routeShortName == "97" }, "bus 97 is what reaches Conshohocken")

        XCTAssertTrue(fastest.rides.contains { $0.mode == .rail && $0.routeShortName == "NOR" })
        XCTAssertLessThan(fastest.arrival, cheapest.arrival.addingTimeInterval(-20 * 60), "the train saves real time")
        XCTAssertGreaterThan(fastest.fare, cheapest.fare)
    }

    func testBoardingTheTrainAtNorthBroadBeatsTempleOnPrice() throws {
        let all = options(at: 16, 37).filter(\.fareIsKnown)
        let viaNorthBroad = all.filter { $0.rides.first?.mode == .metro && $0.rides.contains { $0.mode == .rail } }
        let best = try XCTUnwrap(viaNorthBroad.min { ($0.fare, $0.arrival) < ($1.fare, $1.arrival) })
        // Metro fare + Zone 1 to Zone 3.
        XCTAssertEqual(best.fare, 2.90 + 5.00, accuracy: 0.001)
        // Boarding the same train at Temple pays the Center City rate and arrives
        // no sooner, so it is never the better buy.
        for atTemple in all where atTemple.rides.first(where: { $0.mode == .rail })?.boardName == "Temple University" {
            XCTAssertGreaterThan(atTemple.fare, best.fare)
            XCTAssertGreaterThanOrEqual(atTemple.arrival, best.arrival)
        }
    }
}
