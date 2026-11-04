import Foundation

/// The bus + Regional Rail network, loaded once from the bundle on first use.
///
/// Off the main actor, lazily: it is a few MB of text and only the supplemental
/// "More ways" section needs it, so the Metro answer never waits on it.
enum ExtendedData {
    static let network: ExtendedNetwork? = {
        guard let url = Bundle.main.url(forResource: "SEPTAExtended", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? ExtendedNetwork.decode(text)
    }()
}

/// Anything that gets the rider there, reduced to what value ranking needs.
struct ValueCandidate: Identifiable {
    enum Kind {
        case metro(Journey)
        case extended(ExtendedItinerary)
        case indego(IndegoOption)
        case driving(DrivingEstimate)
    }

    var id: String
    var kind: Kind
    var title: String
    var leaveBy: Date
    var arrival: Date
    var fare: Double
    /// Time spent pedalling uphill on a classic bike. Already inside the travel
    /// time; counted a second time in value, because a climb costs effort as
    /// well as minutes — which is what makes the e-bike win on hills.
    var effortSeconds: TimeInterval = 0

    /// Door-to-door travel time — the time actually spent getting there.
    var travelTime: TimeInterval { max(0, arrival.timeIntervalSince(leaveBy)) }

    func cost(perHour rate: Double) -> Double {
        fare + (travelTime + effortSeconds) / 3600 * rate
    }
}

extension CommuteModel {
    // MARK: Coordinates of the two ends

    func coordinate(of endpoint: Endpoint?) -> Coordinate? {
        switch endpoint {
        case .place(_, let coordinate)?: return coordinate
        case .station(let id)?: return network.station(id)?.coordinate
        case nil: return nil
        }
    }

    var originCoordinate: Coordinate? { coordinate(of: resolvedOrigin) }

    /// True when the trip starts from wherever the phone is.
    var isPlanningFromCurrentLocation: Bool {
        if case .currentLocation = source { return true }
        return false
    }
    var destinationCoordinate: Coordinate? { coordinate(of: resolvedTarget) }

    // MARK: Planning the extras

    /// Bike share and the all-SEPTA alternatives, alongside — never instead of —
    /// the Metro plan.
    func planSupplemental() {
        updateDrivingEstimate()
        if preferences.showIndego {
            indego.refreshIfNeeded()
            updateIndegoOptions()
        } else {
            indegoOptions = []
        }

        guard preferences.showAllSEPTA,
              let origin = originCoordinate,
              let destination = destinationCoordinate else {
            cancelAlternativesSearch()
            extendedItineraries = []
            return
        }
        var walking = preferences.plannerOptions().walking
        walking.metersPerSecond = preferences.walkingMilesPerHour * Coordinate.metersPerMile / 3600
        let margin = preferences.boardingBufferSeconds
        let now = Date()

        // Replans come every thirty seconds and on every location fix. The search
        // is five full passes over all of SEPTA, so it runs only when something it
        // depends on has changed: the two ends (to ~50 m), the minute, the settings.
        func rounded(_ c: Coordinate) -> String { String(format: "%.4f,%.4f", c.latitude, c.longitude) }
        let endpoints = rounded(origin) + ">" + rounded(destination)
        let key = "\(endpoints)|\(Int(now.timeIntervalSince1970 / 60))|\(walking.metersPerSecond)|\(margin)"
        guard key != extendedSearchKey else { return }
        extendedSearchKey = key
        // A different trip: the old trip's alternatives must not sit under the new
        // answer, compared against it, while the search runs.
        if endpoints != extendedEndpoints {
            extendedItineraries = []
            extendedEndpoints = endpoints
        }

        extendedTask?.cancel()
        extendedTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) { () -> [ExtendedItinerary]? in
                guard let network = ExtendedData.network else { return [] }
                var planner = ExtendedPlanner(network: network, walking: walking, boardingMarginSeconds: margin)
                // One search returns the fastest option per number of rides, so on its
                // own the fastest mode wins everything and a cheaper-but-slower one
                // (a bus instead of Regional Rail) is never seen. Searching again with
                // each mode left out puts every mode on equal footing; the price/time
                // frontier below decides what is worth showing.
                let exclusions: [Set<ExtendedMode>] = [[], [.rail], [.metro, .trolley], [.bus], [.rail, .metro, .trolley]]
                var seen = Set<String>()
                var found: [ExtendedItinerary] = []
                for excluded in exclusions {
                    if Task.isCancelled { return nil }
                    planner.excludedModes = excluded
                    for itinerary in planner.plan(from: origin, to: destination, departAt: now) where !itinerary.rides.isEmpty {
                        let key = itinerary.rides.map { "\($0.routeShortName)@\(Int($0.departure.timeIntervalSince1970))" }.joined(separator: ">")
                        if seen.insert(key).inserted { found.append(itinerary) }
                    }
                }
                return found.sorted { $0.arrival < $1.arrival }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, let result else { return }
            self.extendedItineraries = result
        }
    }

