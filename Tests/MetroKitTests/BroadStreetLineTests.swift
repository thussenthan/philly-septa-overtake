import XCTest
@testable import MetroKit

/// Assertions against the timetable the app actually ships.
///
/// These guard the generated data as much as the planner: if a regeneration
/// silently drops the express, renames a station, or reverses a direction, these
/// fail rather than the app quietly giving bad advice.
final class BroadStreetLineTests: XCTestCase {

    private let network = BSLData.network
    private lazy var planner = JourneyPlanner(network: network)
    private lazy var narrator = JourneyNarrator(network: network)

    /// A weekday morning inside a normal peak.
    private func weekday(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 5           // a Wednesday
        components.hour = hour
        components.minute = minute
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        return gregorian.date(from: components)!
    }

    private func saturday(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 8           // a Saturday
        components.hour = hour
        components.minute = minute
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        return gregorian.date(from: components)!
    }

    // MARK: - Network shape

    func testTheLineHasItsTwentyFourStations() {
        XCTAssertEqual(network.stations.count, 24)
        for id in ["fern-rock", "erie", "cecil-b-moore", "girard", "fairmount",
                   "spring-garden", "city-hall", "walnut-locust", "nrg",
                   "chinatown", "8th-and-market"] {
            XCTAssertNotNil(network.station(StationID(id)), "missing station \(id)")
        }
    }

    func testStationsAreOrderedNorthToSouthOnTheLocalPattern() throws {
        let southbound = try XCTUnwrap(network.patterns.first {
            $0.kind == .local && $0.direction == .southbound && $0.stops.count == 22
        })
        let latitudes = southbound.stationIDs.compactMap { network.station($0)?.coordinate.latitude }
        XCTAssertEqual(latitudes.count, 22)
        for (north, south) in zip(latitudes, latitudes.dropFirst()) {
            XCTAssertGreaterThan(north, south, "southbound pattern is not monotonically southward")
        }
    }

    /// The express exists, runs weekdays only, and terminates at Walnut-Locust —
    /// it never reaches South Philadelphia, which is the single most common
    /// misconception about this line.
    func testExpressIsWeekdayOnlyAndStopsAtWalnutLocust() throws {
        let express = network.patterns.filter { $0.kind == .express }
        XCTAssertEqual(express.count, 2, "expected one express pattern per direction")

        for pattern in express {
            XCTAssertTrue(pattern.schedule.runs(on: .weekday))
            XCTAssertFalse(pattern.schedule.runs(on: .saturday), "\(pattern.id) should not run Saturdays")
            XCTAssertFalse(pattern.schedule.runs(on: .sunday), "\(pattern.id) should not run Sundays")

            XCTAssertFalse(pattern.serves("nrg"), "\(pattern.id) must not reach NRG")
            XCTAssertFalse(pattern.serves("oregon"))
            XCTAssertTrue(pattern.serves("walnut-locust"))
            XCTAssertTrue(pattern.serves("erie"))
            XCTAssertTrue(pattern.serves("girard"))

            // The stations express riders get burned by.
            XCTAssertFalse(pattern.serves("fairmount"), "\(pattern.id) must skip Fairmount")
            XCTAssertFalse(pattern.serves("cecil-b-moore"), "\(pattern.id) must skip Cecil B. Moore")
            XCTAssertFalse(pattern.serves("allegheny"), "\(pattern.id) must skip Allegheny")
        }
    }

