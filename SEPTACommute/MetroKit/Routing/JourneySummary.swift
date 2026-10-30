import Foundation

/// The shape of a journey, named the way a rider would describe it.
public enum JourneyStrategy: Sendable, Hashable {
    case walk
    /// One train, straight through.
    case direct(PatternKind)
    /// Ride one train, get off, and catch a faster one — the classic
    /// "take the local now and let the express overtake you at Erie".
    case overtake(first: PatternKind, second: PatternKind, at: StationID)
    /// Change trains for a reason other than being overtaken (a branch, a short-turn).
    case connect(first: PatternKind, second: PatternKind, at: StationID)
    /// Three or more trains.
    case multiLeg(count: Int)

    public var isOvertake: Bool {
        if case .overtake = self { return true }
        return false
    }
}

/// Rider-facing text for one option.
public struct JourneySummary: Sendable, Hashable {
    public var strategy: JourneyStrategy
    /// Headline, e.g. "Express, straight through".
    public var title: String
    /// One line of detail, e.g. "Board at Erie, off at Girard, 7 min walk".
    public var detail: String
    /// Extra nuance worth a smaller line, e.g. "Skips Fairmount".
    public var footnote: String?

    public init(strategy: JourneyStrategy, title: String, detail: String, footnote: String? = nil) {
        self.strategy = strategy
        self.title = title
        self.detail = detail
        self.footnote = footnote
    }
}

/// Whether this is worth hurrying for.
///
/// Deliberately a function of two things, because either alone misleads. Slack
/// says how close you are cutting it; `MissedTrainCost` says what missing it
/// costs. Two minutes of slack is an emergency before the last express of the
/// peak and completely irrelevant when the next local is three minutes behind —
/// and telling a rider to run in the second case is worse than saying nothing,
/// because it teaches them to ignore the warning.
public enum Advisory: Sendable, Hashable {
    /// Tight, and expensive to miss.
    case run(penalty: TimeInterval, secondsLeft: TimeInterval)
    /// Tight, but the next one is right behind — don't bother running.
    case dontRush(penalty: TimeInterval)
    /// Not tight, but worth knowing this one is expensive to miss.
    case worthCatching(penalty: TimeInterval)
    /// Already gone.
    case missed

    public var isUrgent: Bool {
        if case .run = self { return true }
        return false
    }
}

/// How one option compares to the best one.
public struct JourneyComparison: Sendable, Hashable {
    /// Positive means this option arrives later than the best.
    public var arrivalDelta: TimeInterval
    /// Positive means this option lets the rider leave later than the best.
    public var departureDelta: TimeInterval
    public var isBest: Bool

    public init(arrivalDelta: TimeInterval, departureDelta: TimeInterval, isBest: Bool) {
        self.arrivalDelta = arrivalDelta
        self.departureDelta = departureDelta
        self.isBest = isBest
    }
}

/// Names journeys and explains why the winner won.
public struct JourneyNarrator: Sendable {
    public let network: Network

    public init(network: Network) {
        self.network = network
    }

    private func name(_ id: StationID) -> String {
        network.station(id)?.name ?? id.rawValue
    }

    /// The route a rider sees on the map and the station signs.
    ///
    /// The route, never the line letter: "the B" is three different trains at Erie,
    /// two of which don't stop where you're going.
    private func badge(_ ride: RideLeg) -> String { ride.routeBadge }

    // MARK: - Strategy

    public func strategy(for journey: Journey) -> JourneyStrategy {
        let rides = journey.rides
        switch rides.count {
        case 0:
            return .walk
        case 1:
            return .direct(rides[0].kind)
        case 2:
            let at = rides[0].alightStation
            // Only call it an overtake if the planner verified one against the
            // timetable. Same line, same direction is *not* evidence: riding the
            // express to Girard and finishing on a local has exactly that shape
            // and overtakes nothing.
            if journey.overtake != nil {
                return .overtake(first: rides[0].kind, second: rides[1].kind, at: at)
            }
            return .connect(first: rides[0].kind, second: rides[1].kind, at: at)
        default:
            return .multiLeg(count: rides.count)
        }
    }

    // MARK: - Summary

    public func summary(for journey: Journey) -> JourneySummary {
        let strategy = strategy(for: journey)
        return JourneySummary(
            strategy: strategy,
            title: title(for: journey, strategy: strategy),
            detail: detail(for: journey),
            footnote: footnote(for: journey, strategy: strategy)
        )
    }

