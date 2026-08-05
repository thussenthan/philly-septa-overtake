import Combine
import Foundation
import SwiftUI
import WidgetKit

/// Light, dark, or whatever the phone is set to.
enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match phone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

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
    /// Route only via stations with elevator access.
    var stepFreeOnly: Bool = false

    /// Stored as an optional so preferences saved before this setting existed still
    /// decode — otherwise adding a key would silently reset every other setting.
    private var appearanceRaw: String?

    var appearance: AppearanceChoice {
        get { appearanceRaw.flatMap(AppearanceChoice.init(rawValue:)) ?? .dark }
        set { appearanceRaw = newValue.rawValue }
    }

    static let storageKey = "riderPreferences.v1"

    func plannerOptions() -> PlannerOptions {
        var options = PlannerOptions()
        options.walking.milesPerHour = walkingMilesPerHour
        options.maxWalkSeconds = maxWalkMinutes * 60
        options.boardingBufferSeconds = boardingBufferSeconds
        options.maxTransfers = allowTransfers ? 2 : 0
        options.requiresStepFreeAccess = stepFreeOnly
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
    /// Every train from the recommended boarding station that can get the rider
    /// there, in departure order — the platform sign this app is standing in for.
    @Published private(set) var departures: [BoardDeparture] = []
    /// Set when the rider is standing in (or right next to) a station.
    @Published private(set) var currentStation: Station?
    @Published private(set) var lastPlannedAt: Date?
    @Published private(set) var isRefreshing = false

    let network: Network
    let narrator: JourneyNarrator
    let locationService: LocationService
    let walkTimes: WalkTimeService
    let alertService: AlertService
    let places: PlaceStore

    private var cancellables: Set<AnyCancellable> = []
    private var timer: AnyCancellable?
    private var planTask: Task<Void, Never>?
    private let defaults: UserDefaults

    /// How close counts as "you are at this station".
    private let atStationMeters: Double = 160

    /// Within this far of home, the app assumes you are setting out for the day.
    ///
    /// The point of the app is to open it and have the answer already there, so the
    /// destination is guessed from where you are standing: near home means you are
    /// heading to work or school, anywhere else means you are heading home.
    private let nearHomeMeters: Double = 1609.34   // one mile

    /// Set once the rider picks a destination by hand, so the guess stops
    /// overriding them. Deliberately not persisted — every launch starts by
    /// guessing again, which is the behaviour that makes the app useful at a glance.
    @Published private(set) var hasManualTarget = false

    /// The services default to `nil` rather than to freshly constructed values.
    ///
    /// A default argument is evaluated in a nonisolated context, so
    /// `LocationService()` as a default fails to compile: both services are
    /// `@MainActor`. Constructing them inside the initialiser — which *is*
    /// main-actor isolated, because the class is — keeps the convenient call site.
    init(
        network: Network = SEPTAData.network,
        places: PlaceStore,
        locationService: LocationService? = nil,
        walkTimes: WalkTimeService? = nil,
        alertService: AlertService? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.network = network
        self.narrator = JourneyNarrator(network: network)
        self.places = places
        self.locationService = locationService ?? LocationService()
        self.walkTimes = walkTimes ?? WalkTimeService()
        self.alertService = alertService ?? AlertService()
        self.defaults = defaults

        if let data = defaults.data(forKey: RiderPreferences.storageKey),
           let saved = try? JSONDecoder().decode(RiderPreferences.self, from: data) {
            preferences = saved
        }

        target = Self.automaticTarget(places: places, location: nil, nearHomeMeters: 1609.34)

        // `self.` is load-bearing: the initialiser parameter of the same name is
        // optional, and would shadow the stored property here.
        self.locationService.$status
            .removeDuplicates()
            .sink { [weak self] _ in self?.locationChanged() }
            .store(in: &cancellables)

        self.places.$places
            .sink { [weak self] updated in self?.placesChanged(updated) }
            .store(in: &cancellables)

        // A nested ObservableObject's changes don't reach a view observing this one,
        // so they are forwarded by hand. Alerts don't affect the plan — nothing is
        // replanned here, the screen just redraws with SEPTA's notice on it.
        self.alertService.$digest
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func onAppear() {
        locationService.requestPermissionIfNeeded()
        startTicking()
        replan()
        alertService.refreshIfNeeded()
    }

    func onDisappear() {
        timer?.cancel()
        timer = nil
        planTask?.cancel()
        planTask = nil
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
        // A deliberate pull, so refetch alerts even if the cached set is young.
        await alertService.refresh()
        // A brief hold so a pull-to-refresh reads as having done something even
        // when the plan is unchanged.
        try? await Task.sleep(nanoseconds: 350_000_000)
        isRefreshing = false
    }

    // MARK: - Reacting to change

    private func locationChanged() {
        updateCurrentStation()
        updateAutomaticTarget()
        replan()
    }

    /// Guess where the rider is going, unless they have already said.
    private func updateAutomaticTarget() {
        guard !hasManualTarget else { return }
        let guess = Self.automaticTarget(
            places: places,
            location: locationService.coordinate,
            nearHomeMeters: nearHomeMeters
        )
        guard guess != target else { return }
        target = guess
    }

    private static func automaticTarget(
        places: PlaceStore,
        location: Coordinate?,
        nearHomeMeters: Double
    ) -> Target? {
        let home = places.home
        let school = places.school
        // With only one anchor there is nothing to choose between.
        guard let home else { return school.map(Target.saved) }
        guard let school else { return .saved(home) }
        guard let location else { return .saved(home) }

        let distanceFromHome = location.distance(to: home.coordinate)
        return .saved(distanceFromHome <= nearHomeMeters ? school : home)
    }

    /// The rider picked a destination themselves; stop guessing for this session.
    func chooseTarget(_ chosen: Target?) {
        hasManualTarget = chosen != nil
        target = chosen
        replan()
    }

    /// Hand the choice back to the app.
    func resumeAutomaticTarget() {
        hasManualTarget = false
        updateAutomaticTarget()
        replan()
    }

    /// Why the current destination was chosen, for the "To" row.
    var targetReason: String? {
        guard !hasManualTarget, let home = places.home, places.school != nil else { return nil }
        guard let location = locationService.coordinate else { return nil }
        return location.distance(to: home.coordinate) <= nearHomeMeters
            ? "You're near home — heading out"
            : "Heading home"
    }

    private func placesChanged(_ updated: [SavedPlace]) {
        guard hasManualTarget else {
            updateAutomaticTarget()
            replan()
            return
        }
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

    // MARK: - Planning

    /// Recompute the plan.
    ///
    /// The search itself runs off the main actor. A door-to-door plan across the
    /// Metro map measures at about 31 ms on an Apple silicon Mac, and a phone is
    /// slower. That much work on the main actor, every thirty seconds and again on
    /// every location update, is a visible stutter.
    func replan() {
        guard let origin = resolvedOrigin, let destination = resolvedTarget else {
            planTask?.cancel()
            plan = nil
            departures = []
            advice = nil
            return
        }

        let now = Date()
        var options = preferences.plannerOptions()
        options.maxResults = 6

        let accessCandidates = candidateStations(near: origin.coordinate, limit: options.maxAccessStations)
        let egressCandidates = candidateStations(near: destination.coordinate, limit: options.maxEgressStations)

        let overrides = preferences.useMeasuredWalkTimes
            ? walkTimes.overrides(
                from: origin.coordinate,
                to: destination.coordinate,
                accessStations: accessCandidates,
                egressStations: egressCandidates
            )
            : .none

        compute(
            request: PlanRequest(
                origin: origin,
                destination: destination,
                departAt: now,
                walkOverrides: overrides
            ),
            options: options
        )

        guard preferences.useMeasuredWalkTimes else { return }
        walkTimes.measure(
            from: origin.coordinate,
            to: destination.coordinate,
            accessStations: accessCandidates,
            egressStations: egressCandidates,
            onUpdate: { [weak self] in
                // Measured walks can reorder the options, so replan — `measure`
                // won't re-request anything already cached.
                self?.replan()
            }
        )
    }

    /// Runs one search off the main actor and publishes the result.
    ///
    /// A newer request supersedes an in-flight one: the rider has moved on, and
    /// a stale plan landing after a fresh one would make countdowns jump backwards.
    private func compute(request: PlanRequest, options: PlannerOptions) {
        planTask?.cancel()
        let network = self.network
        let narrator = self.narrator

        planTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                JourneyPlanner(network: network, options: options).plan(request)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.plan = result
            self.departures = board(for: result, asOf: request.departAt, options: options)
            self.advice = narrator.advice(for: result, asOf: request.departAt)
            self.lastPlannedAt = request.departAt
            self.publishSnapshot(for: request)
        }
    }

    /// The board for the recommended boarding station.
    ///
    /// Built from the plan rather than independently, so it lists trains from the
    /// station the app is actually sending the rider to, towards the stations the
    /// plan found usable at the far end. Anything else would be a board for a
    /// different trip.
    private func board(for plan: Plan, asOf now: Date, options: PlannerOptions) -> [BoardDeparture] {
        guard let origin = plan.best?.boardStation else { return [] }
        // Where the *first* train ends, not where the trip does: on an itinerary with
        // a change, the useful board is trains towards the interchange. Each row names
        // the station it arrives at, so there is nothing to misread.
        let destinations = Set(plan.journeys.compactMap { $0.rides.first?.alightStation })
        guard !destinations.isEmpty else { return [] }
        return JourneyPlanner(network: network, options: options)
            .departureBoard(from: origin, to: destinations, after: now, limit: 8)
    }

    /// Hand the widget the trip, not the answer.
    ///
    /// The widget has the same timetable and can work out departures for itself; what
    /// it cannot do is get a location fix or guess where the rider is going. So only
    /// the endpoints cross the boundary, and the widget re-plans them for whatever
    /// moment it is being looked at — which is why its countdown is live rather than
    /// a picture of whatever the app last computed.
    private func publishSnapshot(for request: PlanRequest) {
        let snapshot = CommuteSnapshot(
            origin: SnapshotEndpoint(request.origin, name: originName),
            destination: SnapshotEndpoint(request.destination, name: targetName),
            reason: targetReason,
            savedAt: request.departAt
        )
        // Only nudge WidgetKit when the trip itself changed: this runs every thirty
        // seconds, and a reload budget spent re-answering the same question is a
        // reload not available when the answer actually moves.
        guard SharedStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What to call the origin on screen and in the widget.
    var originName: String {
        switch source {
        case .currentLocation:
            return currentStation?.displayName ?? "Where I am"
        case .station(let id):
            return network.station(id)?.displayName ?? id.rawValue
        case .saved(let place):
            return place.name
        }
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

    /// Stations grouped by line, each in travel order — the only arrangement that
    /// makes sense once there are 585 of them. Lines the rider's own places sit on
    /// come first, then SEPTA's own order: L, B, trolleys, Girard, Media-Sharon Hill,
    /// Norristown, then the trackless trolleys. Sorting by badge put route 59 at the
    /// top of the Philadelphia rapid-transit network.
    var stationSections: [(line: Line, stations: [Station])] {
        let homeLines = Set((places.places.compactMap { place -> Station? in
            network.nearestStation(to: place.coordinate)?.station
        }).flatMap(\.lines))

        return network.lines
            .map { (line: $0, stations: network.stationsInOrder(on: $0.id)) }
            .filter { !$0.stations.isEmpty }
            .sorted { lhs, rhs in
                let lhsNear = homeLines.contains(lhs.line.id)
                let rhsNear = homeLines.contains(rhs.line.id)
                if lhsNear != rhsNear { return lhsNear }
                if lhs.line.sortOrder != rhs.line.sortOrder {
                    return lhs.line.sortOrder < rhs.line.sortOrder
                }
                return lhs.line.badge < rhs.line.badge
            }
    }

    /// The station the board is for, named.
    var boardStationName: String? {
        plan?.best?.boardStation.map { network.station($0)?.name ?? $0.rawValue }
    }

    /// True for the train the recommendation actually puts the rider on, so the board
    /// can mark it rather than making them match times by eye.
    func isRecommended(_ departure: BoardDeparture) -> Bool {
        plan?.best?.rides.first?.trip.id == departure.trip.id
    }

    // MARK: - Service alerts

    /// The lines the current options actually use.
    ///
    /// Alerts are filtered to these rather than shown wholesale: SEPTA publishes a
    /// notice for every route it runs, and a rider looking at a B trip does not need
    /// to hear about the Media-Sharon Hill trolleys.
    private var linesInPlan: Set<LineID> {
        Set((plan?.journeys ?? []).flatMap { $0.rides.map(\.lineID) })
    }

    /// SEPTA's notices for the lines on screen, worst first.
    ///
    /// Empty until the fetch lands, and empty when offline with no usable cache —
    /// in both cases the app says nothing rather than implying all is well.
    var serviceAlerts: [ServiceAlert] {
        let lines = linesInPlan
        // With no plan yet there is nothing to be specific about, so only
        // system-wide notices are worth showing.
        guard !lines.isEmpty else {
            return alertService.digest.alerts
                .filter(\.appliesToWholeSystem)
                .sorted { $0.severity > $1.severity }
        }
        return alertService.digest.alerts(affecting: lines)
    }

    /// The worst notice touching one option, for the chip on its card.
    func alert(for journey: Journey) -> ServiceAlert? {
        alertService.digest.worstAlert(for: journey)
    }

    /// "Delays on the B" — the line named the way the map names it.
    func alertChipText(_ alert: ServiceAlert) -> String {
        guard let lineID = alert.lineID, let line = network.line(lineID) else {
            return alert.severity.label
        }
        return "\(alert.severity.label) on the \(line.badge)"
    }

    /// Where SEPTA interpolates rather than publishes the times behind an option.
    ///
    /// Every Broad Street Line stop time in the feed is a published timing point; on
    /// the trolleys it's about one in six, and the rest are the agency's own estimate
    /// between them. An app whose whole promise is a countdown should say which it is
    /// holding — but on the detail screen, not over the answer, because it doesn't
    /// change which train to catch.
    var estimatedTimeNotes: [String] {
        let routes = (plan?.journeys ?? []).flatMap(\.rides).compactMap { ride in
            network.pattern(ride.patternID).map { (ride.routeBadge, $0) }
        }
        var seen = Set<String>()
        return routes.compactMap { badge, pattern in
            guard pattern.hasMostlyEstimatedTimes, seen.insert(badge).inserted else { return nil }
            return "SEPTA publishes \(pattern.publishedTimePercent)% of the \(badge)'s stop times; "
                + "the rest are its own estimates between timing points."
        }
    }

    /// Why these are scheduled times, given SEPTA does publish some live data.
    ///
    /// Measured rather than assumed, and it splits by mode: for the B and the L,
    /// `TransitViewAll` reports `late` as 998 — its no-data sentinel — on every
    /// vehicle, and the GTFS-Realtime `TripUpdates` feed omits subway trips entirely
    /// (0 of 32 running subway trips appeared in it against 770 of 819 bus and trolley
    /// trips at the same moment). For the trolleys, Girard and Norristown, the delay
    /// *is* published and this app simply doesn't read it yet.
    ///
    /// Both sentences are worth saying, and saying the right one: a rider comparing
    /// this app against one showing a live map deserves to know whether the difference
    /// is SEPTA's data or this app's ambition.
    var liveDataNote: String? {
        let lines = linesInPlan
        guard !lines.isEmpty else { return nil }
        let subwayOnly: Set<LineID> = ["B", "B-OWL", "L"]
        if lines.isSubset(of: subwayOnly) {
            return "SEPTA publishes where B and L trains are but not whether they're "
                + "running late, so these are scheduled times — as they are in every "
                + "other app."
        }
        let tracked = lines.subtracting(subwayOnly).map(\.rawValue).sorted()
        return "SEPTA does publish live delays for the \(tracked.joined(separator: ", ")). "
            + "This app doesn't read them yet, so these are scheduled times."
    }

    /// SEPTA's fare rules, as sentences. From the feed's own fare tables, so they
    /// change when SEPTA changes them rather than when someone remembers to.
    var fareNotes: [String] {
        let fare = network.fare
        guard fare.isKnown else { return [] }
        var notes = ["\(Format.money(fare.amount, currency: fare.currency)) per ride, adult full fare."]
        if fare.includedTransfers > 0, !fare.freeTransferMedia.isEmpty {
            let media = fare.freeTransferMedia.joined(separator: " or ")
            let changes = fare.includedTransfers == 1 ? "one change" : "up to \(fare.includedTransfers) changes"
            notes.append(
                "With \(media), one fare covers \(changes) of train within "
                    + "\(Format.minutes(fare.transferWindow))."
            )
        }
        if !fare.perBoardingMedia.isEmpty {
            notes.append(
                "Paying with \(fare.perBoardingMedia.joined(separator: " or "))"
                    + " costs a new fare every time you board."
            )
        }
        return notes
    }

    /// Shown under the alerts when the fetch failed and there is nothing cached, so
    /// an empty list isn't mistaken for good news.
    var alertFetchProblem: String? {
        guard alertService.digest.alerts.isEmpty else { return nil }
        return alertService.lastError
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
            case .noStepFreeRouteFound:
                return "No step-free route found. The stations near you don't all have elevators — turn off step-free routing in Settings to see the rest."
            case .stepFreeCostsTime(let extra):
                return "Step-free routing is costing you \(Format.minutes(extra)) here, because a closer station has no elevator."
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
