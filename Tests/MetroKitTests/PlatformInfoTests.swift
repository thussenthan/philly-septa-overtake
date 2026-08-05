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

    /// The Broad Street Line runs north–south and the Market-Frankford Line runs
    /// east–west, so the direction cannot be a property of the app — it has to come
    /// from where the rider is actually going.
    func testDirectionFollowsTheAxisTheLineActuallyRunsOn() throws {
        let southbound = try journey(from: "erie", to: "walnut-locust", at: 8, 15)
        XCTAssertEqual(southbound.rides.first?.compass, .south)

        let northbound = try journey(from: "walnut-locust", to: "erie", at: 8, 15)
        XCTAssertEqual(northbound.rides.first?.compass, .north)

        // 69th St is the western end of the L; Frankford the eastern.
        let westbound = try journey(from: "city-hall", to: "69th-st-transit-center", at: 8, 15)
        XCTAssertEqual(westbound.rides.first?.compass, .west, "got \(westbound.trace)")

        let eastbound = try journey(from: "city-hall", to: "frankford-transit-center", at: 8, 15)
        XCTAssertEqual(eastbound.rides.first?.compass, .east, "got \(eastbound.trace)")
    }

    func testCompassLabelsReadTheWaySignsAreWritten() {
        XCTAssertEqual(CompassDirection.north.label, "Northbound")
        XCTAssertEqual(CompassDirection.south.label, "Southbound")
        XCTAssertEqual(CompassDirection.east.label, "Eastbound")
        XCTAssertEqual(CompassDirection.west.label, "Westbound")
    }

    /// The axis is a property of the line and the sense a property of the ride, and
    /// conflating them gets Philadelphia wrong. Frankford is 7.8 km north of City
    /// Hall and only 7.4 km east of it, so measuring this ride on its own says
    /// "northbound" while every sign in the station says eastbound.
    func testTheLineDecidesTheAxisNotTheIndividualRide() throws {
        let cityHall = try XCTUnwrap(network.station("city-hall")?.coordinate)
        let frankford = try XCTUnwrap(network.station("frankford-transit-center")?.coordinate)
        let sixtyNinth = try XCTUnwrap(network.station("69th-st-transit-center")?.coordinate)

        // Judged alone, this ride is more north than east.
        let (north, east) = Coordinate.offsetMeters(from: cityHall, to: frankford)
        XCTAssertGreaterThan(abs(north), abs(east), "the trap this exists to avoid")

        // The line end to end is east-west, and that is what names the direction.
        let axis = TransitAxis(from: sixtyNinth, to: frankford)
        XCTAssertEqual(axis, .eastWest)
        XCTAssertEqual(CompassDirection(travelling: cityHall, to: frankford, along: axis), .east)
        XCTAssertEqual(CompassDirection(travelling: frankford, to: cityHall, along: axis), .west)
    }

    func testNoHeadingIsAnnouncedWhenThereIsNone() throws {
        let start = Coordinate(latitude: 39.9526, longitude: -75.1652)
        // A loop route can put a rider off roughly where they got on.
        XCTAssertNil(CompassDirection(travelling: start, to: start, along: .northSouth))
        XCTAssertNil(
            CompassDirection(
                travelling: start,
                to: Coordinate(latitude: 39.9536, longitude: -75.1652),
                along: .northSouth
            ),
            "110 m is not a heading"
        )
        // Movement along the *other* axis doesn't count either.
        XCTAssertNil(
            CompassDirection(
                travelling: start,
                to: Coordinate(latitude: 39.9526, longitude: -75.1300),
                along: .northSouth
            ),
            "3 km east is not a north-south heading"
        )
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
