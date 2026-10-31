import Foundation

public struct PlannerOptions: Sendable {
    /// Longest access or egress walk to consider.
    public var maxWalkSeconds: TimeInterval = 22 * 60
    /// How many candidate boarding stations to try.
    ///
    /// More than one matters: the nearest station is not always the right one.
    /// Walking an extra three minutes to a station the express actually stops at
    /// routinely beats boarding the local next door.
    public var maxAccessStations: Int = 4
    /// How many candidate alighting stations to try.
    ///
    /// This is what lets the planner say "ride the express past your stop to
    /// Girard and walk back" — the express skips Fairmount, so the only way to
    /// use it is to get off somewhere else.
    public var maxEgressStations: Int = 4
    /// Maximum number of train-to-train changes.
    public var maxTransfers: Int = 2
    /// Time needed to get from one platform to another at the same station.
    ///
    /// At Olney and City Hall the express uses separate center tracks, so this is
    /// a real platform change, not a step across.
    public var minTransferSeconds: TimeInterval = 75
    /// Padding added before every boarding, so a plan that is only theoretically
    /// catchable is not presented as catchable.
    public var boardingBufferSeconds: TimeInterval = 30
    /// How far ahead to look for departures.
    public var searchHorizon: TimeInterval = 100 * 60
    /// How many options to return.
    public var maxResults: Int = 6
    /// Options arriving more than this much later than the best are dropped:
    /// nobody wants a fifth-best option that loses twenty minutes.
    public var arrivalTolerance: TimeInterval = 12 * 60
    /// Use only stations with elevator access, including for changes of train.
    ///
    /// This genuinely changes answers on this network rather than just trimming
    /// them: Erie and Fairmount have no elevator, so the commute the app was built
    /// around has an entirely different shape step-free.
    public var requiresStepFreeAccess: Bool = false
    public var walking = WalkingModel()

    public init() {}
}

/// What the rider asked for.
public struct PlanRequest: Sendable {
    public var origin: Endpoint
    public var destination: Endpoint
    /// When the rider can start moving. Usually "now".
    public var departAt: Date
    /// Real walking times, when the app has measured them.
    public var walkOverrides: WalkTimeOverrides

    public init(
        origin: Endpoint,
        destination: Endpoint,
        departAt: Date,
        walkOverrides: WalkTimeOverrides = .none
    ) {
        self.origin = origin
        self.destination = destination
        self.departAt = departAt
        self.walkOverrides = walkOverrides
    }
}

/// Something worth telling the rider that is not itself a route.
public enum PlanNote: Sendable, Hashable {
    /// The whole trip is shorter on foot than waiting for a train.
    case walkingIsFaster(saving: TimeInterval)
    /// Express exists on this line but is not running at the requested time.
    case expressNotRunningNow(nextDeparture: Date?)
    /// The bundled timetable has run out of service data entirely.
    case scheduleOutOfDate(feedEndDate: String)
    /// Trains have stopped for the night; a replacement bus is running.
    case nightServiceOnly
    /// Step-free routing is on, and it is the reason there is nothing to show.
    case noStepFreeRouteFound
    /// Step-free routing is on and cost the rider time.
    case stepFreeCostsTime(extra: TimeInterval)
    /// No station was close enough to walk to.
    case originTooFarFromLine(nearest: StationID, meters: Double)
    case destinationTooFarFromLine(nearest: StationID, meters: Double)
    /// Nothing at all could be built.
    case noServiceFound
}

/// The answer: ranked options, plus why the top one wins.
public struct Plan: Sendable {
    public var request: PlanRequest
    public var journeys: [Journey]
    public var notes: [PlanNote]
    public var generatedAt: Date

    public init(request: PlanRequest, journeys: [Journey], notes: [PlanNote], generatedAt: Date) {
        self.request = request
        self.journeys = journeys
        self.notes = notes
        self.generatedAt = generatedAt
    }

    public var best: Journey? { journeys.first }

    /// The fastest option that leaves late enough to still be catchable, given
    /// how long the rider has already spent staring at the screen.
    public func bestCatchable(asOf now: Date) -> Journey? {
        journeys.first { $0.urgency.leaveBy >= now.addingTimeInterval(-30) }
    }
}