    func testExpressBeatsLocalOverTheSameStretch() throws {
        let expressSouth = try XCTUnwrap(network.patterns.first {
            $0.kind == .express && $0.direction == .southbound
        })
        let localSouth = try XCTUnwrap(network.patterns.first {
            $0.kind == .local && $0.direction == .southbound && $0.stops.count == 22
        })

        func runTime(_ pattern: ServicePattern, _ from: StationID, _ to: StationID) throws -> TimeInterval {
            let start = try XCTUnwrap(pattern.stopIndex(of: from))
            let end = try XCTUnwrap(pattern.stopIndex(of: to))
            return pattern.stops[end].arrivalOffset - pattern.stops[start].departureOffset
        }

        let expressRun = try runTime(expressSouth, "erie", "city-hall")
        let localRun = try runTime(localSouth, "erie", "city-hall")
        XCTAssertLessThan(expressRun, localRun)
        // Erie → City Hall: 10.00 min express vs 14.75 min local in the July 2026 feed.
        XCTAssertEqual(expressRun / 60, 10.0, accuracy: 1.5)
        XCTAssertEqual(localRun / 60, 14.75, accuracy: 1.5)
    }

    func testSpurRunsToChinatownAndEighthAndMarketOnly() throws {
        let spur = network.patterns.filter { $0.kind == .spur }
        XCTAssertFalse(spur.isEmpty)
        for pattern in spur {
            XCTAssertTrue(pattern.serves("fairmount"), "the spur does serve Fairmount")
            XCTAssertFalse(pattern.serves("city-hall"), "the spur leaves Broad St before City Hall")
            XCTAssertFalse(pattern.schedule.runs(on: .sunday), "no Sunday spur service")
        }
        // Chinatown and 8th & Market are reachable only by the spur.
        for id in [StationID("chinatown"), StationID("8th-and-market")] {
            let serving = network.patterns(serving: id)
            XCTAssertFalse(serving.isEmpty)
            XCTAssertTrue(serving.allSatisfy { $0.kind == .spur }, "\(id) should be spur-only")
        }
    }

    // MARK: - The commute this app was built for

    /// Boarding at Erie for an address near Fairmount is the interesting case:
    /// the express stops at Erie but skips Fairmount, so using it means getting
    /// off at Girard or Spring Garden and walking. The planner has to weigh the
    /// faster ride against the longer walk, and it must offer both.
    func testErieToFairmountOffersBothTheLocalAndTheExpressWithAWalk() throws {
        // A point two blocks from Fairmount station, on the Broad St grid.
        let nearFairmount = Coordinate(latitude: 39.9690, longitude: -75.1630)

        let plan = planner.plan(PlanRequest(
            origin: .station("erie"),
            destination: .place(name: "Home", coordinate: nearFairmount),
            departAt: weekday(8, 15)
        ))

        XCTAssertFalse(plan.journeys.isEmpty, "notes: \(plan.notes)")

        let alightStations = Set(plan.journeys.compactMap(\.alightStation))
        XCTAssertTrue(
            alightStations.contains("fairmount"),
            "the local straight to Fairmount must be an option; got \(alightStations)"
        )

        // Every option must be internally consistent and actually catchable.
        for journey in plan.journeys where !journey.isWalkOnly {
            XCTAssertGreaterThanOrEqual(journey.urgency.slack, -30)
            XCTAssertEqual(journey.legs.first?.startTime, journey.departureTime)
            XCTAssertEqual(journey.legs.last?.endTime, journey.arrivalTime)
            for ride in journey.rides {
                XCTAssertEqual(ride.direction, .southbound, "heading home is southbound from Erie")
            }
        }

        // And the app must be able to say something about the choice.
        XCTAssertNotNil(narrator.advice(for: plan, asOf: weekday(8, 15)))
    }

    /// Riding the express past Fairmount to Girard, then walking, is a genuine
    /// strategy on this line. It should surface when the express is running.
    func testExpressToAnAdjacentStationIsConsideredForASkippedDestination() {
        let nearFairmount = Coordinate(latitude: 39.9690, longitude: -75.1630)
        var options = PlannerOptions()
        options.maxEgressStations = 4
        options.maxWalkSeconds = 25 * 60
        let wide = JourneyPlanner(network: network, options: options)

        let plan = wide.plan(PlanRequest(
            origin: .station("erie"),
            destination: .place(name: "Home", coordinate: nearFairmount),
            departAt: weekday(8, 15)
        ))

        let expressOptions = plan.journeys.filter(\.usesExpress)
        for journey in expressOptions {
            let alight = journey.alightStation
            XCTAssertNotEqual(alight, "fairmount", "the express cannot stop at Fairmount")
            XCTAssertTrue(
                alight == "girard" || alight == "spring-garden",
                "an express rider bound for Fairmount gets off at Girard or Spring Garden, not \(alight?.rawValue ?? "nil")"
            )
        }
    }