    /// The car, priced, when the rider has one and Best value is on — nothing
    /// else uses it.
    private func updateDrivingEstimate() {
        guard preferences.hasCar,
              preferences.valueOfTimePerHour != nil,
              let origin = originCoordinate,
              let destination = destinationCoordinate,
              origin.distance(to: destination) > 400 else {
            if !drivingEstimates.isEmpty { drivingEstimates = [] }
            return
        }
        let car = preferences.car
        Task { [weak self] in
            let estimates = await DrivingService.shared.estimates(from: origin, to: destination, car: car, now: Date())
            guard let self, self.originCoordinate == origin, self.destinationCoordinate == destination else { return }
            if self.drivingEstimates != estimates { self.drivingEstimates = estimates }
        }
    }

    func cancelAlternativesSearch() {
        extendedTask?.cancel()
        extendedTask = nil
        extendedSearchKey = nil
    }

    /// Dock counts older than this are not "live" any more, and a bike that was
    /// there ten minutes ago is a guess.
    private static let indegoMaxAge: TimeInterval = 10 * 60

    func updateIndegoOptions() {
        guard preferences.showIndego,
              let origin = originCoordinate,
              let destination = destinationCoordinate,
              let updated = indego.lastUpdated,
              Date().timeIntervalSince(updated) < Self.indegoMaxAge,
              !indego.stations.isEmpty else {
            indegoOptions = []
            return
        }
        var walking = preferences.plannerOptions().walking
        walking.metersPerSecond = preferences.walkingMilesPerHour * Coordinate.metersPerMile / 3600
        var planner = IndegoPlanner(walking: walking, pass: preferences.indegoPass)
        planner.routes = bikeRoutes
        let options = planner.options(from: origin, to: destination, stations: indego.stations, departAt: Date())
        indegoOptions = options

        // Measure the chosen rides (route length and climb), then plan again with
        // them. A measured ride can change which docks win; those get measured on
        // the next pass, and the cache settles it.
        let unmeasured = options
            .map { (key: IndegoPlanner.routeKey(from: $0.pickup, to: $0.dropoff), from: $0.pickup.coordinate, to: $0.dropoff.coordinate) }
            .filter { bikeRoutes[$0.key] == nil }
        guard !unmeasured.isEmpty else { return }
        Task { [weak self] in
            let changed = await BikeRouteService.shared.measure(unmeasured)
            let all = await BikeRouteService.shared.all
            guard changed, let self else { return }
            self.bikeRoutes = all
            self.updateIndegoOptions()
        }
    }

    /// Bike options worth listing: those nothing else on screen beats on both
    /// price and arrival. A bike that costs more and arrives later than a train
    /// (or than the other bike) is just noise. Worked out when shown, so it is
    /// always against the current plan rather than whichever landed first.
    ///
    /// Only rides measured along a real cycling route are shown. The straight-line
    /// estimate exists to pick which docks to ask Apple Maps about — the planner
    /// weighs dozens of dock pairs, far more than MapKit allows requests for —
    /// and is never what the rider sees.
    var visibleIndegoOptions: [IndegoOption] { frontier(of: indegoOptions.filter(\.isMeasured)) }

