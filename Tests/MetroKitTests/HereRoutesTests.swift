import XCTest
@testable import MetroKit

final class HereRoutesTests: XCTestCase {
    /// Shaped like a HERE Routing v8 response with return=summary,tolls,
    /// tolls[summaries]=total and spans=functionalClass,length,names.
    private let sample = #"""
    {"routes":[
      {"id":"a","sections":[{"id":"s","type":"vehicle",
        "summary":{"duration":1500,"length":20000,"baseDuration":1300,
                   "tolls":{"total":{"type":"value","currency":"USD","value":6.0}}},
        "spans":[{"offset":0,"length":5000,"functionalClass":4,"names":[{"value":"Market St","language":"en"}]},
                 {"offset":40,"length":15000,"functionalClass":1,"names":[{"value":"I-76","language":"en"}]}]}]},
      {"id":"b","sections":[{"id":"t","type":"vehicle",
        "summary":{"duration":1800,"length":18000,"baseDuration":1600},
        "spans":[{"offset":0,"length":18000,"functionalClass":3,"names":[{"value":"Ridge Ave","language":"en"}]}]}]}
    ]}
    """#

    func testDecodesTollsHighwayShareAndName() throws {
        let routes = try XCTUnwrap(HereRoutes.decode(Data(sample.utf8)))
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].toll, 6.0)
        XCTAssertEqual(routes[0].tollCurrency, "USD")
        XCTAssertEqual(routes[0].highwayMeters, 15000)
        XCTAssertEqual(routes[0].name, "I-76")
        XCTAssertEqual(routes[1].toll, 0)
        XCTAssertEqual(routes[1].highwayMeters, 0)
        XCTAssertEqual(routes[1].seconds, 1800)
    }

    func testGarbageIsNil() {
        XCTAssertNil(HereRoutes.decode(Data("{\"error\":\"Unauthorized\"}".utf8)))
    }
}
