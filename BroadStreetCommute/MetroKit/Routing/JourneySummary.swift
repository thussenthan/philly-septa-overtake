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
            switch kind {
            case .express: return "Express, straight through"
            case .local: return "Local, straight through"
            case .spur: return "Broad-Ridge Spur"
            case .nightBus: return "Owl bus"
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

    /// The one sentence that answers "so which do I take?".
    ///
    /// The interesting case is when the fastest option also demands you move
    /// right now: a rider who cannot make that train needs to know what it costs
    /// to take the next one.
    public func advice(for plan: Plan, asOf now: Date) -> String? {
        guard let best = plan.journeys.first else { return nil }
        let bestSummary = summary(for: best)

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
            return "\(summary(for: runnerUp).title) is only \(Format.minutes(penalty)) slower and gives you "
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
            return "Don't wait for the express — \(bestSummary.title.lowercased()) gets you there "
                + "\(Format.minutes(penalty)) sooner."
        }

        return "\(bestSummary.title). Leave \(Format.relativeLeave(bestLeave)), "
            + "arrive \(Format.clock(best.arrivalTime))."
    }
}
