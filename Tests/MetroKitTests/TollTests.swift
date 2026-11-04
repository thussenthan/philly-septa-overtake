import XCTest
@testable import MetroKit

final class TollTests: XCTestCase {
    // Either end of the Ben Franklin Bridge, as one straight segment.
    private let camden = Coordinate(latitude: 39.9480, longitude: -75.1190)
    private let philly = Coordinate(latitude: 39.9560, longitude: -75.1450)

    func testBridgeChargedIntoPennsylvaniaOnly() {
        let west = Tolls.charges(path: [camden, philly], steps: [])
        XCTAssertEqual(west.map(\.name), ["Ben Franklin Bridge"])
        XCTAssertEqual(west.first?.amount, 6)
        XCTAssertTrue(Tolls.charges(path: [philly, camden], steps: []).isEmpty)
    }

    func testRouteNowhereNearABridgePaysNothing() {
        let cityHall = Coordinate(latitude: 39.9524, longitude: -75.1636)
        let temple = Coordinate(latitude: 39.9812, longitude: -75.1550)
        XCTAssertTrue(Tolls.charges(path: [cityHall, temple], steps: []).isEmpty)
    }

    func testTurnpikeChargedByTheMile() {
        let steps = [
            Tolls.Step(instructions: "Merge onto I-276 E / Pennsylvania Turnpike", meters: 10 * Coordinate.metersPerMile),
            Tolls.Step(instructions: "Take exit 351 toward US-1", meters: 800),
        ]
        let charges = Tolls.charges(path: [], steps: steps)
        XCTAssertEqual(charges.map(\.name), ["Pennsylvania Turnpike"])
        XCTAssertEqual(charges.first?.amount ?? 0, 1.60, accuracy: 0.001)
    }

    func testFreeExpresswaysAreNotTolled() {
        let steps = [Tolls.Step(instructions: "Merge onto I-76 W / Schuylkill Expy", meters: 8000),
                     Tolls.Step(instructions: "Continue onto I-476 S / Blue Route", meters: 8000)]
        XCTAssertTrue(Tolls.charges(path: [], steps: steps).isEmpty)
    }
}
