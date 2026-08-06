import Foundation

/// A route's badge and its line's colour, resolved for a view that has no `Network`.
///
/// The badge is the route — `B2`, not `B` — because that is what the platform sign
/// says and what distinguishes the train the rider wants from the one on the next
/// track. The colour still comes from the line, so a B2 is orange like the rest of
/// the Broad Street Line.
public struct WidgetLineStyle: Sendable, Hashable {
    public var badge: String
    public var colorHex: String

    public init(badge: String, colorHex: String) {
        self.badge = badge
        self.colorHex = colorHex
    }
}

/// One widget timeline entry's worth of answer.
///
/// Everything a view needs, already resolved: no `Network` lookups and no narrator
/// calls at render time, so the drawing code is pure presentation and this part can
/// be tested without WidgetKit.
public struct WidgetPlanStep: Sendable, Hashable {
    /// When this entry takes over.
    public var validFrom: Date
    /// Lines ridden, in order, deduplicated.
    public var lines: [WidgetLineStyle]
    /// "Local now, switch to the express at Girard".
    public var title: String
    /// "Express toward NRG" for the first train — the words on the front of it.
    public var platformDescription: String?
    /// Where to be standing.
    public var boardName: String?
    /// The last moment the rider can set off. What the countdown counts to.
    public var leaveBy: Date
    public var arrival: Date
    public var isWalkOnly: Bool
    /// What missing this costs, when it is enough to matter. Deliberately not a
    /// "run!" warning: whether to run depends on how long is left, and a timeline
    /// entry computed ten minutes ago cannot know that. The cost doesn't change,
    /// so the cost is what gets stated.
    public var penaltyText: String?
    /// When the next-best option would get you there, if there is one.
    public var nextArrival: Date?

    public init(
        validFrom: Date,
        lines: [WidgetLineStyle],
        title: String,
        platformDescription: String? = nil,
        boardName: String? = nil,
        leaveBy: Date,
        arrival: Date,
        isWalkOnly: Bool,
        penaltyText: String? = nil,
        nextArrival: Date? = nil
    ) {
        self.validFrom = validFrom
        self.lines = lines
        self.title = title
        self.platformDescription = platformDescription
        self.boardName = boardName
        self.leaveBy = leaveBy
        self.arrival = arrival
        self.isWalkOnly = isWalkOnly
        self.penaltyText = penaltyText
        self.nextArrival = nextArrival
    }
}

/// One moment on the widget's timeline: which answer is on screen, and how the
/// countdown to it should be drawn.
///
/// A widget cannot re-render itself when it feels like it — every frame it will ever
/// show has to be handed to WidgetKit up front. So the countdown's own changes are
/// part of the timeline: one frame per displayed minute while it counts in minutes,
/// then a single frame for the last stretch, where WidgetKit's live timer takes over
/// and no further frames are needed.
public struct WidgetPlanFrame: Sendable, Hashable {
    /// When this frame goes on screen.
    public var at: Date
    public var step: WidgetPlanStep
    /// The countdown to draw, for the whole of this frame's turn on screen — or `nil`
    /// once the deadline is close enough that seconds earn their place, where
    /// WidgetKit's live timer takes over and needs no frames at all.
    ///
    /// Held here rather than recomputed from `at` in the view, because the two differ
    /// by exactly the case that matters: frames land on the instants the number
    /// changes, and a window beginning at 3:00 spends all of itself reading "2 min".
    public var countdown: String?

    /// The same threshold the app switches at, so the two never disagree side by side.
    public var showsSeconds: Bool { countdown == nil }

    public init(at: Date, step: WidgetPlanStep, countdown: String?) {
        self.at = at
        self.step = step
        self.countdown = countdown
    }
}

/// Builds a widget's timeline from the bundled timetable.
///
/// A widget can't recompute on demand, so instead of guessing a refresh interval
/// this walks forward through the actual answers: plan now, and the next entry
/// begins at the exact moment the option it recommends becomes uncatchable. Between
/// those instants nothing the widget could say would change, which is why the
/// countdown can be a self-updating `Text` rather than an entry per minute.
public enum WidgetPlanner {

    /// The rider's own settings, so the widget answers the question the app answers.
    ///
    /// Only `maxResults` is narrowed, and that cannot change which train comes first —
    /// it trims the list after ranking. Everything a rider can adjust and everything
    /// that moves `leaveBy` — walking speed, how far they'll walk, boarding margin,
    /// whether to change trains, step-free routing — comes from what they set, and
    /// everything else is left at the library default the app also uses. Guessing at
    /// any of it was why the widget's countdown and the app's disagreed.
    public static func options(tuning: RiderTuning? = SharedStore.tuning()) -> PlannerOptions {
        var options = (tuning ?? RiderTuning()).plannerOptions()
        options.maxResults = 2
        return options
    }

