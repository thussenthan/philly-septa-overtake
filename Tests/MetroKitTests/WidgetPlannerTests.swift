import XCTest
@testable import MetroKit

/// The widget's timeline. Everything asserted here happens inside an extension that
/// cannot be debugged comfortably and gets killed if it takes too long, which is
/// exactly why the logic lives in `MetroKit` and is tested from the command line.
final class WidgetPlannerTests: XCTestCase {

    private func snapshot(from: StationID = "a", to: StationID = "f") -> CommuteSnapshot {
        CommuteSnapshot(
            origin: SnapshotEndpoint(.station(from), name: from.rawValue.uppercased()),
            destination: SnapshotEndpoint(.station(to), name: to.rawValue.uppercased()),
            reason: "Heading home",
            savedAt: Fixture.date(8, 0)
        )
    }

    private func steps(at hour: Int, _ minute: Int, limit: Int = 4) -> [WidgetPlanStep] {
        WidgetPlanner.steps(
            for: snapshot(),
            from: Fixture.date(hour, minute),
            limit: limit,
            network: Fixture.network,
            options: widgetOptions()
        )
    }

    /// The fixture's geometry is only meaningful with the walking fuzz removed, the
    /// same way `Fixture.planner()` does it.
    private func widgetOptions() -> PlannerOptions {
        var options = WidgetPlanner.options()
        options.walking.startupSeconds = 0
        options.walking.stationEntrySeconds = 0
        options.walking.stationExitSeconds = 0
        options.boardingBufferSeconds = 0
        options.minTransferSeconds = 60
        return options
    }

    // MARK: - Timeline shape

    /// The point of the whole design: each entry begins exactly when the option the
    /// previous one recommended stops being catchable. Anything else is either a
    /// stale answer on the home screen or a refresh budget spent saying nothing.
    func testEachEntryBeginsWhenThePreviousOptionBecomesUncatchable() throws {
        let steps = self.steps(at: 8, 1)
        XCTAssertGreaterThan(steps.count, 1, "expected a rolling timeline")

        for (previous, next) in zip(steps, steps.dropFirst()) {
            XCTAssertGreaterThan(next.validFrom, previous.leaveBy, "next entry must start after the deadline it replaces")
            XCTAssertEqual(next.validFrom.timeIntervalSince(previous.leaveBy), 1, accuracy: 60)
            XCTAssertGreaterThan(next.leaveBy, previous.leaveBy, "each entry must recommend a later train")
        }
    }

    func testEveryEntryIsStillCatchableWhenItTakesOver() throws {
        for step in steps(at: 8, 1) {
            XCTAssertGreaterThanOrEqual(
                step.leaveBy, step.validFrom,
                "an entry that is already too late to act on is worse than no widget"
            )
            XCTAssertGreaterThan(step.arrival, step.validFrom)
        }
    }

    func testTheFirstEntryMatchesWhatTheAppWouldRecommend() throws {
        let now = Fixture.date(8, 1)
        let step = try XCTUnwrap(steps(at: 8, 1).first)

        // The same planner the widget builds — default calendar included, so this is
        // comparing the two paths and not two different service calendars.
        let plan = JourneyPlanner(network: Fixture.network, options: widgetOptions())
            .plan(PlanRequest(origin: .station("a"), destination: .station("f"), departAt: now))
        let best = try XCTUnwrap(plan.best)

        XCTAssertEqual(step.leaveBy, best.urgency.leaveBy)
        XCTAssertEqual(step.arrival, best.arrivalTime)
        XCTAssertEqual(step.title, JourneyNarrator(network: Fixture.network).summary(for: best).title)
        XCTAssertEqual(step.lines.map(\.badge), ["T"])
    }

    func testTheLimitIsRespected() {
        XCTAssertEqual(steps(at: 8, 1, limit: 2).count, 2)
        XCTAssertLessThanOrEqual(steps(at: 8, 1, limit: 9).count, 9)
    }

    func testNoServiceProducesNoEntriesRatherThanAnEmptyAnswer() {
        // 23:30, long after the fixture line has stopped, between two stations —
        // so there is no walk-only option to fall back on either.
        XCTAssertTrue(steps(at: 23, 30).isEmpty)
    }