    private func title(for journey: Journey, strategy: JourneyStrategy) -> String {
        switch strategy {
        case .walk:
            return "Walk the whole way"
        case .direct(let kind):
            let line = journey.rides.first.map { badge($0) }
            switch kind {
            case .express: return "Express, straight through"
            case .spur: return "Broad-Ridge Spur"
            case .nightBus: return "Owl bus"
            case .local:
                // Name the line. "Local, straight through" reads fine when there is
                // only one line in the app, and says nothing once there are nine.
                guard let line else { return "Straight through, no changes" }
                return "Straight through on the \(line)"
            }
        case .overtake(let first, let second, let at):
            if first == .local, second == .express {
                return "Local now, switch to the express at \(name(at))"
            }
            if first == .express, second == .local {
                return "Express to \(name(at)), then the local"
            }
            return "\(first.label) to \(name(at)), then the \(second.label.lowercased())"
        case .connect(let first, let second, let at):
            // Changing between lines is the useful thing to say; changing stopping
            // pattern within one line is the fallback.
            if let from = journey.rides.first,
               let to = journey.rides.dropFirst().first,
               from.routeID != to.routeID {
                // Naming both routes is the point — and the second one's stopping
                // pattern too, when it is what makes the change worth making.
                let onward = to.kind == .local ? badge(to) : "\(badge(to)) \(to.kind.label.lowercased())"
                return "\(badge(from)) to \(name(at)), change to the \(onward)"
            }
            return "\(first.label) to \(name(at)), change to the \(second.label.lowercased())"
        case .multiLeg(let count):
            return "\(count) trains"
        }
    }

    private func detail(for journey: Journey) -> String {
        var parts: [String] = []
        if let board = journey.boardStation {
            parts.append("Board at \(name(board))")
        }
        if let alight = journey.alightStation {
            parts.append("off at \(name(alight))")
        }
        if let walk = journey.finalWalk, walk.duration >= 60 {
            parts.append("\(Format.minutes(walk.duration)) walk")
        } else if journey.isWalkOnly {
            return "\(Format.minutes(journey.totalDuration)) on foot"
        }
        return parts.joined(separator: ", ")
    }

    private func footnote(for journey: Journey, strategy: JourneyStrategy) -> String? {
        // When a faster train really did catch the rider up, say what that is
        // worth. This is the one number that justifies the whole manoeuvre, and
        // it now comes from a timetable comparison rather than an assumption.
        if let overtake = journey.overtake, let wait = journey.overtakeWait {
            if overtake.timeSaved >= 60 {
                return "Saves \(Format.minutes(overtake.timeSaved)) over staying on, after a "
                    + "\(Format.minutes(wait.duration)) wait at \(name(wait.stationID))"
            }
            return "Your first train gets passed at \(name(overtake.switchedAt))"
        }

        // Otherwise the most useful nuance is which stations a fast train skips,
        // because that is exactly what makes riders distrust the express.
        if let ride = journey.rides.first(where: { $0.kind == .express || $0.kind == .spur }) {
            let skipped = skippedStations(on: ride)
            if !skipped.isEmpty {
                let names = skipped.prefix(3).map(name)
                let suffix = skipped.count > 3 ? " +\(skipped.count - 3) more" : ""
                return "Skips \(names.joined(separator: ", "))\(suffix)"
            }
        }
        return nil
    }

    /// Stations the rider passes without stopping on this ride.
    ///
    /// Derived by comparing the ride against a local pattern going the same way,
    /// so it stays correct if SEPTA changes the express stopping pattern.
    public func skippedStations(on ride: RideLeg) -> [StationID] {
        guard ride.kind != .local else { return [] }
        guard let localPattern = network.patterns.first(where: {
            $0.lineID == ride.lineID
                && $0.kind == .local
                && $0.direction == ride.direction
                && $0.carries(from: ride.boardStation, to: ride.alightStation)
        }) else { return [] }

        guard let from = localPattern.stopIndex(of: ride.boardStation),
              let to = localPattern.stopIndex(of: ride.alightStation) else { return [] }

        let served = Set(ride.stationsServed)
        return localPattern.stops[(from + 1)..<to]
            .map(\.station)
            .filter { !served.contains($0) }
    }

    // MARK: - Comparison

    public func comparison(of journey: Journey, against best: Journey) -> JourneyComparison {
        JourneyComparison(
            arrivalDelta: journey.arrivalTime.timeIntervalSince(best.arrivalTime),
            departureDelta: journey.departureTime.timeIntervalSince(best.departureTime),
            isBest: journey.id == best.id
        )
    }

