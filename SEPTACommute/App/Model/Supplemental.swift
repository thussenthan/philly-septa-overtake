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
    }

    var id: String
    var kind: Kind
    var title: String
    var leaveBy: Date
    var arrival: Date
    var fare: Double

    /// Door-to-door travel time — the time actually spent getting there.
    var travelTime: TimeInterval { max(0, arrival.timeIntervalSince(leaveBy)) }

    func cost(perHour rate: Double) -> Double {
        fare + travelTime / 3600 * rate
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
    var destinationCoordinate: Coordinate? { coordinate(of: resolvedTarget) }

    // MARK: Planning the extras

    /// Bike share and bus/rail, alongside — never instead of — the Metro plan.
    func planSupplemental() {
        if preferences.showIndego {
            indego.refreshIfNeeded()
            updateIndegoOptions()
        } else {
            indegoOptions = []
        }

        extendedTask?.cancel()
        guard preferences.showAllSEPTA,
              let origin = originCoordinate,
              let destination = destinationCoordinate else {
            extendedItineraries = []
            return
        }
        var walking = preferences.plannerOptions().walking
        walking.metersPerSecond = preferences.walkingMilesPerHour * Coordinate.metersPerMile / 3600
        let margin = preferences.boardingBufferSeconds
        let now = Date()
        extendedTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> [ExtendedItinerary] in
                guard let network = ExtendedData.network else { return [] }
                var planner = ExtendedPlanner(network: network, walking: walking, boardingMarginSeconds: margin)
                let mixed = planner.plan(from: origin, to: destination, departAt: now)
                // The Metro wins most city trips outright, which would leave the bus
                // invisible. Asking again without it shows what the bus would do.
                planner.excludedModes = [.metro, .trolley]
                let withoutMetro = planner.plan(from: origin, to: destination, departAt: now)
                var seen = Set<String>()
                return (mixed + withoutMetro)
                    .filter { seen.insert($0.rides.map { "\($0.routeShortName)@\($0.departure.timeIntervalSince1970)" }.joined(separator: ">")).inserted }
                    .sorted { $0.arrival < $1.arrival }
            }.value
            guard !Task.isCancelled, let self else { return }
            // The Metro planner already covers trips on the Metro alone; this list
            // is for what only buses or Regional Rail make possible.
            self.extendedItineraries = Array(result.filter(\.usesBusOrRail).prefix(3))
        }
    }

    func updateIndegoOptions() {
        guard preferences.showIndego,
              let origin = originCoordinate,
              let destination = destinationCoordinate,
              !indego.stations.isEmpty else {
            if !preferences.showIndego { indegoOptions = [] }
            return
        }
        var walking = preferences.plannerOptions().walking
        walking.metersPerSecond = preferences.walkingMilesPerHour * Coordinate.metersPerMile / 3600
        let planner = IndegoPlanner(walking: walking, pass: preferences.indegoPass)
        indegoOptions = planner.options(from: origin, to: destination, stations: indego.stations, departAt: Date())
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
        for itinerary in extendedItineraries {
            candidates.append(ValueCandidate(
                id: "ext-" + itinerary.id,
                kind: .extended(itinerary),
                title: itinerary.rides.map(\.routeShortName).joined(separator: " → "),
                leaveBy: itinerary.leaveBy,
                arrival: itinerary.arrival,
                fare: itinerary.fare
            ))
        }
        for option in indegoOptions {
            candidates.append(ValueCandidate(
                id: "indego-" + option.id,
                kind: .indego(option),
                title: "Indego \(option.bike.label.lowercased())",
                leaveBy: option.leaveAt,
                arrival: option.arrival,
                fare: option.price
            ))
        }
        return candidates.sorted { $0.cost(perHour: rate) < $1.cost(perHour: rate) }
    }
}