    public static func steps(
        for snapshot: CommuteSnapshot,
        from now: Date,
        limit: Int = 4,
        network: Network = SEPTAData.network,
        options: PlannerOptions? = nil
    ) -> [WidgetPlanStep] {
        // Resolved per moment, not per snapshot: the widget's job is to answer the
        // trip the rider is making now, which flips at midday.
        let trip = snapshot.trip(at: now)
        guard let origin = trip.origin.endpoint,
              let destination = trip.destination.endpoint else { return [] }

        let planner = JourneyPlanner(network: network, options: options ?? Self.options())
        let narrator = JourneyNarrator(network: network)

        var steps: [WidgetPlanStep] = []
        var instant = now

        while steps.count < limit {
            let plan = planner.plan(PlanRequest(origin: origin, destination: destination, departAt: instant))
            guard let best = plan.best else { break }

            steps.append(
                step(for: best, plan: plan, at: instant, narrator: narrator, network: network)
            )

            // The next entry begins the moment this one stops being catchable. A
            // walk has no train to miss, so there is nothing after it.
            guard !best.isWalkOnly else { break }
            let next = best.urgency.leaveBy.addingTimeInterval(1)
            instant = max(next, instant.addingTimeInterval(60))
        }
        return steps
    }

    /// The steps, expanded into the frames a widget has to be given in advance.
    ///
    /// One frame per minute the countdown displays, which sounds extravagant and isn't:
    /// the frames land exactly on the instants the number changes, so a twenty-minute
    /// wait costs twenty frames and never shows a stale one in between. The last frame
    /// of each step starts two minutes before its deadline and hands over to WidgetKit's
    /// live timer, which needs no frames at all.
    public static func frames(
        for steps: [WidgetPlanStep],
        from now: Date,
        limit: Int = 120
    ) -> [WidgetPlanFrame] {
        var frames: [WidgetPlanFrame] = []

        for (index, step) in steps.enumerated() {
            guard frames.count < limit else { break }
            let start = max(step.validFrom, now)
            // This answer stands until the next one takes over, or — for the last one —
            // until its own deadline passes and WidgetKit reloads.
            let end = index + 1 < steps.count
                ? steps[index + 1].validFrom
                : step.leaveBy.addingTimeInterval(1)
            guard start < end else { continue }

            let handover = step.leaveBy.addingTimeInterval(-Format.countdownSecondsThreshold)

            var instants: [Date] = [start]
            if handover > start {
                // The live timer takes over here and runs to the deadline unaided.
                instants.append(handover)
                // Before that, one frame per whole minute the countdown displays,
                // landing on the instants it changes: those are the whole minutes
                // counted back from the deadline, not from now.
                var mark = handover.addingTimeInterval(-60)
                while mark > start {
                    instants.append(mark)
                    mark = mark.addingTimeInterval(-60)
                }
            }
            instants.sort()

            for instant in instants where instant < end {
                guard frames.count < limit else { break }
                let remaining = step.leaveBy.timeIntervalSince(instant)
                frames.append(WidgetPlanFrame(
                    at: instant,
                    step: step,
                    countdown: instant >= handover ? nil : windowCountdown(remaining)
                ))
            }
        }

        // WidgetKit rejects a timeline that doesn't start at or before now, and a plan
        // computed a moment ago can round its way past it.
        if let first = frames.first, first.at > now {
            frames[0].at = now
        }
        return frames
    }

    /// The countdown as it will read for a window *beginning* this far from the
    /// deadline, which is not the same as the countdown at that instant.
    ///
    /// The number floors, so it changes the moment it drops below a whole minute: at
    /// 3:00 exactly it still says "3 min", and one instant later it says "2 min" and
    /// keeps saying it for the next sixty seconds. A frame that opens at 3:00 owns
    /// that whole minute, so "2 min" is what it has to show. Taking the value a hair
    /// below the boundary is exactly that rule, and leaves frames that don't land on
    /// a boundary untouched.
    private static func windowCountdown(_ remaining: TimeInterval) -> String {
        Format.countdown(remaining.nextDown)
    }

    private static func step(
        for journey: Journey,
        plan: Plan,
        at instant: Date,
        narrator: JourneyNarrator,
        network: Network
    ) -> WidgetPlanStep {
        var lines: [WidgetLineStyle] = []
        for ride in journey.rides where !lines.contains(where: { $0.badge == ride.routeBadge }) {
            let colorHex = network.line(ride.lineID)?.colorHex ?? "6B7280"
            lines.append(WidgetLineStyle(badge: ride.routeBadge, colorHex: colorHex))
        }

        let runnerUp = plan.journeys.dropFirst().first
        var penaltyText: String?
        if let penalty = journey.missedCost?.penalty, penalty >= 300 {
            penaltyText = "Miss it: +\(Format.compactMinutes(penalty))"
        }

        return WidgetPlanStep(
            validFrom: instant,
            lines: lines,
            title: narrator.summary(for: journey).title,
            platformDescription: journey.rides.first?.platformDescription,
            boardName: journey.rides.first.map { network.station($0.boardStation)?.name ?? $0.boardStation.rawValue },
            leaveBy: journey.urgency.leaveBy,
            arrival: journey.arrivalTime,
            isWalkOnly: journey.isWalkOnly,
            penaltyText: penaltyText,
            nextArrival: runnerUp?.arrivalTime
        )
    }
}
