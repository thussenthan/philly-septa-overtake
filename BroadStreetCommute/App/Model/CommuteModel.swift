import Combine
import Foundation

/// Rider-adjustable knobs, persisted.
struct RiderPreferences: Codable, Equatable {
    var walkingMilesPerHour: Double = 3.0
    /// Longest walk to a station the rider will entertain, in minutes.
    var maxWalkMinutes: Double = 18
    /// Extra seconds of safety margin before every boarding.
    var boardingBufferSeconds: Double = 30
    /// Whether to spend network calls on real walking directions.
    var useMeasuredWalkTimes: Bool = true
    /// Whether to consider itineraries with a change of train.
    var allowTransfers: Bool = true

    static let storageKey = "riderPreferences.v1"

    func plannerOptions() -> PlannerOptions {
        var options = PlannerOptions()
        options.walking.milesPerHour = walkingMilesPerHour
        options.maxWalkSeconds = maxWalkMinutes * 60
        options.boardingBufferSeconds = boardingBufferSeconds
        options.maxTransfers = allowTransfers ? 2 : 0
        return options
    }
}

/// Where the rider is heading.
enum Target: Hashable, Identifiable {
    case saved(SavedPlace)
    case station(StationID)

    var id: String {
        switch self {
        case .saved(let place): return "place-\(place.id.uuidString)"
        case .station(let id): return "station-\(id.rawValue)"
        }
    }
}

/// Where the rider is starting from.
enum Source: Hashable {
    case currentLocation
    case station(StationID)
    case saved(SavedPlace)
}

/// Owns the app's state: what the rider asked for, where they are, and the plan.
@MainActor
final class CommuteModel: ObservableObject {
    // MARK: Inputs

    @Published var source: Source = .currentLocation
    @Published var target: Target?
    @Published var preferences = RiderPreferences() {
        didSet {
            guard preferences != oldValue else { return }
            persistPreferences()
            replan()
        }
    }

    // MARK: Outputs

    @Published private(set) var plan: Plan?
    @Published private(set) var advice: String?
    /// Set when the rider is standing in (or right next to) a station.
    @Published private(set) var currentStation: Station?
    @Published private(set) var lastPlannedAt: Date?
    @Published private(set) var isRefreshing = false

    let network: Network
    let narrator: JourneyNarrator
    let locationService: LocationService
    let walkTimes: WalkTimeService
    let places: PlaceStore

    private var cancellables: Set<AnyCancellable> = []
    private var timer: AnyCancellable?
    private let defaults: UserDefaults

    /// How close counts as "you are at this station".
    private let atStationMeters: Double = 160

    init(
        network: Network = BSLData.network,
        places: PlaceStore,
        locationService: LocationService = LocationService(),
        walkTimes: WalkTimeService = WalkTimeService(),
        defaults: UserDefaults = .standard
    ) {
        self.network = network
        self.narrator = JourneyNarrator(network: network)
        self.places = places
        self.locationService = locationService
        self.walkTimes = walkTimes
        self.defaults = defaults

        if let data = defaults.data(forKey: RiderPreferences.storageKey),
           let saved = try? JSONDecoder().decode(RiderPreferences.self, from: data) {
            preferences = saved
        }

        target = places.home.map(Target.saved) ?? places.school.map(Target.saved)

        locationService.$status
            .removeDuplicates()
            .sink { [weak self] _ in self?.locationChanged() }
            .store(in: &cancellables)

        places.$places
            .sink { [weak self] updated in self?.placesChanged(updated) }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func onAppear() {
        locationService.requestPermissionIfNeeded()
        startTicking()
        replan()
    }

    func onDisappear() {
        timer?.cancel()
        timer = nil
        locationService.stop()
    }

    /// Replanning every thirty seconds keeps countdowns from drifting into
    /// recommending a train that has already gone.
    private func startTicking() {
        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.replan() }
    }

    func refresh() async {
        isRefreshing = true
        locationService.refresh()
        replan()
        // A brief hold so a pull-to-refresh reads as having done something even
        // when the plan is unchanged.
        try? await Task.sleep(nanoseconds: 350_000_000)
        isRefreshing = false
    }

    // MARK: - Reacting to change

    private func locationChanged() {
        updateCurrentStation()
        replan()
    }

    private func placesChanged(_ updated: [SavedPlace]) {
        // Keep pointing at the same role if its address was edited.
        if case .saved(let place) = target {
            if let refreshed = updated.first(where: { $0.id == place.id }) {
                target = .saved(refreshed)
            } else if let sameRole = updated.first(where: { $0.role == place.role }) {
                target = .saved(sameRole)
            } else {
                target = updated.first.map(Target.saved)
            }
        } else if target == nil {
            target = updated.first.map(Target.saved)
        }
        replan()
    }

    private func updateCurrentStation() {
        guard let coordinate = locationService.coordinate else {
            currentStation = nil
            return
        }
        guard let nearest = network.nearestStation(to: coordinate), nearest.meters <= atStationMeters else {
            currentStation = nil
            return
        }
        currentStation = nearest.station
    }

    // MARK: - Endpoints

    /// The origin to plan from, resolving "current location" to a station when
    /// the rider is standing in one — that removes a pointless "walk 0 min" leg
    /// and makes the countdown match the platform sign.
    var resolvedOrigin: Endpoint? {
        switch source {
        case .station(let id):
            return .station(id)
        case .saved(let place):
            return place.endpoint
        case .currentLocation:
            if let station = currentStation { return .station(station.id) }
            guard let coordinate = locationService.coordinate else { return nil }
            return .place(name: "Current location", coordinate: coordinate)
        }
    }

