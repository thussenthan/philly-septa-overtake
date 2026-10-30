import XCTest
@testable import MetroKit

/// Things a review of the planner turned up, each pinned by a case that failed first.
final class PlannerRegressionTests: XCTestCase {

    // MARK: - Doors that stay shut

    /// The synthetic local line, with a stop where nobody may board (B) and one where
    /// nobody may alight (D) — the way SEPTA marks a few mid-route stops.
    private func plannerWithRestrictedStops() -> JourneyPlanner {
        let restricted = ServicePattern(
            id: "T-restricted-south",
            lineID: Fixture.lineID,
            routeID: "T1",
            kind: .local,
            direction: .southbound,
            compass: .south,
            headsign: "F",
            stops: Fixture.stations.enumerated().map { index, station in
                PatternStop(
                    station: station.id,
                    offset: TimeInterval(index * 120),
                    allowsBoarding: station.id != "b",
                    allowsAlighting: station.id != "d"
                )
            },
            schedule: Schedule(everyDay: [.frequency(from: Fixture.sam(8, 0), until: Fixture.sam(11, 0), every: 600)])
        )
        let network = Network(
            lines: Fixture.network.lines,
            stations: Fixture.stations,
            patterns: [restricted],
            provenance: Fixture.provenance
        )
        var options = PlannerOptions()
        options.walking.startupSeconds = 0
        options.walking.stationEntrySeconds = 0
        options.walking.stationExitSeconds = 0
        options.boardingBufferSeconds = 0
        return JourneyPlanner(network: network, calendar: Fixture.calendar, options: options)
    }

    func testThePlannerNeverBoardsWhereTheDoorsDoNotOpen() {
        let plan = plannerWithRestrictedStops().plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))
        for journey in plan.journeys {
            for ride in journey.rides {
                XCTAssertNotEqual(ride.boardStation, "b", "boarded at a stop that doesn't allow it: \(journey.trace)")
            }
        }
    }

    func testThePlannerNeverAlightsWhereTheDoorsDoNotOpen() {
        let plan = plannerWithRestrictedStops().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("d"),
            departAt: Fixture.date(7, 58)
        ))
        XCTAssertFalse(plan.journeys.isEmpty, "riding to a neighbouring stop and walking is still an option")
        for journey in plan.journeys {
            for ride in journey.rides {
                XCTAssertNotEqual(ride.alightStation, "d", "alighted at a stop that doesn't allow it: \(journey.trace)")
            }
        }
    }

    func testRestrictedStopsDoNotStopTheRestOfTheLineBeingUsed() {
        let plan = plannerWithRestrictedStops().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))
        XCTAssertTrue(plan.journeys.contains { $0.alightStation == "f" })
    }

    /// The same promise against the real feed, whose restricted stops are all mid-route.
    func testPlansOnTheRealFeedNeverUseARestrictedStop() throws {
        let network = SEPTAData.network
        let restricted = network.patterns.flatMap { pattern in
            pattern.stops.enumerated().compactMap { index, stop in
                (!stop.allowsBoarding || !stop.allowsAlighting) ? (pattern, index) : nil
            }
        }
        try XCTSkipIf(restricted.isEmpty, "this feed has no restricted stops")

        var options = PlannerOptions()
        options.maxResults = 6
        let planner = JourneyPlanner(network: network, options: options)

        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        components.hour = 8; components.minute = 30
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let morning = try XCTUnwrap(gregorian.date(from: components))

        for (pattern, index) in restricted.prefix(15) {
            let stop = pattern.stops[index]
            let trips: [(StationID, StationID)] = [
                (pattern.stops[0].station, stop.station),
                (stop.station, pattern.stops[pattern.stops.count - 1].station),
            ]
            for (from, to) in trips where from != to {
                let plan = planner.plan(PlanRequest(origin: .station(from), destination: .station(to), departAt: morning))
                for journey in plan.journeys {
                    for ride in journey.rides {
                        let ridden = try XCTUnwrap(network.pattern(ride.patternID))
                        XCTAssertTrue(
                            ridden.carries(from: ride.boardStation, to: ride.alightStation),
                            "\(from) → \(to) used \(ride.patternID) \(ride.boardStation)→\(ride.alightStation), "
                                + "which the doors don't allow"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Measured walks

    /// MapKit measures the walk and nothing else. The time to get out of the door and
    /// through the station gates is still owed, or every measured trip comes out a
    /// minute and a half optimistic.
    func testMeasuredWalksStillPayTheFixedOverheads() throws {
        var overrides = WalkTimeOverrides()
        overrides[.access("a")] = 300
        overrides[.egress("f")] = 120

        let planner = Fixture.planner {
            $0.walking.startupSeconds = 30
            $0.walking.stationEntrySeconds = 60
            $0.walking.stationExitSeconds = 45
        }
        let plan = planner.plan(PlanRequest(
            origin: .place(name: "Home", coordinate: Fixture.coordinate(of: "a", offsetMeters: 300)),
            destination: .place(name: "Work", coordinate: Fixture.coordinate(of: "f", offsetMeters: 300)),
            departAt: Fixture.date(7, 50),
            walkOverrides: overrides
        ))

        let journey = try XCTUnwrap(plan.journeys.first { $0.boardStation == "a" && $0.alightStation == "f" })
        let boarding = try XCTUnwrap(journey.rides.first).departure
        XCTAssertEqual(journey.urgency.leaveBy, boarding.addingTimeInterval(-(30 + 300 + 60)))
        XCTAssertEqual(try XCTUnwrap(journey.finalWalk).duration, 45 + 120)
    }

    // MARK: - Wording

    /// "In 3 min" with two and a half minutes left promises time the rider doesn't have.
    func testRelativeLeaveFloorsTheMinutes() {
        XCTAssertEqual(Format.relativeLeave(150), "in 2 min")
        XCTAssertEqual(Format.relativeLeave(179), "in 2 min")
        XCTAssertEqual(Format.relativeLeave(180), "in 3 min")
        XCTAssertEqual(Format.relativeLeave(100), "in 1 min")
        XCTAssertEqual(Format.relativeLeave(600), "in 10 min")
    }

    // MARK: - Alerts

    func testOneMalformedAlertEntryDoesNotCostTheRest() throws {
        let digest = try AlertsFeed.decode(Data("[1, null, \"x\"]".utf8), fetchedAt: Date())
        XCTAssertTrue(digest.alerts.isEmpty)
    }

    func testAFeedThatIsNotAnArrayIsStillRejected() {
        XCTAssertThrowsError(try AlertsFeed.decode(Data("{}".utf8), fetchedAt: Date()))
    }
}