    /// A walk has no train to miss, so there is no later entry to schedule. Emitting
    /// one would mean the widget re-planning against a deadline that doesn't exist.
    func testAWalkOnlyAnswerEndsTheTimeline() {
        let walk = CommuteSnapshot(
            origin: SnapshotEndpoint(name: "A St", latitude: Fixture.coordinate(of: "a").latitude,
                                     longitude: Fixture.coordinate(of: "a").longitude),
            destination: SnapshotEndpoint(name: "B St", latitude: Fixture.coordinate(of: "b").latitude,
                                          longitude: Fixture.coordinate(of: "b").longitude),
            savedAt: Fixture.date(23, 30)
        )
        let steps = WidgetPlanner.steps(
            for: walk,
            from: Fixture.date(23, 30),
            network: Fixture.network,
            options: widgetOptions()
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(steps[0].isWalkOnly)
    }

    func testAnUnusableSnapshotProducesNothing() {
        let broken = CommuteSnapshot(
            origin: SnapshotEndpoint(name: "Somewhere"),   // no station, no coordinate
            destination: SnapshotEndpoint(.station("f"), name: "F"),
            savedAt: Fixture.date(8, 0)
        )
        XCTAssertTrue(WidgetPlanner.steps(for: broken, from: Fixture.date(8, 0), network: Fixture.network).isEmpty)
    }

    // MARK: - What the entry says

    /// The widget states the *cost* of missing the train, never "run" — whether to
    /// run depends on how much time is left, and a timeline entry rendered ten
    /// minutes after it was computed cannot know that.
    func testThePenaltyIsStatedOnlyWhenItIsWorthStating() throws {
        let steps = self.steps(at: 8, 1)
        // 08:01: the express arrives 08:08 and the next local 08:20, so missing it
        // costs twelve minutes and the widget should say so.
        XCTAssertEqual(try XCTUnwrap(steps.first).penaltyText, "Miss it: +12m")
        for step in steps {
            guard let text = step.penaltyText else { continue }
            XCTAssertTrue(text.hasPrefix("Miss it: +"), text)
            XCTAssertFalse(text.lowercased().contains("run"), "urgency can't be baked into an entry: \(text)")
        }
    }

    func testTheNextBestArrivalIsCarriedForComparison() throws {
        // At 08:01 both the express and the following local are live options.
        let step = try XCTUnwrap(steps(at: 8, 1).first)
        let next = try XCTUnwrap(step.nextArrival)
        XCTAssertGreaterThan(next, step.arrival, "the alternative should be the slower one")
    }

    // MARK: - The shared record

    func testEndpointsSurviveTheRoundTrip() throws {
        let station = SnapshotEndpoint(.station("erie"), name: "Erie")
        XCTAssertEqual(station.endpoint, .station("erie"))

        let place = SnapshotEndpoint(
            .place(name: "Home", coordinate: Coordinate(latitude: 39.98, longitude: -75.15)),
            name: "Home"
        )
        guard case .place(let name, let coordinate) = try XCTUnwrap(place.endpoint) else {
            return XCTFail("expected a place")
        }
        XCTAssertEqual(name, "Home")
        XCTAssertEqual(coordinate.latitude, 39.98, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, -75.15, accuracy: 0.000001)
    }

    func testSnapshotsEncodeAndDecode() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CommuteSnapshot.self, from: data), original)
    }

    /// The app replans every thirty seconds. Reloading the widget each time would
    /// spend its refresh budget re-answering the same question.
    func testSavingReportsWhetherTheTripActuallyChanged() throws {
        let defaults = UserDefaults(suiteName: "widget-planner-tests")!
        defaults.removePersistentDomain(forName: "widget-planner-tests")

        XCTAssertTrue(SharedStore.save(snapshot(), to: defaults), "first write is a change")

        var later = snapshot()
        later.savedAt = Fixture.date(9, 30)
        XCTAssertFalse(SharedStore.save(later, to: defaults), "same trip, new clock reading")

        XCTAssertTrue(
            SharedStore.save(snapshot(to: "e"), to: defaults),
            "a different destination is a different question"
        )
        XCTAssertEqual(SharedStore.snapshot(from: defaults)?.destination.stationID, "e")
        defaults.removePersistentDomain(forName: "widget-planner-tests")
    }
}
