import XCTest
@testable import MetroKit

final class RecentPlacesTests: XCTestCase {
    let aldi = Coordinate(latitude: 39.9700, longitude: -75.1500)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSamePlaceCountsUpAndKeepsItsId() {
        var log = RecentPlaceLog()
        let first = log.record(name: "Aldi", address: "1 Main St", coordinate: aldi, at: t0)
        // A different spelling of the same store, 20 m away.
        let again = log.record(name: "ALDI", address: "1 Main Street",
                               coordinate: Coordinate(latitude: 39.97015, longitude: -75.1500), at: t0 + 60)
        XCTAssertEqual(log.places.count, 1)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.uses, 2)
    }

    func testOffersFavoriteOnceAfterThreeChoices() {
        var log = RecentPlaceLog()
        var place = log.record(name: "Aldi", address: "", coordinate: aldi, at: t0)
        XCTAssertFalse(log.shouldOfferFavorite(place))
        place = log.record(name: "Aldi", address: "", coordinate: aldi, at: t0 + 1)
        XCTAssertFalse(log.shouldOfferFavorite(place))
        place = log.record(name: "Aldi", address: "", coordinate: aldi, at: t0 + 2)
        XCTAssertTrue(log.shouldOfferFavorite(place))
        log.markPrompted(place.id)
        place = log.record(name: "Aldi", address: "", coordinate: aldi, at: t0 + 3)
        XCTAssertFalse(log.shouldOfferFavorite(place), "asked once, never again")
    }

    func testMostRecentFirstAndCapped() {
        var log = RecentPlaceLog()
        for i in 0..<(RecentPlaceLog.capacity + 3) {
            log.record(name: "P\(i)", address: "", coordinate: Coordinate(latitude: 39.9 + Double(i) * 0.01, longitude: -75.1),
                       at: t0 + Double(i))
        }
        XCTAssertEqual(log.places.count, RecentPlaceLog.capacity)
        XCTAssertEqual(log.places.first?.name, "P\(RecentPlaceLog.capacity + 2)")
        XCTAssertFalse(log.places.contains { $0.name == "P0" })
    }

    func testRoundTripsThroughJSON() throws {
        var log = RecentPlaceLog()
        log.record(name: "Aldi", address: "x", coordinate: aldi, at: t0)
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(RecentPlaceLog.self, from: data), log)
    }
}
