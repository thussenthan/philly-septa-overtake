import XCTest
@testable import MetroKit

/// What a trip costs, and the one case where it isn't obvious.
///
/// The flat fare is uninteresting. The transfer isn't: SEPTA's own
/// `fare_transfer_rules` include it free on Key and contactless and say nothing
/// about cash, so the same two-train itinerary is one fare or two depending on how
/// the rider tapped in. That is the only fare fact on this network that can change
/// which option someone picks.
final class FareTests: XCTestCase {

    private let network = SEPTAData.network

    private func journey(rides: Int, apart: TimeInterval = 600) -> Journey {
        let pattern = network.patterns.first { $0.stops.count > 3 }!
        let legs: [JourneyLeg] = (0..<rides).map { index in
            let departure = Date(timeIntervalSince1970: 1_770_000_000 + Double(index) * apart)
            return .ride(RideLeg(
                trip: Trip(
                    patternID: pattern.id,
                    startTime: departure,
                    scheduledStartSecondsAfterMidnight: 8 * 3600,
                    dayType: .wednesday
                ),
                patternID: pattern.id,
                lineID: pattern.lineID,
                routeID: pattern.routeID,
                kind: pattern.kind,
                direction: pattern.direction,
                headsign: pattern.headsign,
                boardStation: pattern.stops[0].station,
                alightStation: pattern.stops[1].station,
                departure: departure,
                arrival: departure.addingTimeInterval(300),
                stationsServed: [pattern.stops[0].station, pattern.stops[1].station]
            ))
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        return Journey(
            legs: legs,
            departureTime: start,
            arrivalTime: start.addingTimeInterval(Double(rides) * apart),
            urgency: Urgency(leaveBy: start, boardingDeparture: start, slack: 300)
        )
    }

    // MARK: - The rules, as published

    func testTheBundledDataCarriesSEPTAsFareRules() {
        let fare = network.fare
        XCTAssertTrue(fare.isKnown)
        XCTAssertEqual(fare.amount, 2.90, accuracy: 0.001)
        XCTAssertEqual(fare.currency, "USD")
        XCTAssertEqual(fare.transferWindow, 7200, "two hours")
        XCTAssertEqual(fare.includedTransfers, 2)
        XCTAssertEqual(fare.freeTransferMedia, ["Contactless Payment", "SEPTA Key"])
        XCTAssertEqual(fare.perBoardingMedia, ["Cash", "Quick Trip"])
    }

    // MARK: - What a journey costs

    func testOneTrainIsOneFareHoweverYouPay() throws {
        let fare = try XCTUnwrap(journey(rides: 1).fare(network.fare))
        XCTAssertEqual(fare.boardings, 1)
        XCTAssertEqual(fare.withFreeTransfers, 2.90, accuracy: 0.001)
        XCTAssertEqual(fare.perBoarding, 2.90, accuracy: 0.001)
        XCTAssertFalse(fare.mediumMatters, "nothing to decide on a single ride")
    }

    /// The case the card exists for: the change is free with Key, and $2.90 without.
    func testAChangeOfTrainIsFreeOnKeyAndPaidInCash() throws {
        let fare = try XCTUnwrap(journey(rides: 2).fare(network.fare))
        XCTAssertTrue(fare.transfersAreCovered)
        XCTAssertEqual(fare.withFreeTransfers, 2.90, accuracy: 0.001)
        XCTAssertEqual(fare.perBoarding, 5.80, accuracy: 0.001)
        XCTAssertTrue(fare.mediumMatters)
    }

    func testTheAllowanceRunsOutAfterTwoChanges() throws {
        // Three changes is four boardings — one more than a single fare covers.
        let fare = try XCTUnwrap(journey(rides: 4).fare(network.fare))
        XCTAssertFalse(fare.transfersAreCovered)
        XCTAssertEqual(fare.withFreeTransfers, 5.80, accuracy: 0.001, "a second fare starts")
        XCTAssertEqual(fare.perBoarding, 11.60, accuracy: 0.001)
    }

    /// Two hours is the limit, and a journey longer than that pays again even with
    /// only one change.
    func testAChangeOutsideTheWindowIsNotFree() throws {
        let inside = try XCTUnwrap(journey(rides: 2, apart: 7100).fare(network.fare))
        XCTAssertTrue(inside.transfersAreCovered)

        let outside = try XCTUnwrap(journey(rides: 2, apart: 7300).fare(network.fare))
        XCTAssertFalse(outside.transfersAreCovered)
        XCTAssertEqual(outside.withFreeTransfers, 5.80, accuracy: 0.001)
    }

    func testAWalkCostsNothing() {
        let walk = Journey(
            legs: [.walk(WalkLeg(
                purpose: .direct, fromName: "A", toName: "B",
                straightLineMeters: 400, routedMeters: 500, duration: 400,
                startTime: Date(timeIntervalSince1970: 1_770_000_000)
            ))],
            departureTime: Date(timeIntervalSince1970: 1_770_000_000),
            arrivalTime: Date(timeIntervalSince1970: 1_770_000_400),
            urgency: .unconstrained(from: Date(timeIntervalSince1970: 1_770_000_000))
        )
        XCTAssertNil(walk.fare(network.fare), "there is nothing to pay to walk")
    }

    func testAnUnknownFareIsReportedAsUnknownRatherThanFree() {
        XCTAssertNil(journey(rides: 2).fare(FareRules(amount: 0)))
        XCTAssertFalse(FareRules(amount: 0).isKnown)
    }

    func testMoneyIsFormattedAsCurrency() {
        let text = Format.money(2.90, currency: "USD")
        XCTAssertTrue(text.contains("2.90"), text)
        XCTAssertTrue(text.contains("$") || text.contains("USD"), text)
    }
}
