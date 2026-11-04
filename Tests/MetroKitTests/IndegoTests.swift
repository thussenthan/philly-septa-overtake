import XCTest
@testable import MetroKit

final class IndegoTests: XCTestCase {
    private let cityHall = Coordinate(latitude: 39.9524, longitude: -75.1636)
    private let temple = Coordinate(latitude: 39.9812, longitude: -75.1550)

    private func dock(_ id: String, _ c: Coordinate, classic: Int, electric: Int, docks: Int = 10) -> IndegoStation {
        IndegoStation(id: id, name: id, coordinate: c, classicBikes: classic, electricBikes: electric, openDocks: docks)
    }

    func testPricesFollowThePass() {
        XCTAssertEqual(IndegoPass.payAsYouGo.price(minutes: 20, bike: .classic), 3.0, accuracy: 0.001)
        XCTAssertEqual(IndegoPass.payAsYouGo.price(minutes: 20, bike: .electric), 9.0, accuracy: 0.001)
        XCTAssertEqual(IndegoPass.indego30.price(minutes: 20, bike: .classic), 0, accuracy: 0.001)
        XCTAssertEqual(IndegoPass.indego30.price(minutes: 70, bike: .classic), 1.5, accuracy: 0.001)
        XCTAssertEqual(IndegoPass.access.price(minutes: 20, bike: .electric), 1.4, accuracy: 0.001)
        XCTAssertEqual(IndegoPass.indego365Plus.price(minutes: 20, bike: .electric), 0, accuracy: 0.001)
    }

    func testClassicIsListedFirstWhenAvailableAndElectricIsFaster() {
        let stations = [
            dock("a", Coordinate(latitude: 39.9530, longitude: -75.1640), classic: 2, electric: 3),
            dock("b", Coordinate(latitude: 39.9805, longitude: -75.1555), classic: 0, electric: 0),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let options = IndegoPlanner().options(from: cityHall, to: temple, stations: stations, departAt: now)
        XCTAssertEqual(options.map(\.bike), [.classic, .electric])
        XCTAssertLessThan(options[1].arrival, options[0].arrival)
        XCTAssertTrue(options.allSatisfy { $0.arrival > now })
    }

    func testOnlyElectricWhenNoClassicBikes() {
        let stations = [
            dock("a", Coordinate(latitude: 39.9530, longitude: -75.1640), classic: 0, electric: 1),
            dock("b", Coordinate(latitude: 39.9805, longitude: -75.1555), classic: 0, electric: 0),
        ]
        let options = IndegoPlanner().options(from: cityHall, to: temple, stations: stations, departAt: Date())
        XCTAssertEqual(options.map(\.bike), [.electric])
        XCTAssertGreaterThan(options[0].price, 0)
    }

    func testNoOptionWithoutAFreeDockNearTheDestination() {
        let stations = [
            dock("a", Coordinate(latitude: 39.9530, longitude: -75.1640), classic: 2, electric: 3),
            dock("b", Coordinate(latitude: 39.9805, longitude: -75.1555), classic: 0, electric: 0, docks: 0),
        ]
        XCTAssertTrue(IndegoPlanner().options(from: cityHall, to: temple, stations: stations, departAt: Date()).isEmpty)
    }

    func testDecodesGBFS() throws {
        let info = #"{"data":{"stations":[{"station_id":"s1","name":"One","lat":39.95,"lon":-75.16}]}}"#
        let status = #"{"data":{"stations":[{"station_id":"s1","num_bikes_available":5,"num_docks_available":7,"is_installed":1,"is_renting":1,"is_returning":1,"num_bikes_available_types":{"classic":2,"smart":1,"electric":2}}]}}"#
        let stations = try IndegoFeed.decode(information: Data(info.utf8), status: Data(status.utf8))
        XCTAssertEqual(stations.first?.classicBikes, 3)
        XCTAssertEqual(stations.first?.electricBikes, 2)
        XCTAssertEqual(stations.first?.openDocks, 7)
    }
}