    /// Whether to run for this train, if there is anything worth saying.
    ///
    /// Thresholds: "expensive" is five minutes lost, which is roughly one headway
    /// on this network at peak and the point at which a rider notices. "Cheap" is
    /// three minutes or less, where running gains almost nothing.
    public func advisory(for journey: Journey, asOf now: Date) -> Advisory? {
        guard !journey.isWalkOnly else { return nil }
        let secondsLeft = journey.urgency.secondsUntilLeaveBy(asOf: now)
        if secondsLeft < -30 { return .missed }

        guard let cost = journey.missedCost else { return nil }
        let tight = secondsLeft <= 150

        if tight, cost.penalty >= 300 {
            return .run(penalty: cost.penalty, secondsLeft: max(0, secondsLeft))
        }
        if tight, cost.penalty <= 180 {
            return .dontRush(penalty: cost.penalty)
        }
        if !tight, cost.penalty >= 600 {
            return .worthCatching(penalty: cost.penalty)
        }
        return nil
    }

    /// The advisory as a sentence.
    public func advisoryText(_ advisory: Advisory) -> String {
        switch advisory {
        case .run(let penalty, let secondsLeft):
            // Floored like every other countdown: rounding said "2m" with 91 s left.
            let when = secondsLeft <= 30 ? "Go now" : "Leave \(Format.relativeLeave(secondsLeft))"
            return "\(when) — miss this and you lose \(Format.minutes(penalty))"
        case .dontRush(let penalty):
            // "only under a minute behind" is what `Format.minutes` makes of a tie.
            guard penalty >= 60 else { return "No need to run — the next option gets you there just as soon" }
            return "No need to run — the next option is only \(Format.minutes(penalty)) behind"
        case .worthCatching(let penalty):
            return "Worth catching: the next option arrives \(Format.minutes(penalty)) later"
        case .missed:
            return "This one has gone"
        }
    }

    /// The one sentence that answers "so which do I take?".
    ///
    /// The interesting case is when the fastest option also demands you move
    /// right now: a rider who cannot make that train needs to know what it costs
    /// to take the next one.
    public func advice(for plan: Plan, asOf now: Date) -> String? {
        guard let best = plan.journeys.first else { return nil }
        let bestSummary = summary(for: best)

        // A run warning outranks any comparison between options: it is the only
        // thing that changes what the rider should do in the next thirty seconds.
        if let advisory = advisory(for: best, asOf: now), advisory.isUrgent {
            return "\(bestSummary.title). \(advisoryText(advisory))."
        }

        guard let runnerUp = plan.journeys.dropFirst().first else {
            if best.isWalkOnly { return "Walking is your only option right now." }
            let leave = best.urgency.secondsUntilLeaveBy(asOf: now)
            return "\(bestSummary.title). Leave \(Format.relativeLeave(leave))."
        }

        let penalty = runnerUp.arrivalTime.timeIntervalSince(best.arrivalTime)
        let extraSlack = runnerUp.urgency.leaveBy.timeIntervalSince(best.urgency.leaveBy)
        let bestLeave = best.urgency.secondsUntilLeaveBy(asOf: now)

        // Cheap insurance: the second option costs almost nothing.
        if penalty <= 120, extraSlack >= 120 {
            let cost = penalty < 60 ? "gets you there just as soon" : "is only \(Format.minutes(penalty)) slower"
            return "\(summary(for: runnerUp).title) \(cost) and gives you "
                + "\(Format.minutes(extraSlack)) more to get there — no need to run."
        }

        // The fastest option is worth hustling for.
        if bestLeave <= 180, penalty >= 240 {
            return "\(bestSummary.title) — leave \(Format.relativeLeave(bestLeave)). "
                + "Miss it and the next option gets you there \(Format.minutes(penalty)) later."
        }

        if best.usesExpress, !runnerUp.usesExpress {
            return "Waiting for the express wins by \(Format.minutes(penalty)). "
                + "Leave \(Format.relativeLeave(bestLeave))."
        }
        if !best.usesExpress, runnerUp.usesExpress {
            // The title as written, not lowercased: that turned "the B1" into "the b1"
            // and "Broad-Ridge Spur" into "broad-ridge spur".
            return "Don't wait for the express: \(bestSummary.title) gets you there "
                + "\(Format.minutes(penalty)) sooner."
        }

        return "\(bestSummary.title). Leave \(Format.relativeLeave(bestLeave)), "
            + "arrive \(Format.clock(best.arrivalTime))."
    }
}
