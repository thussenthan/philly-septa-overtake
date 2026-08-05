import XCTest
@testable import MetroKit

/// What the app tells a rider to look for once they're standing in the station.
///
/// This is the last step of the answer and the easiest one to get wrong: a card
/// that says "B" when two different B trains use two different tracks at Erie has
/// handed the hardest part of the decision back to the rider.
final class PlatformInfoTests: XCTestCase {

    private let network = SEPTAData.network

    private func journey(from: StationID, to: StationID, at hour: Int, _ minute: Int) throws -> Journey {
        var options = PlannerOptions()
        options.maxResults = 6
        let planner = JourneyPlanner(network: network, options: options)
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 5
        components.hour = hour; components.minute = minute
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        let plan = planner.plan(PlanRequest(
            origin: .station(from),
            destination: .station(to),
            departAt: gregorian.date(from: components)!
        ))
        return try XCTUnwrap(plan.best)
    }

    /// The route, not the line letter. On the Broad Street Line the difference
    /// between B1, B2 and B3 is the difference between the train that stops where
    /// you're going and two that don't.
    func testRidesCarryTheRouteTheSignsUse() throws {
        let journey = try journey(from: "erie", to: "walnut-locust", at: 8, 15)
        let badges = journey.rides.map(\.routeBadge)
        XCTAssertFalse(badges.isEmpty)
        for badge in badges {
            XCTAssertTrue(
                badge.hasPrefix("B"),
                "a Broad St trip should be on a B route, got \(badges)"
            )
            XCTAssertNotEqual(badge, "B", "the line letter alone doesn't identify the train")
        }
    }

    /// Every route in the bundled data must produce a badge a rider could match
    /// against something painted in a station — no feed identifiers.
    func testEveryRouteBadgeIsSomethingWrittenInAStation() {
        for pattern in network.patterns {
            let badge = pattern.kind == .nightBus ? "OWL" : pattern.routeID.rawValue
            XCTAssertFalse(badge.isEmpty, pattern.id.rawValue)
            XCTAssertFalse(
                badge.contains("_"),
                "\(badge) is a feed identifier, not a route a rider can see"
            )
            XCTAssertLessThanOrEqual(badge.count, 4, "\(badge) won't fit on a badge")
        }
    }

    /// The Owl bus is filed as `B1_OWL`, which is not written on anything.
    func testTheOwlBusIsNamedTheWayRidersNameIt() throws {
        // Erie → City Hall at 2:30 AM, the case the overnight test already pins down.
        let journey = try journey(from: "erie", to: "city-hall", at: 2, 30)
        let owl = try XCTUnwrap(
            journey.rides.first { $0.kind == .nightBus },
            "expected the Owl bus overnight, got \(journey.rides.map(\.routeBadge))"
        )
        XCTAssertEqual(owl.routeBadge, "OWL")
        XCTAssertFalse(owl.routeID.rawValue == owl.routeBadge, "the feed ID should not be shown as-is")
    }

    /// Both cues a rider matches against: the word on the station entrance and the
    /// terminus painted on the front of the train.
    func testPlatformDescriptionCarriesDirectionAndHeadsign() throws {
        let journey = try journey(from: "erie", to: "walnut-locust", at: 8, 15)
        for ride in journey.rides {
            XCTAssertTrue(
                ride.platformDescription.contains(ride.headsign),
                "\(ride.platformDescription) should name the terminus on the front of the train"
            )
            XCTAssertTrue(
                ride.platformDescription.hasPrefix("Southbound"),
                "Erie to Walnut-Locust is southbound, got \(ride.platformDescription)"
            )
        }
    }

    /// The direction words come from SEPTA's own directions.txt, and the reason that
    /// matters is D1/D2: the feed calls them northbound and southbound, while Media
    /// is mostly *west* of 69th St. Anything derived from the coordinates says west,
    /// and every sign in the station says southbound.
    func testDirectionWordsAreTheOnesSEPTAPublishes() throws {
        let expected: [RouteID: Set<CompassDirection>] = [
            "B1": [.north, .south], "B2": [.north, .south], "B3": [.north, .south],
            "L1": [.east, .west],
            "M1": [.north, .south],
            "T1": [.east, .west], "T2": [.east, .west], "T3": [.east, .west],
            "T4": [.east, .west], "T5": [.east, .west],
            "G1": [.east, .west],
            // The one no amount of measuring gets right.
            "D1": [.north, .south], "D2": [.north, .south],
            "75": [.east, .west],
            "59": [.north, .south], "66": [.north, .south],
        ]
        for (route, allowed) in expected {
            let found = Set(network.patterns.filter { $0.routeID == route }.compactMap(\.compass))
            XCTAssertFalse(found.isEmpty, "\(route) declares no direction")
            XCTAssertTrue(
                found.isSubset(of: allowed),
                "\(route) is \(found.map(\.label).sorted()), SEPTA says \(allowed.map(\.label).sorted())"
            )
        }
    }

    /// Media is west of 69th St, so this is the specific claim the feed overrides.
    func testTheMediaRoutesContradictTheirOwnGeometry() throws {
        let start = try XCTUnwrap(network.station("69th-st-transit-center")?.coordinate)
        let end = try XCTUnwrap(network.station("orange-st-media")?.coordinate)
        let north = abs(end.latitude - start.latitude) * 111_320
        let east = abs(end.longitude - start.longitude) * cos(start.latitude * .pi / 180) * 111_320
        XCTAssertGreaterThan(east, north, "Media is further west of 69th St than it is south")

        let declared = Set(network.patterns.filter { $0.routeID == "D1" }.compactMap(\.compass))
        XCTAssertEqual(declared, [.north, .south], "SEPTA calls it north-south anyway")
    }