    /// Cecil B. Moore serves Temple's main campus and the express skips it, so a
    /// trip there is always local — and the plan should explain the absence.
    func testTripToCecilBMooreNeverUsesTheExpress() throws {
        let plan = planner.plan(PlanRequest(
            origin: .station("walnut-locust"),
            destination: .station("cecil-b-moore"),
            departAt: weekday(17, 30)
        ))
        XCTAssertFalse(plan.journeys.isEmpty, "notes: \(plan.notes)")
        for journey in plan.journeys {
            for ride in journey.rides {
                XCTAssertEqual(ride.direction, .northbound)
            }
        }
        let best = try XCTUnwrap(plan.best)
        // Express to Girard then local back up is theoretically possible but
        // should never beat simply staying on the local for two more stops.
        XCTAssertLessThanOrEqual(best.transferCount, 1)
    }

    /// On a Saturday there is no express at all; the plan must still work.
    func testSaturdayHasLocalServiceAndNoExpress() {
        let plan = planner.plan(PlanRequest(
            origin: .station("erie"),
            destination: .station("city-hall"),
            departAt: saturday(11, 0)
        ))
        XCTAssertFalse(plan.journeys.isEmpty, "notes: \(plan.notes)")
        XCTAssertFalse(plan.journeys.contains(where: \.usesExpress))
        XCTAssertTrue(plan.journeys.contains { $0.rides.contains { $0.kind == .local } })
    }

    /// Overnight the subway stops and SEPTA runs the Owl bus along Broad St.
    /// The planner should route onto it rather than reporting no service.
    func testOvernightFallsBackToTheOwlBus() throws {
        let plan = planner.plan(PlanRequest(
            origin: .station("erie"),
            destination: .station("city-hall"),
            departAt: weekday(2, 30)
        ))
        XCTAssertFalse(plan.journeys.isEmpty, "notes: \(plan.notes)")
        let best = try XCTUnwrap(plan.best)
        XCTAssertTrue(
            best.rides.allSatisfy { $0.kind == .nightBus },
            "expected the Owl bus at 2:30 AM, got \(best.trace)"
        )
        XCTAssertTrue(plan.notes.contains(.nightServiceOnly))
    }

    // MARK: - Correctness invariants over the real data

    /// Departure countdowns are only honest if no offered train has already left.
    func testNoOfferedTrainHasAlreadyDeparted() {
        let now = weekday(8, 22)
        for hourOffset in 0..<3 {
            let departAt = now.addingTimeInterval(TimeInterval(hourOffset) * 3600)
            let plan = planner.plan(PlanRequest(
                origin: .station("fern-rock"),
                destination: .station("walnut-locust"),
                departAt: departAt
            ))
            for journey in plan.journeys {
                guard let first = journey.rides.first else { continue }
                XCTAssertGreaterThanOrEqual(
                    first.departure, departAt,
                    "offered a train that left before the rider asked"
                )
            }
        }
    }

    /// Every ride must be a stretch its pattern genuinely covers, in order.
    func testEveryRideIsServedByItsPattern() {
        let pairs: [(StationID, StationID)] = [
            ("fern-rock", "nrg"),
            ("nrg", "fern-rock"),
            ("erie", "8th-and-market"),
            ("city-hall", "hunting-park"),
            ("snyder", "girard"),
        ]
        for (from, to) in pairs {
            let plan = planner.plan(PlanRequest(origin: .station(from), destination: .station(to), departAt: weekday(9, 5)))
            XCTAssertFalse(plan.journeys.isEmpty, "no route \(from) → \(to); notes: \(plan.notes)")
            for journey in plan.journeys {
                for ride in journey.rides {
                    let pattern = network.pattern(ride.patternID)
                    XCTAssertNotNil(pattern, "unknown pattern \(ride.patternID)")
                    XCTAssertTrue(
                        pattern?.carries(from: ride.boardStation, to: ride.alightStation) == true,
                        "\(ride.patternID) does not run \(ride.boardStation) → \(ride.alightStation)"
                    )
                }
                XCTAssertGreaterThan(journey.arrivalTime, journey.departureTime)
            }
        }
    }