    private func frontier(of options: [IndegoOption]) -> [IndegoOption] {
        let fareRules = network.fare
        func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }
        func cents(_ amount: Double) -> Int { Int((amount * 100).rounded()) }
        let transit: [(Int, Int)] = (plan?.journeys ?? []).map {
            ($0.isWalkOnly ? 0 : cents($0.fare(fareRules)?.withFreeTransfers ?? 0), minute($0.arrivalTime))
        }
        return options.filter { option in
            let c = cents(option.price), m = minute(option.arrival)
            let beaten: ((Int, Int)) -> Bool = { $0.0 <= c && $0.1 <= m && ($0.0 < c || $0.1 < m) }
            if transit.contains(where: beaten) { return false }
            let others = options.filter { $0.id != option.id }.map { (cents($0.price), minute($0.arrival)) }
            return !others.contains(where: beaten)
        }
    }

    /// The classic option, when its route climbs enough that the e-bike is worth
    /// suggesting.
    var hillyClassic: IndegoOption? {
        indegoOptions.first { $0.bike == .classic && ($0.climbMeters ?? 0) >= Self.hillyClimbMeters }
    }

    /// About six storeys: enough to arrive sweaty on a classic bike.
    static let hillyClimbMeters: Double = 20

    // MARK: Alternative routes

    /// Every transit option from the all-of-SEPTA search that is on the price/time
    /// frontier — nothing else on the screen is both at least as cheap and gets
    /// there at least as soon. The Metro planner's options take part as rivals, so
    /// an alternative that merely repeats one of them (or loses to one) is hidden.
    var alternativeRoutes: [ExtendedItinerary] {
        let fareRules = network.fare
        let now = Date()
        // Minutes, because two arrivals a few seconds apart are the same to a rider.
        func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }
        func cents(_ amount: Double) -> Int { Int((amount * 100).rounded()) }

        let rivals: [(cents: Int, minute: Int)] = (plan?.journeys ?? [])
            .filter { !$0.isWalkOnly }
            .map { (cents($0.fare(fareRules)?.withFreeTransfers ?? 0), minute($0.arrivalTime)) }

        var kept: [ExtendedItinerary] = []
        // An option whose leave-by has passed can't be caught; the list is only as
        // fresh as the last search, so that is checked here, at display time.
        // A trip on the Metro alone is the main planner's to answer: it times
        // station entry, exit and transfers that this search leaves out, so the
        // same train would show up here a couple of minutes "sooner". Those live
        // above; this list is for what buses and Regional Rail add.
        let candidates = extendedItineraries
            .filter(\.usesBusOrRail)
            .filter { $0.leaveBy.timeIntervalSince(now) > -30 }
            .sorted { (cents($0.fare), $0.arrival) < (cents($1.fare), $1.arrival) }
        for candidate in candidates {
            let m = minute(candidate.arrival)
            // An unpriced fare can't claim to be cheap: it competes on time alone.
            let c = candidate.fareIsKnown ? cents(candidate.fare) : Int.max
            // Ties go to what is already shown: the Metro answer, then whatever
            // was kept first (cheaper, then sooner).
            if rivals.contains(where: { $0.cents <= c && $0.minute <= m }) { continue }
            if kept.contains(where: { ($0.fareIsKnown ? cents($0.fare) : Int.max) <= c && minute($0.arrival) <= m }) { continue }
            kept.append(candidate)
        }
        return Array(kept.sorted { $0.arrival < $1.arrival }.prefix(4))
    }

    /// The lowest price of anything else on screen, for the Indego badge. Walking
    /// counts, at nothing.
    var cheapestNonBikeFare: Double? {
        let fareRules = network.fare
        let metro = (plan?.journeys ?? []).map { $0.isWalkOnly ? 0 : ($0.fare(fareRules)?.withFreeTransfers ?? 0) }
        let alternatives = alternativeRoutes.filter(\.fareIsKnown).map(\.fare)
        return (metro + alternatives).min()
    }

    /// True when this bike option is the cheapest way there of everything listed.
    func isCheapestOverall(_ option: IndegoOption) -> Bool {
        let bikes = visibleIndegoOptions.map(\.price).min() ?? .infinity
        guard option.price <= bikes + 0.005 else { return false }
        guard let other = cheapestNonBikeFare else { return true }
        return option.price < other - 0.005
    }

    /// What the main answer is, for "sooner/later than …" — it isn't always a train.
    var referenceNoun: String {
        guard let best = plan?.best else { return "the train" }
        if best.isWalkOnly { return "walking" }
        if best.rides.allSatisfy({ $0.kind == .nightBus }) { return "the bus" }
        return "the train"
    }

    // MARK: Value ranking

    /// Every option on screen, cheapest overall first, when the rider has priced
    /// their time. `nil` when value ranking is off.
    var valueRanking: [ValueCandidate]? {
        guard let rate = preferences.valueOfTimePerHour, rate > 0 else { return nil }
        var candidates: [ValueCandidate] = []
        let fareRules = network.fare
        for journey in plan?.journeys ?? [] {
            let fare = journey.fare(fareRules)?.withFreeTransfers ?? 0
            let title = journey.isWalkOnly ? "Walk" : journey.rides.map(\.routeBadge).joined(separator: " → ")
            candidates.append(ValueCandidate(
                id: "metro-" + journey.id,
                kind: .metro(journey),
                title: title,
                leaveBy: journey.isWalkOnly ? journey.departureTime : journey.urgency.leaveBy,
                arrival: journey.arrivalTime,
                fare: fare
            ))
        }
        for itinerary in alternativeRoutes where itinerary.fareIsKnown {
            candidates.append(ValueCandidate(
                id: "ext-" + itinerary.id,
                kind: .extended(itinerary),
                title: itinerary.rides.map(\.routeShortName).joined(separator: " → "),
                leaveBy: itinerary.leaveBy,
                arrival: itinerary.arrival,
                fare: itinerary.fare
            ))
        }
        for option in visibleIndegoOptions {
            candidates.append(ValueCandidate(
                id: "indego-" + option.id,
                kind: .indego(option),
                title: "Indego \(option.bike.label.lowercased())",
                leaveBy: option.leaveAt,
                arrival: option.arrival,
                fare: option.price,
                effortSeconds: option.bike == .classic ? option.climbSeconds : 0
            ))
        }
        for drive in drivingEstimates {
            let via = drive.name.isEmpty ? "" : " via \(drive.name)"
            let toll = drive.tolls.isEmpty ? "" : " (\(drive.tolls.map(\.name).joined(separator: ", ")))"
            candidates.append(ValueCandidate(
                id: drive.id,
                kind: .driving(drive),
                title: "Drive" + via + toll,
                leaveBy: drive.departure,
                arrival: drive.arrival,
                fare: drive.cost
            ))
        }
        // Only what's on the price/arrival frontier: an option that costs more and
        // arrives later than another is never the better pick, whatever the rate.
        func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }
        func cents(_ amount: Double) -> Int { Int((amount * 100).rounded()) }
        let frontier = candidates.filter { candidate in
            !candidates.contains { other in
                other.id != candidate.id
                    && cents(other.fare) <= cents(candidate.fare) && minute(other.arrival) <= minute(candidate.arrival)
                    && (cents(other.fare) < cents(candidate.fare) || minute(other.arrival) < minute(candidate.arrival))
            }
        }
        return frontier.sorted { $0.cost(perHour: rate) < $1.cost(perHour: rate) }
    }
}
