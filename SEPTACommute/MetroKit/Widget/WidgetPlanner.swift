import Foundation

/// A line's badge and colour, resolved for a view that has no `Network`.
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
        leaveBy: Date,
        arrival: Date,
        isWalkOnly: Bool,
        penaltyText: String? = nil,
        nextArrival: Date? = nil
    ) {
        self.validFrom = validFrom
        self.lines = lines
        self.title = title
        self.leaveBy = leaveBy
        self.arrival = arrival
        self.isWalkOnly = isWalkOnly
        self.penaltyText = penaltyText
        self.nextArrival = nextArrival
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

    /// Deliberately narrower than the app's search. The widget shows one answer, and
    /// it has to produce several of them inside an extension's time budget.
    public static func options() -> PlannerOptions {
        var options = PlannerOptions()
        options.maxResults = 2
        options.maxAccessStations = 2
        options.maxEgressStations = 2
        options.maxTransfers = 1
        return options
    }

    public static func steps(
        for snapshot: CommuteSnapshot,
        from now: Date,
        limit: Int = 4,
        network: Network = SEPTAData.network,
        options: PlannerOptions? = nil
    ) -> [WidgetPlanStep] {
        guard let origin = snapshot.origin.endpoint,
              let destination = snapshot.destination.endpoint else { return [] }

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

    private static func step(
        for journey: Journey,
        plan: Plan,
        at instant: Date,
        narrator: JourneyNarrator,
        network: Network
    ) -> WidgetPlanStep {
        var lines: [WidgetLineStyle] = []
        for ride in journey.rides {
            guard let line = network.line(ride.lineID) else { continue }
            guard !lines.contains(where: { $0.badge == line.badge }) else { continue }
            lines.append(WidgetLineStyle(badge: line.badge, colorHex: line.colorHex))
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
            leaveBy: journey.urgency.leaveBy,
            arrival: journey.arrivalTime,
            isWalkOnly: journey.isWalkOnly,
            penaltyText: penaltyText,
            nextArrival: runnerUp?.arrivalTime
        )
    }
}