/// Builds door-to-door options across a small rapid-transit network.
///
/// The search is exhaustive rather than heuristic. A door-to-door plan over the
/// Broad Street Line measures at about 13 ms, and in exchange the interesting
/// strategies fall out on their own instead of being special-cased:
///
/// * ride the local the whole way;
/// * wait for the express and ride it the whole way;
/// * board the local now, hop off where the express stops, and let it overtake you;
/// * ride the express past a station it skips, then walk back;
/// * walk further to a station the express actually serves.
///
/// None of those are coded as rules. They are all just paths the enumeration
/// finds, scored by when the rider actually reaches the door.
public struct JourneyPlanner: Sendable {
    public let network: Network
    public let timetable: Timetable
    public var options: PlannerOptions

    public init(network: Network, calendar: ServiceCalendar = ServiceCalendar(), options: PlannerOptions = PlannerOptions()) {
        self.network = network
        self.timetable = Timetable(network: network, calendar: calendar)
        self.options = options
    }

    // MARK: - Entry point

    public func plan(_ request: PlanRequest) -> Plan {
        var notes: [PlanNote] = []

        let access = terminalLegs(for: request.origin, role: .access, overrides: request.walkOverrides)
        let egress = terminalLegs(for: request.destination, role: .egress, overrides: request.walkOverrides)

        if access.isEmpty, let nearest = nearestStationNote(to: request.origin) {
            notes.append(.originTooFarFromLine(nearest: nearest.0, meters: nearest.1))
        }
        if egress.isEmpty, let nearest = nearestStationNote(to: request.destination) {
            notes.append(.destinationTooFarFromLine(nearest: nearest.0, meters: nearest.1))
        }

        var candidates = enumerateJourneys(request: request, access: access, egress: egress)

        if let walkOnly = directWalk(request: request) {
            candidates.append(walkOnly)
        }

        var ranked = rank(candidates)

        // What each option costs to miss, measured against every alternative the
        // search found — not just the handful that survived ranking, since the
        // realistic fallback is often a plain slower train that got filtered out.
        ranked = ranked.map { journey in
            var withCost = journey
            withCost.missedCost = missedCost(for: journey, among: candidates)
            return withCost
        }

        // A walk that beats every train is worth saying out loud, not burying
        // at position four.
        if let walkOnly = ranked.first(where: { $0.isWalkOnly }),
           let fastestRide = ranked.first(where: { !$0.isWalkOnly }),
           walkOnly.arrivalTime < fastestRide.arrivalTime {
            notes.append(.walkingIsFaster(saving: fastestRide.arrivalTime.timeIntervalSince(walkOnly.arrivalTime)))
        }

        notes.append(contentsOf: serviceNotes(request: request, journeys: ranked, access: access))

        if options.requiresStepFreeAccess {
            notes.append(contentsOf: stepFreeNotes(request: request, ranked: ranked))
        }

        if ranked.isEmpty {
            notes.append(.noServiceFound)
        }
        if ranked.count > options.maxResults {
            ranked = Array(ranked.prefix(options.maxResults))
        }

        return Plan(request: request, journeys: ranked, notes: notes, generatedAt: request.departAt)
    }

    /// `plan`, topped up with later departures until there are at least `minimum`
    /// options.
    ///
    /// The search takes only the next trip of each pattern and drops anything well
    /// behind the best arrival, which is right for choosing a train and leaves the
    /// home screen with a single card off-peak. A rider glancing at it wants to know
    /// what comes after that one too, so this plans again as if they had just missed
    /// the latest train found, and keeps the new trains. Slack is re-measured from
    /// the original moment, since that is when the rider is reading it.
    public func plan(_ request: PlanRequest, atLeast minimum: Int) -> Plan {
        var result = plan(request)
        guard !result.journeys.isEmpty else { return result }

        var seen = Set(result.journeys.map(\.id))
        // A handful of rounds is plenty: each one finds at least the next train.
        for _ in 0..<4 where result.journeys.count < minimum {
            guard let latest = result.journeys.filter({ !$0.isWalkOnly }).map(\.urgency.leaveBy).max() else { break }
            var later = request
            later.departAt = latest.addingTimeInterval(1)

            let added = plan(later).journeys
                .filter { !$0.isWalkOnly && !seen.contains($0.id) }
                .map { journey -> Journey in
                    var rebased = journey
                    rebased.urgency.slack = journey.urgency.leaveBy.timeIntervalSince(request.departAt)
                    return rebased
                }
            guard !added.isEmpty else { break }
            seen.formUnion(added.map(\.id))
            result.journeys += added.prefix(minimum - result.journeys.count)
        }
        return result
    }

    // MARK: - Terminal (walking) legs

    private enum Role {
        case access
        case egress
    }