    /// Every direction a rider is shown must be one the operator uses for that
    /// route, in both senses — a pattern declaring only one of the pair means half
    /// the trips would show nothing.
    func testEveryRouteDeclaresBothOfItsDirections() {
        var byRoute: [RouteID: Set<CompassDirection>] = [:]
        for pattern in network.patterns {
            guard let compass = pattern.compass else { continue }
            byRoute[pattern.routeID, default: []].insert(compass)
        }
        for (route, directions) in byRoute {
            XCTAssertEqual(directions.count, 2, "\(route) only ever runs \(directions.map(\.label))")
        }
    }

    /// A local is just "Southbound" — saying "Local" on every ordinary train buries
    /// the one word that matters when it isn't one.
    func testOnlyFastTrainsAnnounceTheirStoppingPattern() throws {
        let express = try XCTUnwrap(network.patterns.first { $0.kind == .express })
        let local = try XCTUnwrap(network.patterns.first { $0.kind == .local })

        XCTAssertEqual(ride(on: express, compass: .south).platformHeadline, "Southbound · Express")
        XCTAssertEqual(ride(on: local, compass: .south).platformHeadline, "Southbound")

        // With no measurable heading the headsign has to carry the row on its own.
        XCTAssertEqual(ride(on: local, compass: nil).platformHeadline,
                       "toward \(local.headsign)")
    }

    // MARK: - Doors and published times

    /// SEPTA marks a few mid-route stops as no-pickup or no-drop-off. All 1,082 such
    /// stop times on the Metro map are at middle stops, so there is no shortcut of
    /// assuming it only happens at a terminus — and a plan that ignores them sends a
    /// rider to a door that won't open.
    func testStopsWhereTheDoorDoesNotOpenAreHonoured() throws {
        let restricted = network.patterns.flatMap { pattern in
            pattern.stops.enumerated().compactMap { index, stop in
                (!stop.allowsBoarding || !stop.allowsAlighting) ? (pattern, index, stop) : nil
            }
        }
        XCTAssertFalse(restricted.isEmpty, "the feed has these; the data should keep them")

        for (pattern, index, stop) in restricted {
            // Never a trip end — which is exactly why they can't be ignored.
            XCTAssertGreaterThan(index, 0, "\(pattern.id) restricts its first stop")
            XCTAssertLessThan(index, pattern.stops.count - 1, "\(pattern.id) restricts its last stop")

            if !stop.allowsBoarding {
                XCTAssertFalse(
                    pattern.carries(from: stop.station, to: pattern.stops.last!.station),
                    "\(pattern.id) offers a ride starting where boarding is prohibited"
                )
                XCTAssertFalse(pattern.allowsBoarding(at: stop.station))
            }
            if !stop.allowsAlighting {
                XCTAssertFalse(
                    pattern.carries(from: pattern.stops.first!.station, to: stop.station),
                    "\(pattern.id) offers a ride ending where alighting is prohibited"
                )
                XCTAssertFalse(pattern.allowsAlighting(at: stop.station))
            }
        }
    }

    /// The subway's times are published to the stop. The trolleys' mostly aren't, and
    /// an app selling itself on precise countdowns should know which is which.
    func testPublishedTimeShareMatchesWhatSEPTAActuallyPublishes() {
        func share(_ route: RouteID) -> Int? {
            network.patterns.first { $0.routeID == route }?.publishedTimePercent
        }
        XCTAssertEqual(share("B1"), 100, "every Broad St stop time is a timing point")
        XCTAssertEqual(share("B2"), 100)

        for route: RouteID in ["T1", "T2", "T3", "G1"] {
            let percent = try? XCTUnwrap(share(route))
            XCTAssertLessThan(percent ?? 100, 50, "\(route) is mostly interpolated in the feed")
        }
        XCTAssertTrue(network.patterns.contains { $0.hasMostlyEstimatedTimes })
        XCTAssertTrue(network.patterns.contains { !$0.hasMostlyEstimatedTimes })
    }

    /// SEPTA's own ordering, so the picker reads like the operator's map rather than
    /// like an alphabet — route 59 is not the first thing on this network.
    func testLinesAreOrderedTheWaySEPTAOrdersThem() throws {
        let ordered = network.lines.sorted { $0.sortOrder < $1.sortOrder }.map(\.badge)
        XCTAssertEqual(Array(ordered.prefix(6)), ["L", "B", "T", "G", "D", "M"])
        XCTAssertEqual(
            Set(ordered.suffix(4)), ["59", "66", "75", "B"],
            "the trackless trolleys and the Owl bus come last"
        )
    }

    private func ride(on pattern: ServicePattern, compass: CompassDirection? = nil) -> RideLeg {
        RideLeg(
            trip: Trip(
                patternID: pattern.id,
                startTime: Date(),
                scheduledStartSecondsAfterMidnight: 8 * 3600,
                dayType: .wednesday
            ),
            patternID: pattern.id,
            lineID: pattern.lineID,
            routeID: pattern.routeID,
            kind: pattern.kind,
            direction: pattern.direction,
            compass: compass,
            headsign: pattern.headsign,
            boardStation: pattern.stops.first!.station,
            alightStation: pattern.stops.last!.station,
            departure: Date(),
            arrival: Date().addingTimeInterval(600),
            stationsServed: pattern.stationIDs
        )
    }
}
