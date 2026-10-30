import XCTest
@testable import MetroKit

/// Knowing when the bundled timetable has actually gone off.
///
/// This is the one piece of the app that has to be *reluctant*. Every other warning
/// costs a rider a glance; this one costs them their trust in all the others, because
/// SEPTA's feed declares a fortnight of validity while its rail timetables change a
/// few times a year. Warn on the declared window and the app spends most of its life
/// insisting it is out of date while being perfectly correct.
final class ScheduleFreshnessTests: XCTestCase {

    // MARK: - Two windows, two meanings

    private func provenance(validUntil: String, servicesUntil: String?) -> DataProvenance {
        DataProvenance(
            fidelity: .official,
            source: "test",
            generated: "2026-08-06",
            validUntil: validUntil,
            servicesUntil: servicesUntil
        )
    }

    private func easternNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ServiceCalendar.easternTimeZone
        return calendar.date(from: components)!
    }

    /// SEPTA's real shape, from the feed this build was made with: authoritative to
    /// 8 August, advisory service data to 22 August.
    func testPastTheConfirmedWindowIsNotTheSameAsOutOfData() {
        let feed = provenance(validUntil: "20260808", servicesUntil: "20260822")

        let inside = easternNoon(2026, 8, 6)
        XCTAssertFalse(feed.isStale(asOf: inside))
        XCTAssertFalse(feed.hasNoServiceData(asOf: inside))

        // Between the two: SEPTA's own advisory times. Worth saying, not worth alarm.
        let advisory = easternNoon(2026, 8, 15)
        XCTAssertTrue(feed.isStale(asOf: advisory), "past what SEPTA confirms")
        XCTAssertFalse(feed.hasNoServiceData(asOf: advisory), "but there is still a timetable here")

        // Past both: nothing left to route on.
        let empty = easternNoon(2026, 8, 25)
        XCTAssertTrue(feed.isStale(asOf: empty))
        XCTAssertTrue(feed.hasNoServiceData(asOf: empty))
    }

    /// Service on the last date runs into the small hours, so the night bus at 1am on
    /// the 23rd is still data the feed has, not data it lacks.
    func testTheLastServiceDayRunsPastMidnight() {
        let feed = provenance(validUntil: "20260808", servicesUntil: "20260822")
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 23; components.hour = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ServiceCalendar.easternTimeZone
        XCTAssertFalse(feed.hasNoServiceData(asOf: calendar.date(from: components)!))
    }

    /// A blob generated before the advisory window was recorded has to keep working,
    /// and must err towards warning rather than towards routing on absent data.
    func testWithoutAnAdvisoryWindowTheConfirmedOneIsUsed() {
        let feed = provenance(validUntil: "20260808", servicesUntil: nil)
        XCTAssertTrue(feed.hasNoServiceData(asOf: easternNoon(2026, 8, 15)))
    }

    /// The shipped data really does carry both, or the distinction above is theory.
    ///
    /// The advisory window can only end on or after the confirmed one — a feed that
    /// publishes no extra advisory times, like the current sixteen-week one, ends
    /// both on the same day — so it is the ordering that is worth pinning, not a gap.
    func testTheBundledFeedDeclaresBothWindows() throws {
        let provenance = SEPTAData.network.provenance
        let confirmed = try XCTUnwrap(provenance.validUntil)
        let services = try XCTUnwrap(provenance.servicesUntil, "the generator must emit the advisory end")
        XCTAssertGreaterThanOrEqual(services, confirmed, "advisory data can't end before the confirmed window does")
    }

    // MARK: - Has SEPTA published a newer one?

    func testANewerFeedSupersedesTheBundledOne() {
        XCTAssertTrue(ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: "v202608091"))
        XCTAssertTrue(ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: "v202607262"),
                      "a second revision on the same day is still newer")
    }

    func testTheSameOrAnOlderFeedDoesNot() {
        XCTAssertFalse(ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: "v202607261"))
        XCTAssertFalse(ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: "v202607120"))
    }

    /// The failure that actually matters. If SEPTA ever tags a release in some other
    /// shape, a string comparison would answer arbitrarily — and answering "newer"
    /// arbitrarily means telling every rider every day to update an app that is fine.
    /// Silence is the correct answer to a question that wasn't understood.
    func testAnUnrecognisedVersionIsNeverTreatedAsNewer() {
        // The last two look like digits and are not ASCII ones — `isNumber` alone
        // would wave them through, and then compare them by Unicode order.
        for remote in ["2026-08-09", "latest", "", "v2026", "V202608091", "release-9",
                       "v20260809x", "v٢٠٢٦٠٨٠٩١", "v20260809½"] {
            XCTAssertFalse(
                ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: remote),
                "\(remote) is not a feed version and must not trigger an update notice"
            )
        }
        XCTAssertFalse(ScheduleFreshness.isSuperseded(bundled: "nonsense", remote: "v202608091"),
                       "an unparseable bundled version is just as disqualifying")
    }

    func testFeedVersionShape() {
        XCTAssertTrue(ScheduleFreshness.isFeedVersion("v202607261"))
        XCTAssertFalse(ScheduleFreshness.isFeedVersion("v20260726"), "nine digits, not eight")
        XCTAssertFalse(ScheduleFreshness.isFeedVersion("x202607261"))
    }

    /// Surrounding whitespace is the kind of thing a tag picks up in transit.
    func testVersionsAreTrimmedBeforeComparing() {
        XCTAssertTrue(ScheduleFreshness.isSuperseded(bundled: "v202607261", remote: "  v202608091\n"))
    }

    // MARK: - Reading the release

    func testTheVersionIsReadFromTheReleasePayload() throws {
        let json = Data(#"{"tag_name":"v202608091","name":"whatever","draft":false}"#.utf8)
        XCTAssertEqual(ScheduleFreshness.version(fromReleasesJSON: json), "v202608091")
    }

    /// A changed payload must be a shrug, not a crash inside a background refresh.
    func testAnUnexpectedPayloadIsNil() {
        for body in [#"{"tag":"v1"}"#, "[]", "not json", "", #"{"tag_name":""}"#] {
            XCTAssertNil(ScheduleFreshness.version(fromReleasesJSON: Data(body.utf8)), body)
        }
    }
}
