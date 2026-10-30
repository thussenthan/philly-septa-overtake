import XCTest
@testable import MetroKit

/// Decoding SEPTA's alerts endpoint.
///
/// The fixture below is the real shape, trimmed: keys, spellings and value
/// conventions are copied from a live response, including the ones that look like
/// mistakes. `isadvisory` really is "Yes"/"No" while every neighbouring flag is
/// "Y"/"N", and the subway lines really are filed under `rr_route_*` next to
/// Regional Rail. A decoder written against a tidied-up version of this would work
/// perfectly in tests and return nothing on a phone.
final class AlertsFeedTests: XCTestCase {

    private let fetchedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func decode(_ json: String) throws -> AlertDigest {
        try AlertsFeed.decode(Data(json.utf8), fetchedAt: fetchedAt)
    }

    private func digest() throws -> AlertDigest {
        try decode(Self.fixture)
    }

    // MARK: - What gets through

    func testRoutesTheAppCannotPlanOverAreDropped() throws {
        let digest = try digest()
        // The fixture carries a bus detour, a Regional Rail advisory, a CCT entry
        // and the mobile-app notice. None of them can change which train to catch.
        XCTAssertFalse(
            digest.alerts.contains { $0.routeName == "1" || $0.routeName == "Airport" || $0.routeName == "CCT" },
            "unmodelled routes leaked in: \(digest.alerts.map(\.routeName))"
        )
    }

