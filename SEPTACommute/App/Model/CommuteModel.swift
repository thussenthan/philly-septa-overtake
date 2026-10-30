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
    var maxWalkMinutes: Double = 15
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

    /// The settings that change the answer, in the shape the widget can read too.
    ///
    /// Everything the planner needs lives here rather than in a private conversion,
    /// because the widget plans the same trip in another process and has to plan it
    /// the same way. Settings that only affect the app — whether to spend network
    /// calls on measured walking times, which appearance to use — stay out of it.
    var tuning: RiderTuning {
        RiderTuning(
            walkingMilesPerHour: walkingMilesPerHour,
            maxWalkMinutes: maxWalkMinutes,
            boardingBufferSeconds: boardingBufferSeconds,
            allowTransfers: allowTransfers,
            stepFreeOnly: stepFreeOnly
        )
    }

    func plannerOptions() -> PlannerOptions { tuning.plannerOptions() }
}

extension RiderPreferences {
    /// Every key optional, so a setting added in a later version doesn't make the
    /// whole stored blob undecodable — which would silently reset every other setting.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RiderPreferences()
        self.init()
        walkingMilesPerHour = try container.decodeIfPresent(Double.self, forKey: .walkingMilesPerHour) ?? defaults.walkingMilesPerHour
        maxWalkMinutes = try container.decodeIfPresent(Double.self, forKey: .maxWalkMinutes) ?? defaults.maxWalkMinutes
        boardingBufferSeconds = try container.decodeIfPresent(Double.self, forKey: .boardingBufferSeconds) ?? defaults.boardingBufferSeconds
        useMeasuredWalkTimes = try container.decodeIfPresent(Bool.self, forKey: .useMeasuredWalkTimes) ?? defaults.useMeasuredWalkTimes
        allowTransfers = try container.decodeIfPresent(Bool.self, forKey: .allowTransfers) ?? defaults.allowTransfers
        stepFreeOnly = try container.decodeIfPresent(Bool.self, forKey: .stepFreeOnly) ?? defaults.stepFreeOnly
        appearanceRaw = try container.decodeIfPresent(String.self, forKey: .appearanceRaw)
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
            preferencesChanged()
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
    let scheduleFreshness: ScheduleFreshnessService
    let places: PlaceStore

    private var cancellables: Set<AnyCancellable> = []
    private var timer: AnyCancellable?
    private var planTask: Task<Void, Never>?
    private var preferencesTask: Task<Void, Never>?
    private var replanScheduled = false
    private let defaults: UserDefaults

    /// How close counts as "you are at this station".
    private let atStationMeters: Double = 160

    /// Within this far of home, the app assumes you are setting out for the day.
    ///
    /// The point of the app is to open it and have the answer already there, so the
    /// destination is guessed from where you are standing: near home means you are
    /// heading to work or school, anywhere else means you are heading home.
    ///
    /// The number lives on `SavedCommute` because the widget applies the same rule in
    /// another process, and a home screen where the app and the widget disagreed about
    /// which way the rider was facing would be worse than either alone.
    private let nearHomeMeters: Double = SavedCommute.nearHomeMeters

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
        scheduleFreshness: ScheduleFreshnessService? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.network = network
        self.narrator = JourneyNarrator(network: network)
        self.places = places
        self.locationService = locationService ?? LocationService()
        self.walkTimes = walkTimes ?? WalkTimeService()
        self.alertService = alertService ?? AlertService()
        self.scheduleFreshness = scheduleFreshness ?? ScheduleFreshnessService()
        self.defaults = defaults

        if let data = defaults.data(forKey: RiderPreferences.storageKey),
           let saved = try? JSONDecoder().decode(RiderPreferences.self, from: data) {
            preferences = saved
        }

        target = Self.automaticTarget(places: places, location: nil, nearHomeMeters: SavedCommute.nearHomeMeters)

