import XCTest
@testable import MetroKit

final class CoordinateParseTests: XCTestCase {
    func testPlainPairs() {
        for s in ["39.971485, -75.159465", "39.971485 -75.159465", "(39.971485,-75.159465)"] {
            let c = Coordinate.parse(s)
            XCTAssertEqual(c?.latitude ?? 0, 39.971485, accuracy: 1e-6, s)
            XCTAssertEqual(c?.longitude ?? 0, -75.159465, accuracy: 1e-6, s)
        }
    }
    func testHemispheres() {
        let c = Coordinate.parse("39.9715°N 75.1595°W")
        XCTAssertEqual(c?.latitude ?? 0, 39.9715, accuracy: 1e-6)
        XCTAssertEqual(c?.longitude ?? 0, -75.1595, accuracy: 1e-6)
    }
    func testLongitudeFirst() {
        let c = Coordinate.parse("-75.159465, 39.971485")
        XCTAssertEqual(c?.latitude ?? 0, 39.971485, accuracy: 1e-6)
        XCTAssertEqual(c?.longitude ?? 0, -75.159465, accuracy: 1e-6)
    }
    func testAddressesAndWordsAreNotCoordinates() {
        for s in ["1500 Market St", "1500 2000", "aldi", "Trader Joe's 2121 Market", "39.97", "", "95.5, 20.1 x"] {
            XCTAssertNil(Coordinate.parse(s), s)
        }
    }
}