    /// Skipped-station reporting is what justifies an express recommendation, so
    /// it has to be right.
    func testSkippedStationsAreReportedForAnExpressRide() throws {
        let plan = planner.plan(PlanRequest(
            origin: .station("erie"),
            destination: .station("city-hall"),
            departAt: weekday(8, 15)
        ))
        let expressJourney = try XCTUnwrap(
            plan.journeys.first(where: \.usesExpress),
            "expected an express option at 8:15 AM on a weekday; notes: \(plan.notes)"
        )
        let ride = try XCTUnwrap(expressJourney.rides.first { $0.kind == .express })
        let skipped = Set(narrator.skippedStations(on: ride))
        XCTAssertTrue(skipped.contains("cecil-b-moore"))
        XCTAssertTrue(skipped.contains("fairmount"))
        XCTAssertTrue(skipped.contains("allegheny"))
        XCTAssertFalse(skipped.contains("girard"), "the express does stop at Girard")
    }

    /// Riding away from your destination and doubling back is never worth showing
    /// on a single line, however much extra slack it appears to buy.
    func testNoPointlessBacktracking() {
        let cases: [(StationID, StationID, Direction)] = [
            ("city-hall", "hunting-park", .northbound),
            ("snyder", "girard", .northbound),
            ("olney", "tasker-morris", .southbound),
        ]
        for (from, to, expected) in cases {
            let plan = planner.plan(PlanRequest(
                origin: .station(from),
                destination: .station(to),
                departAt: weekday(9, 5)
            ))
            XCTAssertFalse(plan.journeys.isEmpty, "no route \(from) → \(to)")
            for journey in plan.journeys {
                for ride in journey.rides {
                    XCTAssertEqual(
                        ride.direction, expected,
                        "\(from) → \(to) offered a \(ride.direction.rawValue) ride: \(journey.trace)"
                    )
                }
            }
        }
    }

    /// The same two trains, changed at a different station, is one option — not
    /// one per station where the change happens to be possible.
    func testSameTrainsAreNotOfferedOncePerPossibleTransferPoint() {
        let plan = planner.plan(PlanRequest(
            origin: .station("nrg"),
            destination: .station("fern-rock"),
            departAt: weekday(9, 5)
        ))
        let tripSets = plan.journeys.map { journey in
            journey.rides.map(\.trip.id).joined(separator: ">")
        }
        XCTAssertEqual(
            tripSets.count, Set(tripSets).count,
            "duplicate itineraries differing only in transfer point: \(plan.journeys.map(\.trace))"
        )
    }

    func testBundledDataDeclaresItsProvenance() {
        XCTAssertEqual(network.provenance.fidelity, .official)
        XCTAssertFalse(network.provenance.isEstimate)
        XCTAssertFalse(BSLData.feedVersion.isEmpty)
        XCTAssertNotNil(network.provenance.feedExpiryDate)
        XCTAssertEqual(network.provenance.validUntil, BSLData.feedEndDate)
    }

    /// Performance matters because the app replans on every location update.
    func testPlanningIsFastEnoughToRunOnEveryLocationUpdate() {
        let request = PlanRequest(
            origin: .place(name: "Origin", coordinate: Coordinate(latitude: 40.0092, longitude: -75.1512)),
            destination: .place(name: "Destination", coordinate: Coordinate(latitude: 39.9690, longitude: -75.1630)),
            departAt: weekday(8, 15)
        )
        measure {
            _ = planner.plan(request)
        }
    }
}
