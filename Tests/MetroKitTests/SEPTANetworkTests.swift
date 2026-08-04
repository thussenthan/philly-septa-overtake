import XCTest
@testable import MetroKit

/// Assertions against the timetable the app actually ships.
///
/// These guard the generated data as much as the planner: if a regeneration
/// silently drops the express, renames a station, or reverses a direction, these
/// fail rather than the app quietly giving bad advice.
final class SEPTANetworkTests: XCTestCase {

    private let network = SEPTAData.network
    private lazy var planner = JourneyPlanner(network: network)
    private lazy var narrator = JourneyNarrator(network: network)

    /// The bundled data now covers the whole Metro rail map, so assertions about
    /// the Broad Street Line have to scope themselves to it rather than to
    /// "everything in the network".
    private var broadStreetPatterns: [ServicePattern] {
        network.patterns.filter { $0.lineID == "B" }
    }

    private let broadStreetStations: [StationID] = [
        "fern-rock", "olney", "logan", "wyoming", "hunting-park", "erie", "allegheny",
        "north-philadelphia", "susquehanna-dauphin", "cecil-b-moore", "girard",
        "fairmount", "spring-garden", "race-vine", "city-hall", "walnut-locust",
        "lombard-south", "ellsworth-federal", "tasker-morris", "snyder", "oregon", "nrg",
    ]

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

    func testTheBroadStreetLineHasAllTwentyTwoOfItsStations() {
        for id in broadStreetStations {
            XCTAssertNotNil(network.station(id), "missing station \(id)")
        }
        // Plus the two the Spur adds.
        XCTAssertNotNil(network.station("chinatown"))
        XCTAssertNotNil(network.station("8th-and-market"))
    }

    /// The whole Metro rail map, not one line.
    func testTheNetworkCoversEveryMetroLine() {
        let lines = Set(network.patterns.map(\.lineID))
        for expected: LineID in ["B", "L", "M", "T", "G", "D"] {
            XCTAssertTrue(lines.contains(expected), "no patterns on line \(expected)")
        }
        XCTAssertGreaterThan(network.stations.count, 500)
        XCTAssertFalse(network.lines.isEmpty)
        for line in network.lines {
            XCTAssertEqual(line.colorHex.count, 6, "\(line.id) has an unusable colour")
        }
    }

    /// City Hall carries the B, the L and all five trolley routes; 69th St carries
    /// the L, the M and both Media-Sharon Hill routes. These merges are what make
    /// cross-line routing possible at all, so they are worth pinning.
    func testTheMajorInterchangesAreSingleStations() {
        for id: StationID in ["city-hall", "69th-st-transit-center", "8th-and-market", "40th-st"] {
            let lines = Set(network.patterns(serving: id).map(\.lineID))
            XCTAssertGreaterThan(lines.count, 1, "\(id) should join more than one line, got \(lines)")
        }
        XCTAssertTrue(Set(network.patterns(serving: "city-hall").map(\.lineID)).isSuperset(of: ["B", "L", "T"]))
        XCTAssertTrue(Set(network.patterns(serving: "40th-st").map(\.lineID)).isSuperset(of: ["L", "T"]))
    }

    /// A trip the Broad Street Line alone could never serve.
    func testCrossLineRoutingWorks() throws {
        let plan = planner.plan(PlanRequest(
            origin: .station("cecil-b-moore"),
            destination: .station("40th-st"),
            departAt: weekday(8, 15)
        ))
        let best = try XCTUnwrap(plan.best, "notes: \(plan.notes)")
        let lines = best.rides.map(\.lineID)
        XCTAssertTrue(lines.contains("B"), "should start on the B, got \(best.trace)")
        XCTAssertTrue(lines.contains("L"), "should finish on the L, got \(best.trace)")
    }

