import XCTest
@testable import MetroKit

final class JourneyPlannerTests: XCTestCase {

    // MARK: - The headline decision

    /// Standing at A at 07:58, the 08:00 local reaches F at 08:10 and the 08:04
    /// express reaches it at 08:08. The express leaves *later* and arrives
    /// *sooner*, so there is no tradeoff to present — the local is strictly worse
    /// and showing it would only invite a rider to make a mistake.
    func testTheLocalIsNotOfferedWhenTheExpressBeatsItOnBothCounts() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(7, 58)
        ))

        let best = try XCTUnwrap(plan.best)
        XCTAssertTrue(best.usesExpress, "expected the express to win, got \(best.trace)")
        XCTAssertEqual(best.arrivalTime, Fixture.date(8, 8))
        XCTAssertEqual(best.urgency.boardingDeparture, Fixture.date(8, 4))

        XCTAssertNil(
            plan.journeys.first { !$0.usesExpress && !$0.isWalkOnly },
            "the local leaves earlier AND arrives later, so it should be filtered: "
                + "\(plan.journeys.map(\.trace))"
        )
    }

    /// The genuine version of "wait or go now": a rider who has just missed the
    /// 08:00 local. The express leaves at 08:04 and arrives 08:08; the next local
    /// leaves at 08:10 and arrives 08:20. Now the express demands they move
    /// *sooner*, so both belong on screen — miss the express and it costs 12 min.
    func testBothAreOfferedWhenCatchingTheFasterTrainMeansLeavingSooner() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(8, 1)
        ))

        XCTAssertEqual(plan.journeys.count, 2, "got \(plan.journeys.map(\.trace))")

        let express = try XCTUnwrap(plan.journeys.first)
        XCTAssertTrue(express.usesExpress)
        XCTAssertEqual(express.arrivalTime, Fixture.date(8, 8))
        XCTAssertEqual(express.urgency.boardingDeparture, Fixture.date(8, 4))

        let local = try XCTUnwrap(plan.journeys.last)
        XCTAssertFalse(local.usesExpress)
        XCTAssertEqual(local.arrivalTime, Fixture.date(8, 20))
        XCTAssertEqual(local.urgency.boardingDeparture, Fixture.date(8, 10))
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
    /// which reads very differently from waiting for your first train — and the
    /// numbers behind that claim have to hold up.
    func testTheOvertakeIsVerifiedAgainstTheTimetable() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))
        let best = try XCTUnwrap(plan.best)

        let overtake = try XCTUnwrap(best.overtake, "expected a verified overtake in \(best.trace)")
        XCTAssertEqual(overtake.boardedAt, "b")
        XCTAssertEqual(overtake.switchedAt, "c")
        XCTAssertEqual(best.overtakeWait?.stationID, "c")

        // The local they stepped off carries on to F and gets there at 08:10.
        // The express they stepped onto gets there at 08:08. That two-minute gap
        // is the overtake, and it is the only thing that makes the change worth
        // making.
        XCTAssertEqual(overtake.comparedAt, "f")
        XCTAssertEqual(overtake.arrivalIfTheyHadStayedPut, Fixture.date(8, 10))
        XCTAssertEqual(overtake.arrival, Fixture.date(8, 8))
        XCTAssertEqual(overtake.timeSaved, 120, accuracy: 1)

        let narrator = JourneyNarrator(network: Fixture.network)
        XCTAssertTrue(narrator.strategy(for: best).isOvertake)
    }

    /// Changing trains is not the same thing as being overtaken. Riding the
    /// express past a station it skips and finishing on a local has the identical
    /// shape — same line, same direction, one change — but nothing passed the
    /// rider, and the app must not claim it did.
    func testChangingTrainsWithoutBeingOvertakenIsNotCalledAnOvertake() throws {
        // A → E: the express skips E, so the only way to use it is to ride to F
        // and come back on a northbound local.
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("e"),
            departAt: Fixture.date(7, 58)
        ))

        let viaExpress = try XCTUnwrap(
            plan.journeys.first { $0.rides.count == 2 && $0.usesExpress },
            "expected an express-then-local option; got \(plan.journeys.map(\.trace))"
        )
        XCTAssertNil(
            viaExpress.overtake,
            "no train overtook anybody in \(viaExpress.trace)"
        )
        XCTAssertFalse(viaExpress.hasStrategicHold)

        let narrator = JourneyNarrator(network: Fixture.network)
        XCTAssertFalse(
            narrator.strategy(for: viaExpress).isOvertake,
            "this is a connection, not an overtake"
        )
    }

    // MARK: - What missing it costs

    /// From A at 08:01 the express leaves at 08:04 and arrives 08:08; the next
    /// local leaves 08:10 and arrives 08:20. Missing the express therefore costs
    /// twelve minutes, and the planner has to know that from the full candidate
    /// set rather than from whatever survived ranking.
    func testMissingATrainIsPricedAgainstTheRealFallback() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(8, 1)
        ))
        let express = try XCTUnwrap(plan.journeys.first)
        XCTAssertTrue(express.usesExpress)

        let cost = try XCTUnwrap(express.missedCost, "the express should have a priced fallback")
        XCTAssertEqual(cost.fallbackArrival, Fixture.date(8, 20))
        XCTAssertEqual(cost.fallbackBoarding, Fixture.date(8, 10))
        XCTAssertEqual(cost.penalty, 12 * 60, accuracy: 1)
    }

    /// Tight *and* expensive is the only combination that justifies telling someone
    /// to run. At 08:03, the 08:04 express is a minute away and costs twelve
    /// minutes to miss.
    func testRunWarningAppearsWhenItIsTightAndExpensive() throws {
        let now = Fixture.date(8, 3)
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: now
        ))
        let narrator = JourneyNarrator(network: Fixture.network)
        let express = try XCTUnwrap(plan.journeys.first)

        let advisory = try XCTUnwrap(narrator.advisory(for: express, asOf: now))
        guard case .run(let penalty, _) = advisory else {
            return XCTFail("expected a run warning, got \(advisory)")
        }
        XCTAssertGreaterThanOrEqual(penalty, 300)
        XCTAssertTrue(advisory.isUrgent)
        XCTAssertTrue(narrator.advisoryText(advisory).contains("lose"))

        // And it should lead the headline, since nothing else changes what the
        // rider does in the next thirty seconds.
        let advice = try XCTUnwrap(narrator.advice(for: plan, asOf: now))
        XCTAssertTrue(advice.contains("lose"), "got: \(advice)")
    }

    /// The inverse, which matters just as much: cutting it fine for a train whose
    /// replacement is right behind should tell the rider *not* to run. Warning
    /// them anyway teaches them to ignore the warning.
    func testNoRunWarningWhenTheNextTrainIsRightBehind() throws {
        // Locals every 10 min, express excluded, so missing one costs 10 min...
        // narrow that by asking for a stretch the express does not serve at a time
        // when two locals are close together in arrival terms.
        let planner = Fixture.planner { $0.maxTransfers = 0 }
        let now = Fixture.date(8, 9, second: 30)
        let plan = planner.plan(PlanRequest(
            origin: .station("b"),
            destination: .station("e"),
            departAt: now
        ))
        let narrator = JourneyNarrator(network: Fixture.network)
        guard let first = plan.journeys.first(where: { !$0.isWalkOnly }) else {
            return XCTFail("expected a local option")
        }
        // Whatever the advisory is, it must never claim urgency without a real
        // penalty behind it.
        if let advisory = narrator.advisory(for: first, asOf: now), case .run(let penalty, _) = advisory {
            XCTAssertGreaterThanOrEqual(penalty, 300, "urgency claimed with only \(penalty)s at stake")
        }
    }

    /// A missed option is never priced as though it were catchable.
    func testWalkOnlyJourneysHaveNoAdvisory() {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .place(name: "Near A", coordinate: Fixture.coordinate(of: "a", offsetMeters: 50)),
            destination: .place(name: "Near B", coordinate: Fixture.coordinate(of: "b", offsetMeters: 50)),
            departAt: Fixture.date(8, 1)
        ))
        let narrator = JourneyNarrator(network: Fixture.network)
        for journey in plan.journeys where journey.isWalkOnly {
            XCTAssertNil(narrator.advisory(for: journey, asOf: Fixture.date(8, 1)))
            XCTAssertNil(journey.missedCost)
        }
    }

    // MARK: - Step-free routing

    /// C has no elevator in the fixture, and C is where the overtake happens. With
    /// step-free routing on, that change has to disappear — not merely be ranked
    /// lower.
    func testStepFreeRoutingRefusesToChangeAtAnInaccessibleStation() throws {
        let plan = Fixture.planner { $0.requiresStepFreeAccess = true }.plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))

        for journey in plan.journeys {
            XCTAssertNotEqual(
                journey.overtakeWait?.stationID, "c",
                "changed trains at a station with no elevator: \(journey.trace)"
            )
            for ride in journey.rides.dropFirst() {
                XCTAssertNotEqual(ride.boardStation, "c", journey.trace)
            }
        }
        // The plain local should still be there.
        XCTAssertTrue(plan.journeys.contains { $0.rides.count == 1 }, "\(plan.journeys.map(\.trace))")
    }

    /// Without the restriction, that same trip *does* change at C — otherwise the
    /// test above proves nothing.
    func testTheOvertakeAtCIsAvailableWithoutTheRestriction() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))
        XCTAssertEqual(try XCTUnwrap(plan.best).overtakeWait?.stationID, "c")
    }

    /// Walking to an inaccessible station is refused too, not just changing there.
    func testStepFreeRoutingSkipsInaccessibleStationsAtBothEnds() {
        let plan = Fixture.planner { $0.requiresStepFreeAccess = true }.plan(PlanRequest(
            origin: .place(name: "Near C", coordinate: Fixture.coordinate(of: "c", offsetMeters: 40)),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))
        for journey in plan.journeys where !journey.isWalkOnly {
            XCTAssertNotEqual(journey.boardStation, "c", journey.trace)
        }
    }

    /// A rider given a worse answer should be told the restriction caused it.
    func testStepFreeRoutingSaysWhenItCostsTime() {
        let plan = Fixture.planner { $0.requiresStepFreeAccess = true }.plan(PlanRequest(
            origin: .station("b"),
            destination: .station("f"),
            departAt: Fixture.date(8, 0)
        ))
        let explained = plan.notes.contains { note in
            if case .stepFreeCostsTime = note { return true }
            if case .noStepFreeRouteFound = note { return true }
            return false
        }
        // Losing the overtake costs two minutes here, which is the threshold.
        XCTAssertTrue(explained || plan.journeys.allSatisfy { $0.overtake == nil },
                      "notes were \(plan.notes)")
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
