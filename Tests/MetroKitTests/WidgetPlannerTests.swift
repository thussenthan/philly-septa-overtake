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
        // The route, not the line: at 08:01 the express wins, and "T2" is what a
        // rider matches against the platform sign.
        XCTAssertEqual(step.lines.map(\.badge), ["T2"])
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

    // MARK: - Which way the rider is facing

    /// The reason the widget is worth having: it works out its own direction, so it
    /// is right without the app being opened and without a location fix, neither of
    /// which a widget can rely on.
    func testTheCommuteFlipsAtMidday() throws {
        let home = SnapshotEndpoint(.station("a"), name: "Home")
        let away = SnapshotEndpoint(.station("f"), name: "School")
        // The stale one-off the app last happened to plan, which must not win.
        let snapshot = CommuteSnapshot(
            origin: SnapshotEndpoint(.station("c"), name: "C"),
            destination: SnapshotEndpoint(.station("e"), name: "E"),
            savedAt: Fixture.date(8, 0),
            commute: SavedCommute(home: home, away: away)
        )

        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = ServiceCalendar.easternTimeZone

        let morning = snapshot.trip(at: Fixture.date(8, 0), calendar: eastern)
        XCTAssertEqual(morning.origin.name, "Home")
        XCTAssertEqual(morning.destination.name, "School")

        let evening = snapshot.trip(at: Fixture.date(17, 30), calendar: eastern)
        XCTAssertEqual(evening.origin.name, "School")
        XCTAssertEqual(evening.destination.name, "Home", "the commute, not Sunday's lookup")

        // Right at the turnaround, and the minute before it.
        XCTAssertEqual(snapshot.trip(at: Fixture.date(11, 59), calendar: eastern).destination.name, "School")
        XCTAssertEqual(snapshot.trip(at: Fixture.date(12, 0), calendar: eastern).destination.name, "Home")
    }

    /// With no anchors saved there is nothing to flip, so the last planned trip is
    /// all there is — and it is better than an empty widget.
    func testWithoutACommuteTheLastTripIsUsed() {
        let snapshot = CommuteSnapshot(
            origin: SnapshotEndpoint(.station("a"), name: "A"),
            destination: SnapshotEndpoint(.station("f"), name: "F"),
            savedAt: Fixture.date(8, 0)
        )
        for hour in [8, 17] {
            let trip = snapshot.trip(at: Fixture.date(hour, 0))
            XCTAssertEqual(trip.origin.name, "A")
            XCTAssertEqual(trip.destination.name, "F")
        }
    }

    /// The planner has to resolve the direction per moment too, or an evening
    /// timeline would be planning the morning's trip.
    func testTheTimelineUsesTheDirectionForItsOwnMoment() throws {
        let snapshot = CommuteSnapshot(
            origin: SnapshotEndpoint(.station("a"), name: "A"),
            destination: SnapshotEndpoint(.station("f"), name: "F"),
            savedAt: Fixture.date(8, 0),
            commute: SavedCommute(
                home: SnapshotEndpoint(.station("f"), name: "Home"),
                away: SnapshotEndpoint(.station("a"), name: "School")
            )
        )
        // 08:01 is outbound: home is F, so the widget should be planning F -> A,
        // which on this fixture is the northbound local.
        let steps = WidgetPlanner.steps(
            for: snapshot,
            from: Fixture.date(8, 1),
            network: Fixture.network,
            options: widgetOptions()
        )
        let first = try XCTUnwrap(steps.first)
        XCTAssertEqual(first.lines.map(\.badge), ["T1"], "northbound local, not the southbound express")
    }

    /// A moved house has to reach the widget; a replan that changes nothing must not.
    func testChangingAnAnchorCountsAsAChangedTrip() {
        let base = CommuteSnapshot(
            origin: SnapshotEndpoint(.station("a"), name: "A"),
            destination: SnapshotEndpoint(.station("f"), name: "F"),
            savedAt: Fixture.date(8, 0),
            commute: SavedCommute(
                home: SnapshotEndpoint(.station("a"), name: "Home"),
                away: SnapshotEndpoint(.station("f"), name: "School")
            )
        )
        var moved = base
        moved.commute = SavedCommute(
            home: SnapshotEndpoint(.station("b"), name: "Home"),
            away: SnapshotEndpoint(.station("f"), name: "School")
        )
        XCTAssertFalse(moved.describesSameTrip(as: base), "a new home address is a new trip")

        var restamped = base
        restamped.savedAt = Fixture.date(9, 30)
        XCTAssertTrue(restamped.describesSameTrip(as: base), "same trip, new clock reading")
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

    // MARK: - Which way the rider is facing

    /// One home, one school, and a coordinate to measure from: the rule is distance,
    /// not the hour. Inside a mile of home the rider is setting out; anywhere else
    /// they are heading back.
    private func commuteWithFix(
        metersFromHome: Double,
        takenAt: Date = Fixture.date(8, 0),
        age: TimeInterval = 0
    ) -> SavedCommute {
        let home = Coordinate(latitude: 40.0, longitude: -75.16)
        // Shift east so the offset is a pure distance.
        let degrees = metersFromHome / (111_320 * cos(home.latitude * .pi / 180))
        return SavedCommute(
            home: SnapshotEndpoint(
                .place(name: "Home", coordinate: home),
                name: "Home"
            ),
            away: SnapshotEndpoint(
                .place(name: "School", coordinate: Coordinate(latitude: 39.98, longitude: -75.16)),
                name: "School"
            ),
            lastFix: LocationFix(
                Coordinate(latitude: home.latitude, longitude: home.longitude + degrees),
                at: takenAt.addingTimeInterval(-age)
            )
        )
    }

    func testNearHomeMeansHeadingOutWhateverTheClockSays() {
        // Half past three in the afternoon: the clock would send them home.
        let afternoon = Fixture.date(15, 30)
        XCTAssertTrue(
            commuteWithFix(metersFromHome: 400, takenAt: afternoon).outbound(at: afternoon, calendar: eastern),
            "within a mile of home is outbound"
        )
        let morning = Fixture.date(8, 0)
        XCTAssertTrue(
            commuteWithFix(metersFromHome: 400, takenAt: morning).outbound(at: morning, calendar: eastern)
        )
    }

    func testAwayFromHomeMeansHeadingHomeWhateverTheClockSays() {
        // Eight in the morning: the clock would send them out.
        let morning = Fixture.date(8, 0)
        XCTAssertFalse(
            commuteWithFix(metersFromHome: 4_000, takenAt: morning).outbound(at: morning, calendar: eastern),
            "outside the mile is homeward"
        )
        let afternoon = Fixture.date(15, 30)
        XCTAssertFalse(
            commuteWithFix(metersFromHome: 4_000, takenAt: afternoon).outbound(at: afternoon, calendar: eastern)
        )
    }

    /// The boundary itself, from both sides. A mile is 1609.34 m.
    func testTheMileIsTheBoundary() {
        let afternoon = Fixture.date(15, 30)
        XCTAssertTrue(
            commuteWithFix(metersFromHome: 1_500, takenAt: afternoon).outbound(at: afternoon, calendar: eastern)
        )
        XCTAssertFalse(
            commuteWithFix(metersFromHome: 1_700, takenAt: afternoon).outbound(at: afternoon, calendar: eastern)
        )
    }

    /// A fix from this morning says nothing about where the rider is this afternoon,
    /// and acting on it would offer the trip *to* work to someone already at work.
    func testAStaleFixFallsBackToTheClock() {
        let stale = commuteWithFix(metersFromHome: 400, age: 6 * 3600)
        XCTAssertFalse(
            stale.outbound(at: Fixture.date(15, 30), calendar: eastern),
            "too old to trust; the clock says homeward"
        )
        XCTAssertTrue(stale.outbound(at: Fixture.date(8, 0), calendar: eastern), "the clock says outbound")
    }

    /// With no fix at all — a rider who has never granted location — the clock is all
    /// there is, and the widget still has to point somewhere.
    func testWithoutAFixTheClockDecides() {
        var commute = commuteWithFix(metersFromHome: 400)
        commute.lastFix = nil
        XCTAssertTrue(commute.outbound(at: Fixture.date(8, 0), calendar: eastern))
        XCTAssertFalse(commute.outbound(at: Fixture.date(15, 30), calendar: eastern))
    }

    /// A widget hands WidgetKit entries it cannot revise, so it has to know when the
    /// direction it planned for could stop being true.
    func testTheTimelineExpiresWhenTheDirectionCould() {
        let fresh = commuteWithFix(metersFromHome: 400)
        let moment = Fixture.date(8, 0)
        // Distance is deciding, so the verdict holds exactly as long as the fix does.
        XCTAssertEqual(
            fresh.directionStableUntil(from: moment, calendar: eastern),
            moment.addingTimeInterval(SavedCommute.fixLifetime),
            "the fix was taken at this moment, so it ages out a lifetime later"
        )

        // With no fix the clock is deciding, and the clock changes its mind at noon.
        var clockOnly = fresh
        clockOnly.lastFix = nil
        XCTAssertEqual(
            clockOnly.directionStableUntil(from: moment, calendar: eastern),
            Fixture.date(12, 0)
        )
        // Past the turnaround, the next change is midnight.
        XCTAssertGreaterThan(
            clockOnly.directionStableUntil(from: Fixture.date(15, 30), calendar: eastern),
            Fixture.date(23, 59)
        )
    }

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ServiceCalendar.easternTimeZone
        return calendar
    }

    /// The fix is restamped on every replan and drifts by metres. Reloading the widget
    /// for that would spend the whole refresh budget saying nothing — but crossing the
    /// mile is the one movement it must not miss.
    func testOnlyCrossingTheMileCountsAsAChange() {
        func snapshot(with commute: SavedCommute) -> CommuteSnapshot {
            CommuteSnapshot(
                origin: SnapshotEndpoint(.station("a"), name: "A"),
                destination: SnapshotEndpoint(.station("f"), name: "F"),
                savedAt: Fixture.date(8, 0),
                commute: commute
            )
        }
        let base = snapshot(with: commuteWithFix(metersFromHome: 400))

        XCTAssertTrue(
            snapshot(with: commuteWithFix(metersFromHome: 600)).describesSameTrip(as: base),
            "walking down the street is not a new question"
        )
        XCTAssertFalse(
            snapshot(with: commuteWithFix(metersFromHome: 4_000)).describesSameTrip(as: base),
            "leaving the neighbourhood turns the trip around"
        )
        XCTAssertFalse(
            snapshot(with: commuteWithFix(metersFromHome: 400, age: 6 * 3600)).describesSameTrip(as: base),
            "a fix that has aged out is no longer answering by distance"
        )
    }

    // MARK: - The countdown

    /// The bug this fixes: the widget planned with the library defaults while the app
    /// planned with the rider's settings, so the two counted down to different minutes
    /// sitting inches apart on the same screen.
    func testTheWidgetPlansWithTheRidersSettings() throws {
        let tuning = RiderTuning(
            walkingMilesPerHour: 2.1,
            maxWalkMinutes: 25,
            boardingBufferSeconds: 90,
            allowTransfers: false,
            stepFreeOnly: true
        )
        let widget = WidgetPlanner.options(tuning: tuning)
        let app = tuning.plannerOptions()

        XCTAssertEqual(widget.walking.milesPerHour, app.walking.milesPerHour)
        XCTAssertEqual(widget.maxWalkSeconds, app.maxWalkSeconds)
        XCTAssertEqual(widget.boardingBufferSeconds, app.boardingBufferSeconds)
        XCTAssertEqual(widget.maxTransfers, app.maxTransfers)
        XCTAssertEqual(widget.requiresStepFreeAccess, app.requiresStepFreeAccess)
        XCTAssertEqual(widget.maxAccessStations, app.maxAccessStations)
    }

    /// Same tuning, same trip, same moment: the same deadline. `maxResults` is the one
    /// thing the widget narrows, and trimming a ranked list cannot change its head.
    func testTheWidgetAndTheAppAgreeOnWhenToLeave() throws {
        var tuning = RiderTuning()
        tuning.walkingMilesPerHour = 2.2
        tuning.boardingBufferSeconds = 0

        var appOptions = tuning.plannerOptions()
        appOptions.walking.startupSeconds = 0
        appOptions.walking.stationEntrySeconds = 0
        appOptions.walking.stationExitSeconds = 0
        appOptions.minTransferSeconds = 60

        var widgetOptions = appOptions
        widgetOptions.maxResults = 2

        let moment = Fixture.date(8, 1)
        let request = PlanRequest(origin: .station("a"), destination: .station("f"), departAt: moment)
        let fromTheApp = try XCTUnwrap(
            JourneyPlanner(network: Fixture.network, options: appOptions).plan(request).best
        )
        let fromTheWidget = try XCTUnwrap(
            WidgetPlanner.steps(
                for: snapshot(),
                from: moment,
                limit: 1,
                network: Fixture.network,
                options: widgetOptions
            ).first
        )
        XCTAssertEqual(fromTheWidget.leaveBy, fromTheApp.urgency.leaveBy)
    }

    /// A widget cannot redraw itself, so every minute the countdown displays has to be
    /// an entry — landing exactly on the instant the digit changes, never in between.
    func testFramesLandOnEachDisplayedMinute() throws {
        let now = Fixture.date(8, 1)
        let steps = self.steps(at: 8, 1, limit: 2)
        let frames = WidgetPlanner.frames(for: steps, from: now)
        XCTAssertGreaterThan(frames.count, steps.count, "one entry per step would go stale within the minute")

        XCTAssertLessThanOrEqual(frames[0].at, now, "WidgetKit rejects a timeline starting in the future")
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThan(previous.at, next.at, "entries must advance")
        }

        // The number a frame shows has to be the truth for the whole of its turn on
        // screen, since nothing can redraw it in between. Checked just after it takes
        // over, in the middle, and at the last instant before the next one does.
        for (index, frame) in frames.enumerated() {
            guard let shown = frame.countdown else { continue }
            let ends = index + 1 < frames.count ? frames[index + 1].at : frame.step.leaveBy
            let midpoint = frame.at.addingTimeInterval(ends.timeIntervalSince(frame.at) / 2)
            for instant in [frame.at.addingTimeInterval(0.001), midpoint, ends.addingTimeInterval(-0.001)]
            where instant >= frame.at && instant < ends {
                XCTAssertEqual(
                    shown,
                    Format.countdown(frame.step.leaveBy.timeIntervalSince(instant)),
                    "the entry went stale \(ends.timeIntervalSince(instant))s before it expired"
                )
            }
        }
    }

    /// The whole point of landing on the change instants: the sequence steps down one
    /// minute at a time and hands over to the live timer at two.
    func testFramesCountDownOneMinuteAtATime() throws {
        let steps = self.steps(at: 8, 1, limit: 1)
        let frames = WidgetPlanner.frames(for: steps, from: Fixture.date(8, 1))
        let shown = frames.compactMap(\.countdown)
        XCTAssertEqual(shown.last, "2 min", "the last still number before the timer takes over")
        XCTAssertEqual(frames.last?.countdown, nil, "expected the live timer at the end")
        XCTAssertEqual(Set(shown).count, shown.count, "a repeated number means a wasted entry")
    }

    /// Seconds start ticking two minutes out and not before — the same switch the app
    /// makes, because the two are looked at side by side.
    func testSecondsOnlyTickInTheFinalTwoMinutes() throws {
        let frames = WidgetPlanner.frames(for: steps(at: 8, 1, limit: 2), from: Fixture.date(8, 1))
        for frame in frames {
            let remaining = frame.step.leaveBy.timeIntervalSince(frame.at)
            XCTAssertEqual(
                frame.showsSeconds,
                remaining <= Format.countdownSecondsThreshold,
                "a ticking second hand ten minutes out is noise, and a still number ten seconds out is useless"
            )
        }
        XCTAssertTrue(frames.contains { $0.showsSeconds }, "expected a handover to the live timer")
        XCTAssertTrue(frames.contains { !$0.showsSeconds }, "expected a whole-minute stretch first")
    }
}