    private struct TerminalLeg {
        var station: Station
        var straightLineMeters: Double
        var seconds: TimeInterval
        var isMeasured: Bool
    }

    private func terminalLegs(for endpoint: Endpoint, role: Role, overrides: WalkTimeOverrides) -> [TerminalLeg] {
        switch endpoint {
        case .station(let id):
            guard let station = network.station(id) else { return [] }
            // An explicitly chosen station is honoured even without step-free
            // access — the rider is standing in it.
            // Already inside the station: no walk, but still a moment to reach
            // the platform when boarding.
            let seconds: TimeInterval = role == .access ? options.walking.stationEntrySeconds * 0.5 : 0
            return [TerminalLeg(station: station, straightLineMeters: 0, seconds: seconds, isMeasured: true)]

        case .place(_, let coordinate):
            let limit = options.maxWalkSeconds
            let searchRadius = options.walking.metersPerSecond * limit / options.walking.circuityFactor
            let nearby = network.stations(near: coordinate, within: max(searchRadius, 400))
            let cap = role == .access ? options.maxAccessStations : options.maxEgressStations

            var legs: [TerminalLeg] = []
            for candidate in nearby {
                // A station with unknown accessibility is excluded under step-free
                // routing: promising an elevator that may not exist is worse than
                // omitting the station.
                if options.requiresStepFreeAccess, candidate.station.isAccessible != true { continue }
                let key: WalkTimeOverrides.Kind = role == .access
                    ? .access(candidate.station.id)
                    : .egress(candidate.station.id)
                let measured = overrides[key]
                // A measured walk is the walk and nothing else: MapKit knows nothing
                // about getting out of the door or through the station gates, so the
                // fixed overheads go back on. Substituting it for the whole estimate
                // made every measured trip about a minute and a half optimistic —
                // trains that looked catchable were not, and the arrival came early.
                let seconds: TimeInterval
                if let measured {
                    seconds = role == .access
                        ? options.walking.startupSeconds + measured + options.walking.stationEntrySeconds
                        : options.walking.stationExitSeconds + measured
                } else {
                    seconds = role == .access
                        ? options.walking.accessSeconds(straightLineMeters: candidate.meters)
                        : options.walking.egressSeconds(straightLineMeters: candidate.meters)
                }
                guard seconds <= limit else { continue }
                legs.append(TerminalLeg(
                    station: candidate.station,
                    straightLineMeters: candidate.meters,
                    seconds: seconds,
                    isMeasured: measured != nil
                ))
            }
            // Keep the closest few by walking time, not by distance: a measured
            // walk can reorder them.
            return Array(legs.sorted { $0.seconds < $1.seconds }.prefix(cap))
        }
    }

    private func nearestStationNote(to endpoint: Endpoint) -> (StationID, Double)? {
        guard let coordinate = endpoint.coordinate,
              let nearest = network.nearestStation(to: coordinate) else { return nil }
        return (nearest.station.id, nearest.meters)
    }

    private func walkLeg(_ leg: TerminalLeg, purpose: WalkLeg.Purpose, from: String, to: String, startingAt: Date) -> WalkLeg {
        WalkLeg(
            purpose: purpose,
            fromName: from,
            toName: to,
            straightLineMeters: leg.straightLineMeters,
            routedMeters: options.walking.routedMeters(straightLine: leg.straightLineMeters),
            duration: leg.seconds,
            startTime: startingAt,
            isMeasured: leg.isMeasured
        )
    }

    // MARK: - Walk-only option

    private func directWalk(request: PlanRequest) -> Journey? {
        guard let from = request.origin.coordinate, let to = request.destination.coordinate else { return nil }
        let meters = from.distance(to: to)
        let seconds = options.walking.startupSeconds + options.walking.walkSeconds(straightLineMeters: meters)
        guard seconds <= options.maxWalkSeconds * 1.5 else { return nil }

        let arrival = request.departAt.addingTimeInterval(seconds)
        let leg = WalkLeg(
            purpose: .direct,
            fromName: request.origin.displayName,
            toName: request.destination.displayName,
            straightLineMeters: meters,
            routedMeters: options.walking.routedMeters(straightLine: meters),
            duration: seconds,
            startTime: request.departAt,
            isMeasured: false
        )
        return Journey(
            legs: [.walk(leg)],
            departureTime: request.departAt,
            arrivalTime: arrival,
            // A walk has no timetable, so there is nothing to be late for.
            urgency: .unconstrained(from: request.departAt)
        )
    }

    // MARK: - Enumeration