    func testSubwayAndTrolleyRouteIDsMapToLines() throws {
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "rr_route_bsl"), .line("B"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "rr_route_bso"), .line("B-OWL"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "rr_route_mfl"), .line("L"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "rr_route_nhsl"), .line("M"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "trolley_route_34"), .line("T"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "trolley_route_101"), .line("D"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "bus_route_15"), .line("G"))
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "generic"), .system)
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "bus_route_17"), .unmodelled)
        XCTAssertEqual(AlertsFeed.scope(forRouteID: "rr_route_pao"), .unmodelled)
    }

    /// Every line the mapping claims must actually exist in the bundled data —
    /// otherwise an alert arrives tagged with a line the app can't name or colour.
    func testEveryMappedLineExistsInTheNetwork() {
        for (routeID, scope) in AlertsFeed.scopesByRouteID {
            guard case .line(let lineID) = scope else { continue }
            // Route 15's trolley spelling is kept for the day SEPTA restores it, so
            // it is allowed to point at the same line as the bus spelling.
            XCTAssertNotNil(
                SEPTAData.network.line(lineID),
                "\(routeID) maps to \(lineID), which isn't in the bundled network"
            )
        }
    }

    func testSystemWideNoticesHaveNoLine() throws {
        let systemAlerts = try digest().alerts.filter(\.appliesToWholeSystem)
        XCTAssertEqual(systemAlerts.count, 1)
        XCTAssertEqual(systemAlerts.first?.message, "Fares change on September 1.")
    }

    // MARK: - Flags

    /// `isadvisory` is the one flag spelled "Yes"/"No". Comparing it to "Y" would
    /// silently drop every advisory in the feed.
    func testTheDifferentlySpelledAdvisoryFlagIsHonoured() throws {
        let trolley = try digest().alerts.filter { $0.routeName == "10" }
        XCTAssertEqual(trolley.count, 1)
        XCTAssertEqual(trolley.first?.severity, .advisory)
        XCTAssertEqual(trolley.first?.lineID, "T")
    }

    func testDelaysOutrankAdvisories() throws {
        let broad = try digest().alerts.filter { $0.lineID == "B" }
        XCTAssertEqual(broad.map(\.severity), [.delay], "got \(broad.map(\.message))")
    }

    /// A suspension with no message is still worth saying. An `isalert` with no
    /// message is not — there is literally nothing to report.
    func testAFlagWithNoTextStillProducesAnAlertWhenItMatters() throws {
        let norristown = try digest().alerts.filter { $0.lineID == "M" }
        XCTAssertEqual(norristown.count, 1)
        XCTAssertEqual(norristown.first?.severity, .suspended)
        XCTAssertTrue(
            norristown.first?.message.contains("suspended") == true,
            "got \(norristown.first?.message ?? "none")"
        )

        let owl = try digest().alerts.filter { $0.lineID == "B-OWL" }
        XCTAssertTrue(owl.isEmpty, "an empty alert flag has nothing to report: \(owl.map(\.message))")
    }

    // MARK: - Text

    func testHTMLIsStrippedAndEntitiesDecoded() throws {
        let market = try digest().alerts.filter { $0.lineID == "L" && $0.severity == .detour }
        let message = try XCTUnwrap(market.first?.message)
        XCTAssertFalse(message.contains("<"), message)
        XCTAssertFalse(message.contains("&amp;"), message)
        // Decoded, not merely stripped: the ampersand survives as an ampersand.
        XCTAssertTrue(message.contains("15th & Market"), message)
        // The works order is worth appending — it is why the detour exists.
        XCTAssertTrue(message.contains("Track Work"), message)
    }

    func testWhitespaceIsCollapsedSoTagsDoNotWeldWordsTogether() {
        XCTAssertEqual(
            HTMLText.plain("<p>Trains are delayed</p><p>about 20 minutes.</p>"),
            "Trains are delayed about 20 minutes."
        )
        XCTAssertEqual(HTMLText.plain("Elevator&nbsp;out at 30th&#39;s north end"),
                       "Elevator out at 30th's north end")
        XCTAssertEqual(HTMLText.plain("A&#x26;B"), "A&B")
        XCTAssertEqual(HTMLText.plain("<b>Bold</b> and <i>italic</i>"), "Bold and italic")
        XCTAssertEqual(HTMLText.plain(""), "")
        XCTAssertEqual(HTMLText.plain("&#notanentity; stays"), "&#notanentity; stays")
        // An escaped entity is text, decoded exactly once — and the same way on every
        // launch, which a dictionary's shifting order didn't guarantee.
        XCTAssertEqual(HTMLText.plain("Write &amp;nbsp; for a space"), "Write &nbsp; for a space")
        XCTAssertEqual(HTMLText.plain("&amp;#39;"), "&#39;")
    }

    /// SEPTA occasionally pastes a whole shuttle timetable into one field. A card
    /// cannot show it and a rider will not read it there.
    func testVeryLongMessagesAreTruncatedAtAWordBoundary() {
        let long = String(repeating: "shuttle bus departs every ten minutes ", count: 40)
        let plain = HTMLText.plain(long)
        XCTAssertLessThanOrEqual(plain.count, HTMLText.maximumLength + 1)
        XCTAssertTrue(plain.hasSuffix("…"))
        XCTAssertFalse(plain.contains("  "))
    }

    // MARK: - Lookups

    func testAlertsAreFilteredToTheLinesInUseAndSortedWorstFirst() throws {
        let digest = try digest()
        let onBroad = digest.alerts(affecting: ["B"])
        XCTAssertEqual(onBroad.first?.severity, .delay)
        // System-wide notices always apply.
        XCTAssertTrue(onBroad.contains { $0.appliesToWholeSystem })
        XCTAssertFalse(onBroad.contains { $0.lineID == "L" })

        let severities = digest.alerts(affecting: ["B", "L", "T"]).map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >), "\(severities)")
    }

    /// The card shows one alert, so the one it shows must be the worst on the
    /// journey — not merely the first one SEPTA happened to publish.
    func testWorstAlertForAJourneyPicksTheHighestSeverityOnItsLines() throws {
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .station("a"),
            destination: .station("f"),
            departAt: Fixture.date(8, 1)
        ))
        let journey = try XCTUnwrap(plan.best)
        XCTAssertEqual(Set(journey.rides.map(\.lineID)), [Fixture.lineID], "fixture rides the T")

        let digest = AlertDigest(
            alerts: [
                ServiceAlert(lineID: "T", severity: .advisory, message: "Minor thing", routeName: "10"),
                ServiceAlert(lineID: "T", severity: .modifiedService, message: "Bussed west of 40th", routeName: "34"),
                ServiceAlert(lineID: "B", severity: .suspended, message: "No service", routeName: "Broad Street Line"),
            ],
            fetchedAt: fetchedAt
        )
        let worst = try XCTUnwrap(digest.worstAlert(for: journey))
        XCTAssertEqual(worst.severity, .modifiedService)
        XCTAssertEqual(worst.message, "Bussed west of 40th")
    }

    func testAWalkOnlyJourneyHasNoAlert() throws {
        // Coordinates rather than stations: a walk-only option only exists between
        // two points on the map. And 23:30, when the fixture line has stopped.
        let plan = Fixture.planner().plan(PlanRequest(
            origin: .place(name: "A St", coordinate: Fixture.coordinate(of: "a")),
            destination: .place(name: "B St", coordinate: Fixture.coordinate(of: "b")),
            departAt: Fixture.date(23, 30)
        ))
        let journey = try XCTUnwrap(plan.journeys.first { $0.isWalkOnly })
        let digest = AlertDigest(
            alerts: [ServiceAlert(lineID: "T", severity: .suspended, message: "No service", routeName: "10")],
            fetchedAt: fetchedAt
        )
        XCTAssertNil(digest.worstAlert(for: journey))
    }

    // MARK: - Bad input

    func testAnUnexpectedShapeThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try decode("{\"error\":\"nope\"}"))
        XCTAssertThrowsError(try decode("not json at all"))
    }

    /// A renamed or missing key should cost one field, not the whole feed. This is
    /// the failure mode that matters: an app that shows no alerts looks identical to
    /// an app with nothing to report.
    func testMissingAndRetypedFieldsDegradeToDroppingThatField() throws {
        let odd = """
        [{"route_id":"rr_route_bsl","route_name":"Broad Street Line","mode":"Broad Street Line",
          "isadvisory":"No","isdelays":"Y","alert":"Delays southbound.","advisory":"",
          "detour":"","last_updated":null}]
        """
        let digest = try decode(odd)
        XCTAssertEqual(digest.alerts.count, 1)
        XCTAssertEqual(digest.alerts.first?.severity, .delay)
        XCTAssertEqual(digest.alerts.first?.message, "Delays southbound.")
        XCTAssertNil(digest.alerts.first?.lastUpdated)
    }

    func testIdenticalAlertsAreReportedOnce() throws {
        // The five subway-surface trolleys share one line, and SEPTA repeats a
        // corridor-wide notice on each of them.
        let repeated = """
        [{"route_id":"trolley_route_10","route_name":"10","mode":"Trolley","isadvisory":"Yes",
          "advisory":"Detour in place through Friday.","alert":"","detour":[]},
         {"route_id":"trolley_route_13","route_name":"10","mode":"Trolley","isadvisory":"Yes",
          "advisory":"Detour in place through Friday.","alert":"","detour":[]}]
        """
        XCTAssertEqual(try decode(repeated).alerts.count, 1)
    }

    func testAnEmptyFeedIsNotAnError() throws {
        let digest = try decode("[]")
        XCTAssertTrue(digest.alerts.isEmpty)
        XCTAssertEqual(digest.fetchedAt, fetchedAt)
    }

    // MARK: - Fixture

    /// Trimmed from a live response. Field names, flag spellings and the nesting of
    /// `detour` are unchanged.
    private static let fixture = """
    [
      {"route":"APP","route_id":"APP","route_name":"Mobile APP","sequence":"0","mode":"Mobile",
       "isadvisory":"No","isdetour":"N","isalert":"N","iselevator":"N","issuspended":"N",
       "isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N","isdetouralert":"N",
       "last_updated":"Jul 26 2023 11:45AM","isSnow":"N","description":"Mobile App Only",
       "alert":"","advisory":"","detour":[],"elevator":[]},

      {"route":"SYS","route_id":"generic","route_name":"Generic","sequence":"0","mode":"generic",
       "isadvisory":"No","isdetour":"N","isalert":"Y","iselevator":"N","issuspended":"N",
       "isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N","isdetouralert":"N",
       "last_updated":"Aug  1 2026 11:29AM","isSnow":"N","description":"Alert for the entire SEPTA system.",
       "alert":"<p>Fares change on September 1.</p>","advisory":"","detour":[],"elevator":[]},

      {"route":"1","route_id":"bus_route_1","route_name":"1","sequence":"1001","mode":"Bus",
       "isadvisory":"No","isdetour":"Y","isalert":"N","iselevator":"N","issuspended":"N",
       "isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N","isdetouralert":"N",
       "last_updated":"May 30 2023  9:36AM","isSnow":"N","description":"Parx Casino to 54th-City",
       "alert":"","advisory":"",
       "detour":[{"location_start":"Naple St & Fance St","location_end":"Naple St & Fance St",
                  "start":"7/31/2026  10:38 AM","end":"10/2/2026   4:30 AM",
                  "message":"Discontinued transit stop, Naple St & Fance St",
                  "reason":"Crossover Reconstruction Project"}],
       "elevator":[]},

      {"route":"BSL","route_id":"rr_route_bsl","route_name":"Broad Street Line","sequence":"0",
       "mode":"Broad Street Line","isadvisory":"Yes","isdetour":"N","isalert":"N","iselevator":"N",
       "issuspended":"N","isstrike":"N","ismodifiedservice":"N","isdelays":"Y","isdiversion":"N",
       "isdetouralert":"N","last_updated":"Aug  4 2026  7:12AM","isSnow":"N",
       "description":"Fern Rock to NRG",
       "alert":"<p>Southbound trains are operating with 10 minute delays.</p>",
       "advisory":"","detour":[],"elevator":[]},

      {"route":"BSO","route_id":"rr_route_bso","route_name":"Broad Street Line Owl","sequence":"0",
       "mode":"Broad Street Line","isadvisory":"No","isdetour":"N","isalert":"Y","iselevator":"N",
       "issuspended":"N","isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N",
       "isdetouralert":"N","last_updated":"Aug  4 2026  7:12AM","isSnow":"N",
       "description":"Owl service","alert":"","advisory":"","detour":[],"elevator":[]},

      {"route":"MFL","route_id":"rr_route_mfl","route_name":"Market/Frankford Line","sequence":"0",
       "mode":"Market/ Frankford","isadvisory":"No","isdetour":"Y","isalert":"N","iselevator":"N",
       "issuspended":"N","isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N",
       "isdetouralert":"N","last_updated":"Aug  3 2026  4:05PM","isSnow":"N",
       "description":"69th St to Frankford","alert":"","advisory":"",
       "detour":[{"location_start":"15th &amp; Market","location_end":"30th &amp; Market",
                  "start":"8/3/2026   9:00 PM","end":"8/5/2026   5:00 AM",
                  "message":"<p>Shuttle buses replace trains between 15th &amp; Market and 30th &amp; Market.</p>",
                  "reason":"Track Work"}],
       "elevator":[]},

      {"route":"NHSL","route_id":"rr_route_nhsl","route_name":"Norristown High Speed Line",
       "sequence":"0","mode":"Norristown High Speed Line","isadvisory":"No","isdetour":"N",
       "isalert":"N","iselevator":"N","issuspended":"Y","isstrike":"N","ismodifiedservice":"N",
       "isdelays":"N","isdiversion":"N","isdetouralert":"N","last_updated":"Aug  4 2026  6:02AM",
       "isSnow":"N","description":"69th St to Norristown","alert":"","advisory":"",
       "detour":[],"elevator":[]},

      {"route":"10","route_id":"trolley_route_10","route_name":"10","sequence":"1010",
       "mode":"Trolley","isadvisory":"Yes","isdetour":"N","isalert":"N","iselevator":"N",
       "issuspended":"N","isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N",
       "isdetouralert":"N","last_updated":"Aug  2 2026  8:00AM","isSnow":"N",
       "description":"13th-Market to 63rd-Malvern","alert":"",
       "advisory":"<p>Boarding at street level at 40th St.</p>","detour":[],"elevator":[]},

      {"route":"AIR","route_id":"rr_route_apt","route_name":"Airport","sequence":"0",
       "mode":"Regional Rail","isadvisory":"Yes","isdetour":"N","isalert":"N","iselevator":"Y",
       "issuspended":"N","isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N",
       "isdetouralert":"N","last_updated":"Aug  4 2026  5:00AM","isSnow":"N",
       "description":"Airport Line","alert":"","advisory":"<p>Weekend schedule in effect.</p>",
       "detour":[],"elevator":[]},

      {"route":"CCT","route_id":"cct","route_name":"CCT","sequence":"0","mode":"CCT",
       "isadvisory":"No","isdetour":"N","isalert":"N","iselevator":"N","issuspended":"N",
       "isstrike":"N","ismodifiedservice":"N","isdelays":"N","isdiversion":"N","isdetouralert":"N",
       "last_updated":"Aug  1 2023 11:29AM","isSnow":"N","description":"CCT Connect",
       "alert":"","advisory":"","detour":[],"elevator":[]}
    ]
    """
}
