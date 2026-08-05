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

    /// The headsign leads, because it is the cue that always works: compass
    /// directions are meaningless on a trolley running east–west.
    func testPlatformDescriptionNamesTheHeadsign() throws {
        let journey = try journey(from: "erie", to: "walnut-locust", at: 8, 15)
        for ride in journey.rides {
            XCTAssertTrue(
                ride.platformDescription.contains(ride.headsign),
                "\(ride.platformDescription) should name the terminus on the front of the train"
            )
            XCTAssertTrue(ride.platformDescription.hasPrefix("toward")
                          || ride.platformDescription.hasPrefix(ride.kind.label),
                          ride.platformDescription)
        }
    }

    /// A local is just "toward X" — saying "Local toward X" on every ordinary train
    /// is noise. A fast train has to say so, because that is the whole decision.
    func testOnlyFastTrainsAnnounceTheirStoppingPattern() throws {
        let express = try XCTUnwrap(network.patterns.first { $0.kind == .express })
        let local = try XCTUnwrap(network.patterns.first { $0.kind == .local })

        let expressRide = ride(on: express)
        let localRide = ride(on: local)
        XCTAssertTrue(expressRide.platformDescription.hasPrefix("Express toward"), expressRide.platformDescription)
        XCTAssertTrue(localRide.platformDescription.hasPrefix("toward"), localRide.platformDescription)
    }

    private func ride(on pattern: ServicePattern) -> RideLeg {
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
            headsign: pattern.headsign,
            boardStation: pattern.stops.first!.station,
            alightStation: pattern.stops.last!.station,
            departure: Date(),
            arrival: Date().addingTimeInterval(600),
            stationsServed: pattern.stationIDs
        )
    }
}
