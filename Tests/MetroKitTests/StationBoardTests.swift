import XCTest
@testable import MetroKit

final class StationBoardTests: XCTestCase {

    /// Both routes call at C, and the board shows both, soonest first.
    func testTheBoardShowsEveryRouteThatCallsHere() {
        let rows = Fixture.planner().stationBoard(at: "c", after: Fixture.date(8, 0))
        XCTAssertEqual(Set(rows.map(\.routeID)), ["T1", "T2"])
        XCTAssertEqual(rows.map(\.departure), rows.map(\.departure).sorted())
        XCTAssertTrue(rows.allSatisfy { $0.departure >= Fixture.date(8, 0) })
    }

    /// F is where the southbound trains end: they aren't departures from it, and only
    /// the northbound local starts there.
    func testTrainsThatEndHereAreNotDepartures() {
        let rows = Fixture.planner().stationBoard(at: "f", after: Fixture.date(8, 0))
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.routeID)), ["T1"])
        XCTAssertTrue(rows.allSatisfy { $0.compass == .north })
    }

    func testTheHorizonBoundsTheBoard() {
        let rows = Fixture.planner().stationBoard(at: "a", after: Fixture.date(8, 0), horizon: 15 * 60)
        XCTAssertTrue(rows.allSatisfy { $0.departure <= Fixture.date(8, 15) })
    }

    func testTheLimitIsRespected() {
        XCTAssertLessThanOrEqual(Fixture.planner().stationBoard(at: "c", after: Fixture.date(8, 0), limit: 3).count, 3)
    }

    /// The same promise against the real feed: nothing on a station's board is a train
    /// that ends there or won't open its doors there.
    func testEveryRealStationBoardIsMadeOfRealDepartures() throws {
        let network = SEPTAData.network
        let planner = JourneyPlanner(network: network)
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        components.hour = 8; components.minute = 30
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let morning = try XCTUnwrap(gregorian.date(from: components))

        var anyRows = false
        for station in network.stations.prefix(120) {
            for row in planner.stationBoard(at: station.id, after: morning) {
                anyRows = true
                let pattern = try XCTUnwrap(network.pattern(row.trip.patternID))
                let index = try XCTUnwrap(pattern.stopIndex(of: station.id))
                XCTAssertLessThan(index + 1, pattern.stops.count, "\(pattern.id) ends at \(station.id)")
                XCTAssertTrue(pattern.stops[index].allowsBoarding, "\(pattern.id) doesn't open its doors at \(station.id)")
            }
        }
        XCTAssertTrue(anyRows)
    }

    /// The G1 loops round Delaware Av and calls at Frankford & Richmond twice. Indexing
    /// both calls listed every G1 twice on that board, with the same identity.
    func testALoopingRouteIsListedOncePerTrain() throws {
        let network = SEPTAData.network
        let loopers = network.patterns.filter { pattern in
            Set(pattern.stationIDs).count < pattern.stationIDs.count
        }
        XCTAssertFalse(loopers.isEmpty, "the feed has loops; this test needs one")
        for pattern in loopers {
            for station in Set(pattern.stationIDs) {
                let serving = network.patterns(serving: station).filter { $0.id == pattern.id }
                XCTAssertEqual(serving.count, 1, "\(pattern.id) indexed twice at \(station)")
            }
        }
    }

    /// `direction_id` 0 is east on the L and west on the G1, so judging "same platform"
    /// by it put westbound trolleys on an eastbound L board as trains that skip the
    /// rider's stop — and cost the board its heading. The compass word decides now.
    func testABoardOnlyCarriesTrainsGoingTheRidersWay() throws {
        let network = SEPTAData.network
        let planner = JourneyPlanner(network: network)
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        components.hour = 8; components.minute = 30
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let morning = try XCTUnwrap(gregorian.date(from: components))

        let board = planner.departureBoard(from: "front-girard", to: ["berks"], after: morning)
        XCTAssertFalse(board.isEmpty)
        XCTAssertNotNil(
            BoardDeparture.direction(of: board),
            "one platform: \(board.map(\.routeBadge))"
        )
    }
}
