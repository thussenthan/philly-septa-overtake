import XCTest
@testable import MetroKit

final class JourneyPlannerTests: XCTestCase {

    // MARK: - The headline decision

    /// Standing at A at 07:58, the 08:00 local reaches F at 08:10 but the 08:04
    /// express reaches it at 08:08. Waiting is correct, and the plan should say so.
    func testWaitingForTheExpressWinsWhenItArrivesFirst() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))

        let best = try XCTUnwrap(plan.best)
        XCTAssertTrue(best.usesExpress, "expected the express to win, got \(best.trace)")
        XCTAssertEqual(best.arrivalTime, Fixture.date(8, 8))

        // The slower local must still be offered: it leaves sooner, which some
        // riders will prefer, and the whole point is to show the tradeoff.
        let local = plan.journeys.first { !$0.usesExpress && !$0.isWalkOnly }
        let localJourney = try XCTUnwrap(local, "the local option should still be listed")
        XCTAssertEqual(localJourney.arrivalTime, Fixture.date(8, 10))
    }

    /// The express skips E, so for a trip to E the earlier local is simply right.
    func testLocalWinsWhenTheExpressSkipsTheDestination() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("e"),
            departAt: Fixture.date(7, 58)
        ))

        let best = try XCTUnwrap(plan.best)
        XCTAssertEqual(best.arrivalTime, Fixture.date(8, 8))
        XCTAssertFalse(best.usesExpress, "got \(best.trace)")
    }

    /// From B — a local-only station — the fastest way to F is to ride the local
    /// one stop to C and let the express overtake you. Nothing in the planner
    /// knows about "overtaking"; it falls out of enumerating transfers.
    func testHalfLocalHalfExpressIsFoundWithoutBeingSpecialCased() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))

        let best = try XCTUnwrap(plan.best)
        XCTAssertEqual(best.rides.count, 2, "expected a two-train plan, got \(best.trace)")
        XCTAssertEqual(best.rides.first?.kind, .local)
        XCTAssertEqual(best.rides.last?.kind, .express)
        XCTAssertEqual(best.rides.first?.alightStation, "c")
        XCTAssertEqual(best.arrivalTime, Fixture.date(8, 8))

        let narrator = JourneyNarrator(network: Fixture.network)
        XCTAssertTrue(narrator.strategy(for: best).isOvertake)
        XCTAssertEqual(
            narrator.summary(for: best).title,
            "Local now, switch to the express at C"
        )
    }

    /// The wait at C is the rider deliberately letting a faster train catch up,
    /// which reads very differently from waiting for your first train.
    func testTheHoldAtTheTransferIsMarkedStrategic() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))
        let best = try XCTUnwrap(plan.best)
        let holds = best.legs.compactMap { leg -> WaitLeg? in
            if case .wait(let wait) = leg { return wait }
            return nil
        }
        XCTAssertEqual(holds.filter(\.isStrategicHold).count, 1)
        XCTAssertEqual(holds.first(where: \.isStrategicHold)?.stationID, "c")
    }

    // MARK: - Feasibility

    /// A plan the rider cannot physically reach in time must not be shown.
    func testUnreachableDeparturesAreExcluded() {
        // 700 m from A: about nine minutes of walking with the default model.
        let origin = Endpoint.place(name: "Origin", coordinate: Fixture.coordinate(of: "a", offsetMeters: 700))
        let planner = Fixture.planner { options in
            options.walking.startupSeconds = 30
            options.walking.stationEntrySeconds = 60
        }
        let plan = planner.plan(PlanRequest(
            origin: origin,
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))

        XCTAssertFalse(plan.journeys.isEmpty)
        for journey in plan.journeys where !journey.isWalkOnly {
            XCTAssertGreaterThanOrEqual(
                journey.urgency.slack, -30,
                "offered a train the rider cannot reach: \(journey.trace)"
            )
            // Boarding must come after the walk finishes.
            let walk = journey.walks.first { $0.purpose == .access }
            if let walk, let board = journey.rides.first {
                XCTAssertLessThanOrEqual(walk.endTime, board.departure)
            }
        }
    }

    /// `leaveBy` is the promise the countdown makes; it must equal the boarding
    /// time minus the walk, not the moment the search happened to run.
    func testLeaveByAccountsForTheWalk() throws {
        let walkSeconds: TimeInterval = 300
        var overrides = WalkTimeOverrides()
        overrides[.access("a")] = walkSeconds

        let planner = Fixture.planner()
        let plan = planner.plan(PlanRequest(
            origin: .place(name: "Home", coordinate: Fixture.coordinate(of: "a", offsetMeters: 300)),
            destination: .station("f"),
            departAt: Fixture.date(7, 50),
            walkOverrides: overrides
        ))

        let viaA = try XCTUnwrap(plan.journeys.first { $0.boardStation == "a" })
        let boarding = try XCTUnwrap(viaA.rides.first).departure
        XCTAssertEqual(viaA.urgency.leaveBy, boarding.addingTimeInterval(-walkSeconds))
        XCTAssertEqual(viaA.urgency.boardingDeparture, boarding)
    }

    /// Measured walking times must beat the geometric estimate, or plugging in
    /// real directions would be pointless.
    func testMeasuredWalkOverridesReplaceTheEstimate() throws {
        var overrides = WalkTimeOverrides()
        overrides[.egress("f")] = 45

        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .place(name: "Work", coordinate: Fixture.coordinate(of: "f", offsetMeters: 900)),
            departAt: Fixture.date(7, 58),
            walkOverrides: overrides
        ))

        let journey = try XCTUnwrap(plan.journeys.first { $0.alightStation == "f" })
        let egress = try XCTUnwrap(journey.finalWalk)
        XCTAssertEqual(egress.duration, 45)
        XCTAssertTrue(egress.isMeasured)
    }

    // MARK: - Alighting choices

    /// When the express skips the closest station to the destination, riding it
    /// past and walking back is a real option and must be offered.
    func testRidingPastASkippedStopAndWalkingBackIsOffered() throws {
        // 250 m south of E: E is closest, but F is walkable and express-served.
        let destination = Endpoint.place(
            name: "Near E",
            coordinate: Coordinate(latitude: Fixture.coordinate(of: "e").latitude - 0.0009, longitude: -75.16)
        )
        let plan = Fixture.planner { $0.maxEgressStations = 4 }.plan(PlanRequest(
            origin: .station("a"),
            destination: destination,
            departAt: Fixture.date(7, 58)
        ))

        let alightStations = Set(plan.journeys.compactMap(\.alightStation))
        XCTAssertTrue(alightStations.contains("e"), "the nearest station should be offered")
        XCTAssertTrue(
            alightStations.contains("f"),
            "riding the express past E to F should be offered; got \(alightStations)"
        )
    }

    /// Options that lose a lot of time are noise, not choice.
    func testHopelesslySlowOptionsAreDropped() {
        let plan = Fixture.planner { $0.arrivalTolerance = 5 * 60 }.plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))
        let best = plan.journeys.first!.arrivalTime
        for journey in plan.journeys {
            XCTAssertLessThanOrEqual(journey.arrivalTime.timeIntervalSince(best), 5 * 60)
        }
    }

    func testResultsAreCappedAndSortedByArrival() {
        let plan = Fixture.planner { $0.maxResults = 3 }.plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))
        XCTAssertLessThanOrEqual(plan.journeys.count, 3)
        XCTAssertEqual(plan.journeys, plan.journeys.sorted { $0.arrivalTime < $1.arrivalTime })
    }

    // MARK: - Service availability

    /// On a Saturday the fixture's express does not run, and the rider should be
    /// told that rather than left wondering.
    func testExpressAbsenceIsExplained() throws {
        // 2026-03-07 is a Saturday.
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7
        components.hour = 8
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let saturday = gregorian.date(from: components)!

        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: saturday
        ))

        XCTAssertFalse(plan.journeys.isEmpty)
        XCTAssertFalse(plan.journeys.contains(where: \.usesExpress))
        let mentionsExpress = plan.notes.contains { note in
            if case .expressNotRunningNow = note { return true }
            return false
        }
        XCTAssertTrue(mentionsExpress, "notes were \(plan.notes)")
    }

    /// After the last train there is nothing to offer, and the plan must say so
    /// instead of returning an empty list with no explanation.
    func testNoServiceIsReportedRatherThanSilentlyEmpty() {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(23, 30)
        ))
        XCTAssertTrue(plan.journeys.filter { !$0.isWalkOnly }.isEmpty)
        XCTAssertTrue(plan.notes.contains(.noServiceFound) || plan.journeys.contains(where: \.isWalkOnly))
    }

    /// A destination nowhere near the line should produce an explanation, not
    /// a confident wrong answer.
    func testOffNetworkDestinationIsFlagged() {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .place(name: "Far away", coordinate: Coordinate(latitude: 39.5, longitude: -75.0)),
            departAt: Fixture.date(8, 0)
        ))
        let flagged = plan.notes.contains { note in
            if case .destinationTooFarFromLine = note { return true }
            return false
        }
        XCTAssertTrue(flagged, "notes were \(plan.notes)")
    }

    // MARK: - Sanity properties

    /// Every journey's legs must form one unbroken chain in time, or the itinerary
    /// shown to the rider is internally inconsistent.
    func testLegsAreContiguousAndOrdered() {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .place(name: "Home", coordinate: Fixture.coordinate(of: "b", offsetMeters: 200)),
            destination: .place(name: "Work", coordinate: Fixture.coordinate(of: "f", offsetMeters: 200)),
            departAt: Fixture.date(7, 55)
        ))
        XCTAssertFalse(plan.journeys.isEmpty)

        for journey in plan.journeys {
            XCTAssertEqual(journey.legs.first?.startTime, journey.departureTime, journey.trace)
            XCTAssertEqual(journey.legs.last?.endTime, journey.arrivalTime, journey.trace)
            for (earlier, later) in zip(journey.legs, journey.legs.dropFirst()) {
                XCTAssertEqual(
                    earlier.endTime, later.startTime,
                    "gap or overlap between legs in \(journey.trace)"
                )
            }
            XCTAssertGreaterThan(journey.totalDuration, 0)
        }
    }

    /// A rider never boards a train going the wrong way and rides it further away
    /// than they started, unless it genuinely helps — assert the simple case.
    func testRidesAlwaysMakeProgressAlongTheirPattern() {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))
        for journey in plan.journeys {
            for ride in journey.rides {
                let pattern = Fixture.network.pattern(ride.patternID)!
                XCTAssertTrue(
                    pattern.carries(from: ride.boardStation, to: ride.alightStation),
                    "\(ride.patternID) does not run \(ride.boardStation)→\(ride.alightStation)"
                )
                XCTAssertGreaterThan(ride.arrival, ride.departure)
            }
        }
    }
}