    /// One partial itinerary during the search.
    private struct PartialRide {
        var trip: Trip
        var pattern: ServicePattern
        var board: StationID
        var alight: StationID
        var departure: Date
        var arrival: Date
        var stations: [StationID]
    }

    private func enumerateJourneys(
        request: PlanRequest,
        access: [TerminalLeg],
        egress: [TerminalLeg]
    ) -> [Journey] {
        guard !access.isEmpty, !egress.isEmpty else { return [] }

        let egressByStation = Dictionary(
            egress.map { ($0.station.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let horizonEnd = request.departAt.addingTimeInterval(options.searchHorizon)

        var results: [Journey] = []
        // Best arrival found so far, used to prune hopeless branches.
        var bestArrival = Date.distantFuture

        // Calendar arithmetic once per plan, not once per timetable lookup.
        let serviceDays = timetable.calendar.serviceDays(
            overlapping: DateInterval(start: request.departAt, end: horizonEnd)
        )

        for accessLeg in access {
            let readyAt = request.departAt.addingTimeInterval(accessLeg.seconds)
            guard readyAt <= horizonEnd else { continue }

            var rides: [PartialRide] = []
            explore(
                from: accessLeg.station.id,
                readyAt: readyAt,
                rides: &rides,
                accessLeg: accessLeg,
                egressByStation: egressByStation,
                request: request,
                horizonEnd: horizonEnd,
                serviceDays: serviceDays,
                bestArrival: &bestArrival,
                results: &results
            )
        }
        return results
    }

    private func explore(
        from station: StationID,
        readyAt: Date,
        rides: inout [PartialRide],
        accessLeg: TerminalLeg,
        egressByStation: [StationID: TerminalLeg],
        request: PlanRequest,
        horizonEnd: Date,
        serviceDays: [ServiceDay],
        bestArrival: inout Date,
        results: inout [Journey]
    ) {
        guard rides.count <= options.maxTransfers else { return }

        for pattern in network.patterns(serving: station) {
            // Boarding the same pattern again is never an improvement: the next
            // trip of a pattern is by definition later than the one you are on.
            if let last = rides.last, last.pattern.id == pattern.id { continue }

            // SEPTA marks a few mid-route stops as ones where the train calls but the
            // doors don't open to board (and others, to alight). The departure board
            // honours that; the planner has to as well, or the two disagree and a
            // rider is told to board where they can't.
            guard let boardIndex = pattern.stopIndex(of: station),
                  pattern.stops[boardIndex].allowsBoarding else { continue }

            let earliest = readyAt.addingTimeInterval(options.boardingBufferSeconds)
            guard earliest <= horizonEnd,
                  let trip = timetable.nextTrip(
                      of: pattern,
                      departingFrom: station,
                      atOrAfter: earliest,
                      within: options.searchHorizon,
                      serviceDays: serviceDays
                  ),
                  let departure = timetable.departure(of: trip, at: station),
                  departure <= horizonEnd
            else { continue }

            // Never re-board the trip we just stepped off.
            if let last = rides.last, last.trip.id == trip.id { continue }

            for index in (boardIndex + 1)..<pattern.stops.count {
                let stop = pattern.stops[index]
                let arrival = trip.departure(atOffset: stop.arrivalOffset)

                // Any continuation of this branch arrives at or after `arrival`,
                // so once it is hopeless the rest of the branch is too.
                if arrival > bestArrival.addingTimeInterval(options.arrivalTolerance) { break }

                // The train calls here but won't let anyone off, so there is neither
                // an arrival to assemble nor a change to make at this stop.
                guard stop.allowsAlighting else { continue }

                let ride = PartialRide(
                    trip: trip,
                    pattern: pattern,
                    board: station,
                    alight: stop.station,
                    departure: departure,
                    arrival: arrival,
                    stations: pattern.stops[boardIndex...index].map(\.station)
                )
                rides.append(ride)

                if let egressLeg = egressByStation[stop.station],
                   let journey = assemble(
                       rides: rides,
                       accessLeg: accessLeg,
                       egressLeg: egressLeg,
                       request: request
                   ) {
                    if journey.arrivalTime < bestArrival { bestArrival = journey.arrivalTime }
                    results.append(journey)
                }

                // Only consider changing trains where more than one route calls.
                // At a mid-line stop every train goes the same way and the next one
                // is later than the one you are on, so getting off can only lose
                // time — and skipping those stops removes most of the search space
                // on a network the size of the full Metro map.
                let changeIsAllowed = !options.requiresStepFreeAccess
                    || network.station(stop.station)?.isAccessible == true
                if rides.count <= options.maxTransfers, network.isInterchange(stop.station), changeIsAllowed {
                    explore(
                        from: stop.station,
                        readyAt: arrival.addingTimeInterval(options.minTransferSeconds),
                        rides: &rides,
                        accessLeg: accessLeg,
                        egressByStation: egressByStation,
                        request: request,
                        horizonEnd: horizonEnd,
                        serviceDays: serviceDays,
                        bestArrival: &bestArrival,
                        results: &results
                    )
                }

                rides.removeLast()
            }
        }
    }

    // MARK: - Assembly

    private func assemble(
        rides: [PartialRide],
        accessLeg: TerminalLeg,
        egressLeg: TerminalLeg,
        request: PlanRequest
    ) -> Journey? {
        guard let first = rides.first else { return nil }

        // The rider does not need to leave when the planner started searching —
        // they need to leave in time to catch the first train. Reporting that
        // instant, rather than "now", is what makes the countdown honest.
        let leaveBy = first.departure.addingTimeInterval(-accessLeg.seconds - options.boardingBufferSeconds)
        let slack = leaveBy.timeIntervalSince(request.departAt)
        guard slack >= -30 else { return nil }

        var legs: [JourneyLeg] = []
        var cursor = leaveBy

        // A rider already standing in the station is not "walking to" it; that
        // time belongs to the platform wait instead.
        if accessLeg.straightLineMeters > 20 {
            legs.append(.walk(walkLeg(
                accessLeg,
                purpose: .access,
                from: request.origin.displayName,
                to: stationName(accessLeg.station.id),
                startingAt: cursor
            )))
            cursor = cursor.addingTimeInterval(accessLeg.seconds)
        }

        for (index, ride) in rides.enumerated() {
            let wait = ride.departure.timeIntervalSince(cursor)
            // Every positive gap becomes a leg, so the itinerary is contiguous in
            // time. The UI hides trivially short ones.
            if wait > 0 {
                legs.append(.wait(WaitLeg(
                    stationID: ride.board,
                    startTime: cursor,
                    duration: wait,
                    // A wait before the first train is unavoidable. A wait after
                    // getting off one *might* be a rider letting a faster train
                    // catch them up — but only the timetable can say so.
                    overtake: index > 0 ? overtake(switchingTo: ride, from: rides[index - 1]) : nil
                )))
            }
            legs.append(.ride(RideLeg(
                trip: ride.trip,
                patternID: ride.pattern.id,
                lineID: ride.pattern.lineID,
                routeID: ride.pattern.routeID,
                kind: ride.pattern.kind,
                direction: ride.pattern.direction,
                compass: ride.pattern.compass,
                headsign: ride.pattern.headsign,
                boardStation: ride.board,
                alightStation: ride.alight,
                departure: ride.departure,
                arrival: ride.arrival,
                stationsServed: ride.stations
            )))
            cursor = ride.arrival
        }

        if egressLeg.seconds > 0 {
            legs.append(.walk(walkLeg(
                egressLeg,
                purpose: .egress,
                from: stationName(egressLeg.station.id),
                to: request.destination.displayName,
                startingAt: cursor
            )))
        }
        let arrival = cursor.addingTimeInterval(egressLeg.seconds)

        return Journey(
            legs: legs,
            departureTime: leaveBy,
            arrivalTime: arrival,
            urgency: Urgency(leaveBy: leaveBy, boardingDeparture: first.departure, slack: slack)
        )
    }

    /// What restricting to step-free stations cost.
    ///
    /// A rider who gets a worse answer deserves to know the restriction caused it,
    /// so they can decide whether to relax it — rather than silently receiving a
    /// slower trip. Costs one extra unrestricted search, which is cheap and only
    /// happens when the setting is on.
    private func stepFreeNotes(request: PlanRequest, ranked: [Journey]) -> [PlanNote] {
        var unrestricted = options
        unrestricted.requiresStepFreeAccess = false
        let open = JourneyPlanner(network: network, calendar: timetable.calendar, options: unrestricted)

        let openBest = open.enumerateJourneys(
            request: request,
            access: open.terminalLegs(for: request.origin, role: .access, overrides: request.walkOverrides),
            egress: open.terminalLegs(for: request.destination, role: .egress, overrides: request.walkOverrides)
        ).map(\.arrivalTime).min()

        guard let openBest else { return [] }

        let stepFreeArrivals = ranked.filter { !$0.isWalkOnly }.map(\.arrivalTime)
        guard let stepFreeBest = stepFreeArrivals.min() else { return [.noStepFreeRouteFound] }

        let extra = stepFreeBest.timeIntervalSince(openBest)
        return extra >= 120 ? [.stepFreeCostsTime(extra: extra)] : []
    }

    /// The best option still available to a rider who misses this one's first train.
    private func missedCost(for journey: Journey, among candidates: [Journey]) -> MissedTrainCost? {
        guard let firstRide = journey.rides.first else { return nil }

        let alternatives = candidates.filter { other in
            guard let otherFirst = other.rides.first else {
                // Walking is always still available, and is genuinely the fallback
                // late at night.
                return !other.isWalkOnly ? false : true
            }
            // A later train is only a fallback if the rider can still set off for it
            // having missed this one. A later express from a station further away
            // can need leaving *earlier*, and pricing against it said "no need to
            // run" about a miss that really cost the next train after that.
            return otherFirst.departure > firstRide.departure
                && other.urgency.leaveBy > journey.urgency.leaveBy
        }

        var priced: [MissedTrainCost] = []

        // When each alternative actually gets a rider there who has just missed this
        // train. A train alternative already has a fixed departure, but the walk is
        // timed from the moment of planning — and nobody who missed the train set off
        // then. They set off at its leave-by at the earliest, so the walk starts there;
        // timing it from "now" understated the cost by however much slack was left.
        func arrivalAfterMissing(_ other: Journey) -> Date {
            guard other.isWalkOnly else { return other.arrivalTime }
            let lateStart = journey.urgency.leaveBy.timeIntervalSince(other.departureTime)
            return other.arrivalTime.addingTimeInterval(max(0, lateStart))
        }

        if let fallback = alternatives.min(by: { arrivalAfterMissing($0) < arrivalAfterMissing($1) }) {
            let fallbackArrival = arrivalAfterMissing(fallback)
            let penalty = fallbackArrival.timeIntervalSince(journey.arrivalTime)
            if penalty > 0 {
                priced.append(MissedTrainCost(
                    fallbackArrival: fallbackArrival,
                    fallbackBoarding: fallback.rides.first?.departure,
                    penalty: penalty
                ))
            }
        }
        if let sameTrain = nextTrainOnTheSamePattern(after: journey) {
            priced.append(sameTrain)
        }

        // Whichever fallback is actually better, because that is the one the rider
        // would take.
        return priced.min(by: { $0.penalty < $1.penalty })
    }

    /// The next departure of the same pattern, priced.
    ///
    /// This has to be computed rather than found among the candidates, because the
    /// search deliberately takes only the *next* trip of each pattern — a list of
    /// options should not contain the same itinerary twice twenty minutes apart. But
    /// it is the most natural fallback there is ("I'll get the next one"), and
    /// without it a line running a single stopping pattern has no priced fallback at
    /// all, so the run/don't-run advice can never fire on it. On the Broad Street Line
    /// the express and the Spur hide the gap; on the Norristown line nothing does.
    ///
    /// Restricted to single-ride journeys, where the penalty is exact: the rest of
    /// the trip is the same walk to the same door, so arriving `n` minutes later on
    /// the same train is `n` minutes later at the destination. With a change of train
    /// it would only be a lower bound, since the later train may miss the connection
    /// entirely — and a lower bound presented as a cost would understate the risk of
    /// the thing this warning exists to prevent.
    private func nextTrainOnTheSamePattern(after journey: Journey) -> MissedTrainCost? {
        guard journey.rides.count == 1,
              let ride = journey.rides.first,
              let pattern = network.pattern(ride.patternID) else { return nil }

        guard let next = timetable.nextTrip(
            of: pattern,
            departingFrom: ride.boardStation,
            atOrAfter: ride.departure.addingTimeInterval(1),
            within: options.searchHorizon
        ),
        let departure = timetable.departure(of: next, at: ride.boardStation),
        let arrival = timetable.arrival(of: next, at: ride.alightStation) else { return nil }

        let penalty = arrival.timeIntervalSince(ride.arrival)
        guard penalty > 0 else { return nil }
        return MissedTrainCost(
            fallbackArrival: journey.arrivalTime.addingTimeInterval(penalty),
            fallbackBoarding: departure,
            penalty: penalty
        )
    }

    private func stationName(_ id: StationID) -> String {
        network.station(id)?.displayName ?? id.rawValue
    }

    /// Decides whether changing from `previous` to `next` is genuinely an
    /// overtake, by asking the timetable rather than reading the shape of the
    /// itinerary.
    ///
    /// The train the rider steps off must (a) also serve where they are going,
    /// and (b) get there later than the train they step onto. Both conditions are
    /// necessary. Drop (a) and every branch connection becomes an "overtake";
    /// drop (b) and so does every change onto a slower train.
    private func overtake(switchingTo next: PartialRide, from previous: PartialRide) -> Overtake? {
        guard let pattern = network.pattern(previous.pattern.id),
              let boardIndex = pattern.stopIndex(of: previous.board),
              let destinationIndex = pattern.stopIndex(of: next.alight),
              // The abandoned train has to reach the destination *onward* from
              // where the rider got on, not somewhere behind them.
              destinationIndex > boardIndex,
              let stayedPut = timetable.arrival(of: previous.trip, at: next.alight)
        else { return nil }

        // Switching has to actually gain time, or nothing overtook anybody.
        guard stayedPut > next.arrival else { return nil }

        return Overtake(
            boardedAt: previous.board,
            switchedAt: previous.alight,
            comparedAt: next.alight,
            arrivalIfTheyHadStayedPut: stayedPut,
            arrival: next.arrival
        )
    }

    // MARK: - Ranking

    /// Keep only options a rider might reasonably prefer, best arrival first.
    func rank(_ journeys: [Journey]) -> [Journey] {
        var unique: [String: Journey] = [:]
        for journey in journeys {
            // Riding the same two trains between the same two places is one
            // option, not five, even when there are five stations where the
            // change is technically possible. Keep the version with the least
            // time on a platform — that is the one worth telling a rider about.
            let key = collapseKey(journey)
            if let existing = unique[key], existing.waitingTime <= journey.waitingTime { continue }
            unique[key] = journey
        }

        let all = Array(unique.values)
        guard let bestArrival = all.map(\.arrivalTime).min() else { return [] }
        let cutoff = bestArrival.addingTimeInterval(options.arrivalTolerance)

        let viable = all.filter { $0.arrivalTime <= cutoff }
        let pareto = viable.filter { candidate in
            !viable.contains { other in
                other.id != candidate.id && dominates(other, candidate)
            }
        }

        return collapseTiedArrivals(pareto).sorted { isBetter($0, than: $1) }
    }

    /// The rider's order of preference, in one place.
    ///
    /// When you get there comes first, because that is the question. Everything after
    /// it separates options that answer it identically, cheapest-to-obtain first: the
    /// trip that takes less of your day, then the one that walks you less, then the one
    /// that keeps you on a train for less of it, then the one that leaves you standing
    /// on a platform for less of it.
    ///
    /// The last two barely ever decide anything, and that is fine — with the total and
    /// the walk already equal, riding and waiting are what is left of the same number,
    /// so shortening one lengthens the other. They are here to say which way round the
    /// rider would rather have it.
    ///
    /// Ends on the id, so the order never depends on how a dictionary happened to
    /// enumerate its values.
    func isBetter(_ a: Journey, than b: Journey) -> Bool {
        if a.arrivalTime != b.arrivalTime { return a.arrivalTime < b.arrivalTime }
        return isBetterIgnoringArrival(a, than: b)
    }

    /// The same order with the first question already settled, for choosing between
    /// options that arrive together.
    private func isBetterIgnoringArrival(_ a: Journey, than b: Journey) -> Bool {
        if a.totalDuration != b.totalDuration { return a.totalDuration < b.totalDuration }
        if a.walkingTime != b.walkingTime { return a.walkingTime < b.walkingTime }
        if a.ridingTime != b.ridingTime { return a.ridingTime < b.ridingTime }
        if a.waitingTime != b.waitingTime { return a.waitingTime < b.waitingTime }
        return a.id < b.id
    }

    /// One option per arrival minute: the one that takes the least time to make.
    ///
    /// Landing at the door at the same minute is not two choices. Whichever takes
    /// longer is asking the rider to set off earlier and gain nothing by it, and the
    /// pair are usually the same trip anyway — two stations a similar walk away, one
    /// of them further along the line, so the train reaches the destination at the
    /// same moment either way.
    ///
    /// Pareto filtering could not remove them, and correctly so on its own terms: the
    /// further station costs more walking, the nearer one costs a longer wait, so
    /// neither is better on every axis. But the axes are the wrong thing to weigh once
    /// the arrivals match. Arrival is the question this app answers, and when two
    /// answers agree the only thing left to compare is what each one costs to obtain.
    ///
    /// Minutes, not seconds, because that is the resolution a rider is shown. Two
    /// options they both read as "8:31" must not both be listed on the strength of a
    /// difference they cannot see.
    private func collapseTiedArrivals(_ journeys: [Journey]) -> [Journey] {
        var best: [Int: Journey] = [:]
        var order: [Int] = []
        for journey in journeys {
            let minute = Int((journey.arrivalTime.timeIntervalSinceReferenceDate / 60).rounded(.down))
            if let incumbent = best[minute] {
                if isBetterIgnoringArrival(journey, than: incumbent) { best[minute] = journey }
            } else {
                best[minute] = journey
                order.append(minute)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// Identifies journeys that are "the same plan" from a rider's point of view:
    /// same trains, boarded at the same place, ending at the same place.
    private func collapseKey(_ journey: Journey) -> String {
        let trips = journey.rides.map(\.trip.id).joined(separator: ">")
        let board = journey.boardStation?.rawValue ?? "-"
        let alight = journey.alightStation?.rawValue ?? "-"
        return "\(board)|\(trips)|\(alight)"
    }

    /// `a` dominates `b` when it is at least as good on every axis a rider cares
    /// about and strictly better on one.
    ///
    /// Leaving *later* counts as better — a plan you can start in ten minutes
    /// beats an identical one you must start now — but the indifference band on
    /// that axis has to be wide. At thirty seconds, riding two stops the wrong
    /// way and doubling back survives the filter purely because it buys a minute
    /// and a half of extra slack while arriving seven minutes later. Two minutes
    /// matches how much extra slack a rider actually notices.
    private func dominates(_ a: Journey, _ b: Journey) -> Bool {
        let arrivalOK = a.arrivalTime <= b.arrivalTime
        let transfersOK = a.transferCount <= b.transferCount
        // Sub-minute walking differences are noise from the distance model.
        let walkOK = a.walkingTime <= b.walkingTime + 60
        let departureOK = a.departureTime >= b.departureTime.addingTimeInterval(-120)
        guard arrivalOK, transfersOK, walkOK, departureOK else { return false }

        let strictlyBetter =
            a.arrivalTime < b.arrivalTime.addingTimeInterval(-30) ||
            a.transferCount < b.transferCount ||
            a.walkingTime + 120 < b.walkingTime ||
            a.departureTime > b.departureTime.addingTimeInterval(180)
        return strictlyBetter
    }

    // MARK: - Notes

    private func serviceNotes(request: PlanRequest, journeys: [Journey], access: [TerminalLeg]) -> [PlanNote] {
        var notes: [PlanNote] = []

        let ridesExist = journeys.contains { !$0.isWalkOnly }
        let usesExpress = journeys.contains(where: \.usesExpress)
        let expressPatterns = network.patterns.filter { $0.kind == .express }

        if ridesExist, !usesExpress, !expressPatterns.isEmpty {
            // Only mention express if it could actually have served this trip —
            // telling a rider in South Philadelphia that they missed the express
            // is noise, because it never goes there.
            let boardStations = Set(journeys.compactMap(\.boardStation))
            let alightStations = Set(journeys.compactMap(\.alightStation))
            let relevant = expressPatterns.filter { pattern in
                boardStations.contains(where: pattern.serves) && alightStations.contains(where: pattern.serves)
            }
            if !relevant.isEmpty {
                let next = relevant.compactMap { pattern -> Date? in
                    guard let board = boardStations.first(where: pattern.serves) else { return nil }
                    return timetable.nextTrip(
                        of: pattern,
                        departingFrom: board,
                        atOrAfter: request.departAt,
                        within: 14 * 3600
                    ).flatMap { timetable.departure(of: $0, at: board) }
                }.min()
                notes.append(.expressNotRunningNow(nextDeparture: next))
            }
        }

        if ridesExist, journeys.allSatisfy({ $0.isWalkOnly || $0.rides.allSatisfy { $0.kind == .nightBus } }) {
            notes.append(.nightServiceOnly)
        }

        // Deliberately the *exhaustion* date, not the authoritative one. SEPTA's
        // rail timetables change a few times a year while its feed windows are a
        // fortnight wide, so warning at the fortnight would mean warning almost
        // always — and a notice a rider has learned to scroll past is worse than no
        // notice at all. Whether a newer feed actually exists is a question only the
        // network can answer, and the app asks it separately.
        if network.provenance.hasNoServiceData(asOf: request.departAt) {
            let end = network.provenance.servicesUntil ?? network.provenance.validUntil ?? ""
            notes.append(.scheduleOutOfDate(feedEndDate: end))
        }

        return notes
    }
}
