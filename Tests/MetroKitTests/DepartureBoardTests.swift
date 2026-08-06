import XCTest
@testable import MetroKit

/// The board is the platform sign, and it answers a different question from the
/// planner: not "which train should I take" but "what is coming, and what does
/// waiting cost me". The distinction is the whole reason it isn't just the plan
/// rendered differently.
final class DepartureBoardTests: XCTestCase {

    private func board(
        from origin: StationID = "a",
        to destinations: Set<StationID> = ["f"],
        at hour: Int,
        _ minute: Int,
        aimingAt: StationID? = nil,
        limit: Int = 8
    ) -> [BoardDeparture] {
        Fixture.planner().departureBoard(
            from: origin,
            to: destinations,
            after: Fixture.date(hour, minute),
            aimingAt: aimingAt,
            limit: limit
        )
    }

    // MARK: - What belongs on it

    /// The planner drops the 08:00 local from A to F, because the 08:04 express
    /// leaves later *and* arrives sooner, so nothing recommends it. The board keeps
    /// it: it's a train, it's leaving, and a rider watching it pull in gets to decide
    /// for themselves.
    func testTheBoardKeepsTrainsThePlannerCorrectlyHides() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"), destination: .station("f"), departAt: Fixture.date(7, 58)
        ))
        XCTAssertNil(
            plan.journeys.first { !$0.usesExpress && !$0.isWalkOnly },
            "precondition: the local is dominated and filtered out of the plan"
        )

        let board = self.board(at: 7, 58)
        XCTAssertTrue(board.contains { $0.kind == .local }, "the board shows it anyway")
        XCTAssertTrue(board.contains { $0.kind == .express })
    }

    func testItIsSortedByDeparture() {
        let departures = board(at: 8, 0).map(\.departure)
        XCTAssertEqual(departures, departures.sorted())
        XCTAssertGreaterThan(departures.count, 2)
    }

    func testNothingOnItHasAlreadyLeft() {
        let now = Fixture.date(8, 5)
        for entry in board(at: 8, 5) {
            XCTAssertGreaterThanOrEqual(entry.departure, now)
            if let arrival = entry.arrival {
                XCTAssertGreaterThan(arrival, entry.departure)
            }
        }
    }

    func testTheLimitIsRespected() {
        XCTAssertEqual(board(at: 8, 0, limit: 3).count, 3)
    }

    // MARK: - What doesn't belong on it

    /// A board for a destination this station's trains don't reach is empty, not
    /// wrong — there is no platform to point at.
    func testABoardWithNoUsefulTrainAtAllIsEmpty() {
        XCTAssertTrue(board(from: "a", to: ["a"], at: 8, 0).isEmpty, "you are already there")
    }

    /// Only the platform the rider wants. A train going the other way is not a worse
    /// option, it is a different station, and putting it on the board would be a lie
    /// about which side to stand on.
    func testTrainsGoingTheOtherWayAreNotOnTheBoard() {
        let southbound = board(at: 8, 0)
        XCTAssertFalse(southbound.isEmpty)
        XCTAssertTrue(
            southbound.allSatisfy { $0.compass == southbound.first?.compass },
            "one board, one direction: \(southbound.map { $0.compass?.label ?? "?" })"
        )
    }

    func testAnEmptyDestinationSetProducesNothing() {
        XCTAssertTrue(board(to: [], at: 8, 0).isEmpty)
    }

    func testNoServiceProducesAnEmptyBoardRatherThanStaleTimes() {
        XCTAssertTrue(board(at: 23, 30).isEmpty)
    }

    /// The express skips E, so a board towards E must not *offer* it — but it must
    /// still show it.
    ///
    /// Dropping it made the app disagree with the sign the rider is standing under:
    /// the express really is pulling in first. Showing it greyed says the thing the
    /// sign cannot, which is why that train is no good to them — and that is the
    /// mistake the whole app exists to prevent.
    func testATrainThatSkipsTheDestinationIsShownButNotOffered() {
        let towardsE = board(to: ["e"], at: 8, 0, aimingAt: "e")
        let express = towardsE.filter { $0.kind == .express }
        XCTAssertFalse(express.isEmpty, "the express is on the platform sign, so it is on this one")

        for entry in express {
            XCTAssertFalse(entry.isUseful, "it skips E")
            XCTAssertNil(entry.alightStation)
            XCTAssertNil(entry.arrival)
            XCTAssertEqual(entry.missedDestination, StationID("e"), "the row has to be able to say why")
        }
        XCTAssertTrue(
            towardsE.contains { $0.kind == .local && $0.isUseful },
            "and the train that does work is still there"
        )
    }

    /// Without being told which stop matters, a row can say it is no use but not
    /// which stop it misses — and naming the wrong one would be worse than silence.
    func testTheMissedStopIsOnlyNamedWhenTheCallerSaysWhichItIs() throws {
        let unnamed = board(to: ["e"], at: 8, 0)
        let express = try XCTUnwrap(unnamed.first { $0.kind == .express })
        XCTAssertFalse(express.isUseful)
        XCTAssertNil(express.missedDestination)
    }

    // MARK: - What each row says

    /// Each row names the station that train would put you off at, of the ones
    /// offered — the earliest it reaches, because that is the one a rider would use.
    func testEachRowNamesWhereItWouldPutYouOff() throws {
        let entry = try XCTUnwrap(board(to: ["c", "f"], at: 8, 0).first { $0.kind == .express })
        XCTAssertEqual(entry.alightStation, StationID("c"), "C comes before F on the express")
    }

    func testRowsUseTheSameWordsAsTheItinerary() throws {
        let entry = try XCTUnwrap(board(at: 8, 0).first { $0.kind == .express })
        XCTAssertEqual(entry.routeBadge, "T2")
        XCTAssertEqual(entry.platformHeadline, "Southbound · Express")

        let local = try XCTUnwrap(board(at: 8, 0).first { $0.kind == .local })
        XCTAssertEqual(local.platformHeadline, "Southbound", "a local doesn't announce being one")
    }

    /// The rows drop the direction, because the header carries it. Repeating
    /// "Southbound" down every line spends the widest column on the one word they
    /// all share.
    func testRowsLeaveTheDirectionToTheHeader() throws {
        let entries = board(at: 8, 0)
        for entry in entries {
            XCTAssertFalse(
                entry.serviceHeadline.contains("bound"),
                "\(entry.serviceHeadline) repeats what the header already said"
            )
        }
        XCTAssertEqual(entries.first { $0.kind == .express }?.serviceHeadline, "Express")

        let direction = BoardDeparture.direction(of: entries)
        XCTAssertEqual(direction?.label, "Southbound", "and the header can state it")
    }

    /// A board whose trains disagree about direction names none, rather than picking
    /// one and pointing the rider at the wrong platform.
    func testAMixedBoardClaimsNoDirection() {
        XCTAssertNil(BoardDeparture.direction(of: []))
    }

    /// The arrival is what makes a later train visibly better or worse, so it has to
    /// be the time at the station the row names.
    func testTheArrivalIsAtTheStationTheRowNames() throws {
        let entry = try XCTUnwrap(board(at: 8, 0).first)
        let alight = try XCTUnwrap(entry.alightStation)
        let timetable = Timetable(network: Fixture.network, calendar: Fixture.calendar)
        XCTAssertEqual(entry.arrival, timetable.arrival(of: entry.trip, at: alight))
    }

    /// The one on the board that the recommendation actually puts you on has to be
    /// identifiable, or the rider is matching times by eye.
    func testTheRecommendedTrainIsOnTheBoard() throws {
        let now = Fixture.date(8, 1)
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"), destination: .station("f"), departAt: now
        ))
        let best = try XCTUnwrap(plan.best)
        let boarded = try XCTUnwrap(best.rides.first)
        XCTAssertTrue(
            board(at: 8, 1).contains { $0.trip.id == boarded.trip.id },
            "the plan's own train is missing from the board"
        )
    }

    // MARK: - Doors

    /// A stop where SEPTA prohibits boarding can't be the top of a board.
    func testAStopWhereBoardingIsProhibitedOffersNothing() {
        let restricted = SEPTAData.network.patterns.lazy.compactMap { pattern in
            pattern.stops.first { !$0.allowsBoarding }.map { (pattern, $0) }
        }.first
        guard let (pattern, stop) = restricted else {
            return XCTFail("the bundled data should contain a no-boarding stop")
        }
        let last = pattern.stops.last!.station
        let entries = JourneyPlanner(network: SEPTAData.network).departureBoard(
            from: stop.station,
            to: [last],
            after: Date(timeIntervalSince1970: 1_785_000_000),
            limit: 8
        )
        XCTAssertFalse(
            entries.contains { $0.trip.patternID == pattern.id },
            "\(pattern.id) offers boarding where SEPTA prohibits it"
        )
    }
}