        // `self.` is load-bearing: the initialiser parameter of the same name is
        // optional, and would shadow the stored property here.
        // `@Published` publishes *before* the new value is stored, and these handlers
        // read the service and the store rather than the value they are handed. Without
        // hopping to the next turn of the run loop every replan used the previous
        // location and the previous places: the first fix of a launch planned from
        // nowhere, and saving Work in onboarding planned as though only Home existed.
        self.locationService.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.locationChanged() }
            .store(in: &cancellables)

        self.places.$places
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updated in self?.placesChanged(updated) }
            .store(in: &cancellables)

        // A nested ObservableObject's changes don't reach a view observing this one,
        // so they are forwarded by hand. Alerts don't affect the plan — nothing is
        // replanned here, the screen just redraws with SEPTA's notice on it.
        self.alertService.$digest
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        self.scheduleFreshness.$publishedVersion
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func onAppear() {
        locationService.requestPermissionIfNeeded()
        startTicking()
        replan()
        alertService.refreshIfNeeded()
        scheduleFreshness.refreshIfNeeded()
        // An install that already had addresses saved before the widget existed has
        // never published them, and a rider with no location fix would never trigger
        // a plan to do it either. Same for the appearance, which existed as a setting
        // before anything read it across the boundary.
        publishCommuteOnly()
        publishSettings()
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

    /// Standing this close to the only address on file, the rider is already there.
    private static let alreadyThereMeters: Double = 300

    private static func automaticTarget(
        places: PlaceStore,
        location: Coordinate?,
        nearHomeMeters: Double
    ) -> Target? {
        let home = places.home
        let school = places.school

        // With only one anchor there is nothing to choose between — except that a
        // rider already standing at it has nowhere to go, and a plan from there to
        // there is nonsense. Leaving the destination empty asks where they're headed.
        guard let home else {
            guard let school else { return nil }
            if let location, location.distance(to: school.coordinate) <= alreadyThereMeters { return nil }
            return .saved(school)
        }
        guard let school else {
            if let location, location.distance(to: home.coordinate) <= alreadyThereMeters { return nil }
            return .saved(home)
        }

        // No fix yet: the same clock rule the widget falls back to, so the two agree
        // from the first frame instead of the app showing Home until a fix lands.
        guard let location else {
            let hour = Calendar.septa.component(.hour, from: Date())
            return .saved(hour < SavedCommute.defaultTurnaroundHour ? school : home)
        }

        let headingOut = SavedCommute.isHeadingOut(from: location, home: home.coordinate, away: school.coordinate)
        return .saved(headingOut ? school : home)
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
        guard let location = locationService.coordinate, let school = places.school else { return nil }
        return SavedCommute.isHeadingOut(from: location, home: home.coordinate, away: school.coordinate)
            ? "You're near home — heading out"
            : "Heading home"
    }

    private func placesChanged(_ updated: [SavedPlace]) {
        publishCommuteOnly()
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
                // won't re-request anything already cached. Several legs usually land
                // together, and each used to trigger its own full search.
                self?.replanSoon()
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
            .departureBoard(
                from: origin,
                to: destinations,
                after: now,
                aimingAt: plan.best?.rides.first?.alightStation,
                limit: 8
            )
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
            savedAt: request.departAt,
            commute: savedCommute()
        )
        // Only nudge WidgetKit when the trip itself changed: this runs every thirty
        // seconds, and a reload budget spent re-answering the same question is a
        // reload not available when the answer actually moves.
        guard SharedStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The rider's two anchors, for the widget to choose between.
    ///
    /// The last location fix rides along so the widget can apply the same rule the app
    /// does — within a mile of home means heading out, anywhere else means heading
    /// home — rather than falling back to the clock and pointing the other way.
    private func savedCommute() -> SavedCommute? {
        guard let home = places.home, let away = places.school else { return nil }
        return SavedCommute(
            home: SnapshotEndpoint(home.endpoint, name: home.name),
            away: SnapshotEndpoint(away.endpoint, name: away.name),
            // The fix's own time, not now: restamping an old fix as fresh would have
            // the widget trust a location from this morning for another hour and a half.
            lastFix: locationService.fix.map { LocationFix($0.coordinate, at: $0.at) }
        )
    }

    /// Give the widget something to answer as soon as the addresses exist.
    ///
    /// Without this the widget is empty until the rider opens the plan screen with a
    /// location fix — which is backwards, since the whole point of a widget is not
    /// opening the app. Saving an address is enough information to answer the trip,
    /// so it is enough to publish.
    private func publishCommuteOnly() {
        guard let commute = savedCommute() else { return }
        let outbound = commute.outbound(at: Date())
        let snapshot = CommuteSnapshot(
            origin: outbound ? commute.home : commute.away,
            destination: outbound ? commute.away : commute.home,
            reason: nil,
            savedAt: Date(),
            commute: commute
        )
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

    /// Settings arrive a slider tick at a time. Writing them out, reloading the widget
    /// and replanning on every tick did a full search per step of a drag.
    private func preferencesChanged() {
        preferencesTask?.cancel()
        preferencesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistPreferences()
            self.replan()
        }
    }

    /// Replan once, shortly, however many things asked for it.
    private func replanSoon() {
        guard !replanScheduled else { return }
        replanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.replanScheduled = false
            self?.replan()
        }
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: RiderPreferences.storageKey)
        publishSettings()
    }

    /// Put the settings the widget depends on where the widget can read them.
    ///
    /// Two of them cross the boundary. The appearance, because a widget is drawn by
    /// the system and would otherwise sit light beside a dark app. And the planner
    /// tuning, because the widget re-plans the trip itself: with the library defaults
    /// instead of the rider's walking speed and boarding margin it would count down
    /// to a different minute than the app it is sitting next to, and be wrong about
    /// which train to take whenever the two disagreed.
    private func publishSettings() {
        let appearanceChanged = SharedStore.saveAppearance(preferences.appearance.rawValue)
        let tuningChanged = SharedStore.saveTuning(preferences.tuning)
        guard appearanceChanged || tuningChanged else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Derived view state

    /// Stations grouped by line, each in travel order — the only arrangement that
    /// makes sense once there are 586 of them. Lines the rider's own places sit on
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

    /// The platform this board is for: "Southbound from Erie".
    ///
    /// One direction, said once at the top, instead of the same word opening every
    /// row. It is also the thing a rider standing in a station most needs — which
    /// side to be on — so it belongs where the eye lands first.
    var boardHeading: String {
        guard let station = boardStationName else { return "Departures" }
        guard let compass = BoardDeparture.direction(of: departures) else { return "From \(station)" }
        return "\(compass.label) from \(station)"
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

    /// Set when the widget cannot possibly work, so the reason is visible somewhere
    /// rather than only in a widget that looks blank for no stated reason.
    var sharedContainerProblem: String? {
        guard !SharedStore.isSharedContainerAvailable else { return nil }
        return "The widget can't read your trip: the app group "
            + "\(SharedStore.appGroupID) isn't available on this device. "
            + "The app itself is unaffected."
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
                return "This timetable runs out after \(Self.humanDate(end)). Update Overtake, or check septa.org."
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

    /// Set when SEPTA has published a newer timetable than the one in this build.
    ///
    /// Distinct from the planner's out-of-date note, which fires only once the
    /// bundled data has run out altogether. This is the softer and far more common
    /// case: the times still work, they are simply no longer the newest ones, and
    /// installing an update is worth doing but not worth interrupting anyone over.
    var newerScheduleNote: String? {
        guard let published = scheduleFreshness.publishedVersion else { return nil }
        return "SEPTA has published a newer timetable (\(published)). This build has \(SEPTAData.feedVersion) — update Overtake when you can."
    }

    /// How much of the bundled timetable SEPTA still stands behind.
    ///
    /// Two windows, because SEPTA publishes two: a fortnight it calls authoritative
    /// and a couple of weeks past that it labels advisory. Riders reading this screen
    /// deserve the distinction rather than a single date that makes the app look
    /// broken a fortnight after every release.
    var scheduleWindowNote: String? {
        let provenance = network.provenance
        guard let services = provenance.servicesUntil, services != provenance.validUntil else { return nil }
        if provenance.isStale(asOf: Date()) {
            return "Past SEPTA's confirmed window. These are its own advisory times, which run through \(Self.humanDate(services))."
        }
        return "SEPTA also publishes advisory times through \(Self.humanDate(services)), used once the confirmed window above ends."
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