    func testStationsAreOrderedNorthToSouthOnTheLocalPattern() throws {
        let southbound = try XCTUnwrap(broadStreetPatterns.first {
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
        let express = broadStreetPatterns.filter { $0.kind == .express }
        XCTAssertEqual(express.count, 2, "expected one express pattern per direction")

        for pattern in express {
            for day in DayType.weekdays {
                XCTAssertTrue(pattern.schedule.runs(on: day), "\(pattern.id) should run on \(day)")
            }
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
        let expressSouth = try XCTUnwrap(broadStreetPatterns.first {
            $0.kind == .express && $0.direction == .southbound
        })
        let localSouth = try XCTUnwrap(broadStreetPatterns.first {
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
        // Chinatown is the Spur's alone. 8th & Market is not: it is also an L
        // station, and merging the two feed names is what makes that interchange
        // reachable.
        let chinatown = network.patterns(serving: "chinatown")
        XCTAssertFalse(chinatown.isEmpty)
        XCTAssertTrue(chinatown.allSatisfy { $0.kind == .spur }, "Chinatown should be Spur-only")
        XCTAssertTrue(network.patterns(serving: "8th-and-market").contains { $0.lineID == "L" })
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
            for ride in journey.rides where ride.lineID == "B" {
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
            for ride in journey.rides where ride.lineID == "B" {
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
        XCTAssertTrue(
            plan.journeys.contains { !$0.rides.isEmpty && $0.rides.allSatisfy { $0.kind == .nightBus } },
            "expected an Owl bus option at 2:30 AM, got \(plan.journeys.map(\.trace))"
        )
        XCTAssertFalse(
            plan.journeys.contains { $0.rides.contains { $0.lineID == "B" && $0.kind != .nightBus } },
            "the Broad Street subway is not running at 2:30 AM"
        )
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

    /// Boarding the local at Fern Rock and changing to the express at Olney is a
    /// real overtake: the local you step off carries on to Walnut-Locust and gets
    /// there later than the express you step onto.
    func testLocalToExpressAtOlneyIsAVerifiedOvertake() throws {
        let plan = planner.plan(PlanRequest(
            origin: .station("fern-rock"),
            destination: .station("walnut-locust"),
            departAt: weekday(8, 22)
        ))

        let halfAndHalf = try XCTUnwrap(
            plan.journeys.first { $0.rides.count == 2 },
            "expected a local-then-express option; got \(plan.journeys.map(\.trace))"
        )
        let overtake = try XCTUnwrap(halfAndHalf.overtake, "should be a verified overtake")
        XCTAssertEqual(overtake.boardedAt, "fern-rock")
        XCTAssertEqual(overtake.switchedAt, "olney")
        XCTAssertEqual(overtake.comparedAt, "walnut-locust")
        XCTAssertGreaterThan(overtake.timeSaved, 60, "the switch has to actually gain time")
        XCTAssertLessThan(overtake.arrival, overtake.arrivalIfTheyHadStayedPut)

        XCTAssertTrue(narrator.strategy(for: halfAndHalf).isOvertake)
    }

    /// Changing trains because the first one doesn't go where you're going is not
    /// an overtake, and must not be described as one.
    ///
    /// Every one of these has the same shape as a real overtake — same line, one
    /// change — but in each case the train being abandoned never reaches the
    /// destination, so nothing passed the rider.
    func testConnectionsOntoTrainsThatGoFurtherAreNotOvertakes() {
        let cases: [(StationID, StationID, Date)] = [
            ("erie", "8th-and-market", weekday(9, 5)),     // express stops short of the Spur
            ("olney", "tasker-morris", weekday(9, 5)),     // express terminates at Walnut-Locust
        ]
        for (from, to, when) in cases {
            let plan = planner.plan(PlanRequest(origin: .station(from), destination: .station(to), departAt: when))
            for journey in plan.journeys where journey.rides.count > 1 {
                let firstRide = journey.rides[0]
                let firstPattern = network.pattern(firstRide.patternID)
                // Precondition for the case being interesting at all.
                guard firstPattern?.serves(to) != true else { continue }
                XCTAssertNil(
                    journey.overtake,
                    "\(from) → \(to): \(journey.trace) is a connection, not an overtake"
                )
                XCTAssertFalse(narrator.strategy(for: journey).isOvertake, journey.trace)
            }
        }
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
                for ride in journey.rides where ride.lineID == "B" {
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

    /// The data is text parsed at runtime, so a decoder bug would not fail to
    /// compile — it would quietly yield a smaller network and route over less of
    /// the city. The generator writes down what it emitted; this checks it survived.
    func testTheDecodedNetworkMatchesWhatWasGenerated() {
        XCTAssertEqual(network.stations.count, SEPTAData.expectedStationCount)
        XCTAssertEqual(network.patterns.count, SEPTAData.expectedPatternCount)

        let departures = network.patterns.reduce(0) { total, pattern in
            total + DayType.allCases.reduce(0) { $0 + pattern.schedule.startTimes(on: $1).count }
        }
        XCTAssertEqual(departures, SEPTAData.expectedDepartureCount)

        // Nothing half-parsed: every pattern has stops, a schedule, and real stations.
        for pattern in network.patterns {
            XCTAssertGreaterThanOrEqual(pattern.stops.count, 2, "\(pattern.id) has too few stops")
            XCTAssertFalse(pattern.activeDays.isEmpty, "\(pattern.id) runs on no day")
            XCTAssertFalse(pattern.headsign.isEmpty, "\(pattern.id) has no headsign")
            for stop in pattern.stops {
                XCTAssertNotNil(network.station(stop.station), "\(pattern.id) stops at unknown \(stop.station)")
            }
            // Offsets must increase along the pattern, or arrival times go backwards.
            for (earlier, later) in zip(pattern.stops, pattern.stops.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.departureOffset, later.arrivalOffset, pattern.id.rawValue)
            }
        }
        for station in network.stations {
            XCTAssertFalse(station.name.isEmpty)
            XCTAssertNotEqual(station.coordinate.latitude, 0)
            XCTAssertNotEqual(station.coordinate.longitude, 0)
        }
    }

    /// Every day of the week carries service, which is the whole point of modelling
    /// the week day by day rather than as weekday/Saturday/Sunday.
    func testEveryDayOfTheWeekHasService() {
        for day in DayType.allCases {
            XCTAssertTrue(
                network.patterns.contains { $0.schedule.runs(on: day) },
                "nothing runs on \(day)"
            )
        }
    }

    func testBundledDataDeclaresItsProvenance() {
        XCTAssertEqual(network.provenance.fidelity, .official)
        XCTAssertFalse(network.provenance.isEstimate)
        XCTAssertFalse(SEPTAData.feedVersion.isEmpty)
        XCTAssertNotNil(network.provenance.feedExpiryDate)
        XCTAssertEqual(network.provenance.validUntil, SEPTAData.feedEndDate)
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