    var resolvedTarget: Endpoint? {
        switch target {
        case .saved(let place): return place.endpoint
        case .station(let id): return .station(id)
        case nil: return nil
        }
    }

    var targetName: String {
        switch target {
        case .saved(let place): return place.name
        case .station(let id): return network.station(id)?.name ?? id.rawValue
        case nil: return "Nowhere yet"
        }
    }

    /// Destinations offered in the picker: the saved places, then every station.
    var quickTargets: [Target] {
        places.places.map(Target.saved)
    }

    // MARK: - Planning

    func replan() {
        guard let origin = resolvedOrigin, let destination = resolvedTarget else {
            plan = nil
            advice = nil
            return
        }

        let now = Date()
        var options = preferences.plannerOptions()
        options.maxResults = 6

        let planner = JourneyPlanner(network: network, options: options)

        // First pass with estimates, so something is on screen immediately.
        let overrides = preferences.useMeasuredWalkTimes
            ? walkTimes.overrides(
                from: origin.coordinate,
                to: destination.coordinate,
                accessStations: candidateStations(near: origin.coordinate, limit: options.maxAccessStations),
                egressStations: candidateStations(near: destination.coordinate, limit: options.maxEgressStations)
            )
            : .none

        let result = planner.plan(PlanRequest(
            origin: origin,
            destination: destination,
            departAt: now,
            walkOverrides: overrides
        ))

        plan = result
        advice = narrator.advice(for: result, asOf: now)
        lastPlannedAt = now

        guard preferences.useMeasuredWalkTimes else { return }
        walkTimes.measure(
            from: origin.coordinate,
            to: destination.coordinate,
            accessStations: candidateStations(near: origin.coordinate, limit: options.maxAccessStations),
            egressStations: candidateStations(near: destination.coordinate, limit: options.maxEgressStations),
            onUpdate: { [weak self] in
                // Measured walks can reorder the options, so replan — but without
                // re-triggering measurement, which `measure` guards by cache.
                self?.replanUsingCachedWalkTimes()
            }
        )
    }

    private func replanUsingCachedWalkTimes() {
        guard let origin = resolvedOrigin, let destination = resolvedTarget else { return }
        var options = preferences.plannerOptions()
        options.maxResults = 6
        let now = Date()
        let overrides = walkTimes.overrides(
            from: origin.coordinate,
            to: destination.coordinate,
            accessStations: candidateStations(near: origin.coordinate, limit: options.maxAccessStations),
            egressStations: candidateStations(near: destination.coordinate, limit: options.maxEgressStations)
        )
        let result = JourneyPlanner(network: network, options: options).plan(PlanRequest(
            origin: origin,
            destination: destination,
            departAt: now,
            walkOverrides: overrides
        ))
        plan = result
        advice = narrator.advice(for: result, asOf: now)
        lastPlannedAt = now
    }

    private func candidateStations(near coordinate: Coordinate?, limit: Int) -> [Station] {
        guard let coordinate else { return [] }
        let radius = preferences.maxWalkMinutes * 60 * (preferences.walkingMilesPerHour * 0.44704)
        return network.stations(near: coordinate, within: max(radius, 500))
            .prefix(limit)
            .map(\.station)
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: RiderPreferences.storageKey)
    }

    // MARK: - Derived view state

    var stationsNorthToSouth: [Station] {
        network.stationsSorted(by: .southbound, on: "B")
    }

    /// The plan's notes, as sentences a rider can act on.
    var noteMessages: [String] {
        (plan?.notes ?? []).compactMap { note in
            switch note {
            case .walkingIsFaster(let saving):
                return "Walking beats the train right now by \(Format.minutes(saving))."
            case .expressNotRunningNow(let next):
                if let next {
                    return "No express right now. The next one leaves at \(Format.clock(next))."
                }
                return "No express service right now — it runs weekday peaks only."
            case .nightServiceOnly:
                return "Trains have stopped for the night. These are the B1 Owl bus times, which runs along Broad St at street level."
            case .scheduleOutOfDate(let end):
                return "This timetable was published through \(Self.humanDate(end)) and may be out of date. Check septa.org before relying on it."
            case .originTooFarFromLine(let station, let meters):
                return "You're \(Format.distance(meters: meters)) from the nearest station (\(network.station(station)?.name ?? station.rawValue)) — too far to walk within your limit."
            case .destinationTooFarFromLine(let station, let meters):
                return "Your destination is \(Format.distance(meters: meters)) from \(network.station(station)?.name ?? station.rawValue) — too far to walk within your limit."
            case .noServiceFound:
                return "No trips found in the next hour and a half."
            }
        }
    }

    var scheduleFootnote: String {
        let provenance = network.provenance
        var text = provenance.shortDescription
        if let until = provenance.validUntil {
            text += " · valid through \(Self.humanDate(until))"
        }
        return text
    }

    private static func humanDate(_ yyyymmdd: String) -> String {
        guard yyyymmdd.count == 8 else { return yyyymmdd }
        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMdd"
        parser.timeZone = ServiceCalendar.easternTimeZone
        guard let date = parser.date(from: yyyymmdd) else { return yyyymmdd }
        let output = DateFormatter()
        output.timeZone = ServiceCalendar.easternTimeZone
        output.dateStyle = .medium
        return output.string(from: date)
    }
}
