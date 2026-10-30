import Foundation

/// The trip the widget should be answering, written by the app.
///
/// A widget extension can't do what the app does. It has no reliable location fix,
/// its network calls are throttled, and it is killed if it takes too long. What it
/// *does* have is the same bundled timetable, which is enough to compute exact
/// departures for any moment — as long as something tells it where the rider is
/// going. That is this: the last trip the app planned, written to a shared
/// container. The widget re-plans it from scratch for the current time, so its
/// countdown is a real answer rather than a cached screenshot.
public struct CommuteSnapshot: Codable, Hashable, Sendable {
    public var origin: SnapshotEndpoint
    public var destination: SnapshotEndpoint
    /// Why this destination, when the app chose it — "Heading home".
    public var reason: String?
    /// When the app last planned this. Shown when it is old enough to distrust.
    public var savedAt: Date
    /// The rider's two anchors, if they have set both.
    ///
    /// This is what makes the widget worth having. Without it the widget could only
    /// repeat the last trip the app happened to plan, which means it shows nothing on
    /// a fresh install and shows yesterday's one-off lookup after that — a widget you
    /// have to open the app to prime is not doing its job. With it, the widget picks
    /// a direction itself and is right from the moment the addresses are saved.
    public var commute: SavedCommute?

    public init(
        origin: SnapshotEndpoint,
        destination: SnapshotEndpoint,
        reason: String? = nil,
        savedAt: Date,
        commute: SavedCommute? = nil
    ) {
        self.origin = origin
        self.destination = destination
        self.reason = reason
        self.savedAt = savedAt
        self.commute = commute
    }

    /// The trip to answer at this moment.
    ///
    /// Prefers the saved commute over whatever the app last looked at. That is
    /// deliberate: a widget should show the trip you take twice a day, not the one you
    /// idly checked on Sunday. Which way round it points follows the app's rule — near
    /// home means heading out — using the fix the app lends it, since a widget can get
    /// none of its own.
    public func trip(at moment: Date, calendar: Calendar = .septa) -> (origin: SnapshotEndpoint, destination: SnapshotEndpoint) {
        guard let commute else { return (origin, destination) }
        return commute.outbound(at: moment, calendar: calendar)
            ? (commute.home, commute.away)
            : (commute.away, commute.home)
    }

    /// Whether this describes the same trip, ignoring when it was saved.
    ///
    /// The app replans every thirty seconds; rewriting the snapshot and asking
    /// WidgetKit to reload each time would burn the widget's refresh budget to say
    /// nothing new. The commute is part of the comparison because a rider moving house
    /// is precisely the change the widget must not miss.
    ///
    /// It is compared by where it would *send* the rider rather than field by field:
    /// it carries a location fix that moves every few metres and is restamped on every
    /// replan, and reloading the widget because someone crossed the room would spend
    /// the whole refresh budget saying nothing.
    public func describesSameTrip(as other: CommuteSnapshot?) -> Bool {
        guard let other else { return false }
        // With a commute on file the widget derives the trip from it and never reads
        // `origin` or `destination`, so comparing them would only measure the rider
        // walking about: while they are not standing in a station, the origin is
        // their own coordinate, and every few metres would count as a new trip.
        if let commute {
            return reason == other.reason && commute.agrees(with: other.commute, at: savedAt)
        }
        return origin == other.origin
            && destination == other.destination
            && reason == other.reason
            && other.commute == nil
    }
}

/// Where the rider lives and where they go, so the widget can work out which way
/// they are facing without asking anything.
public struct SavedCommute: Codable, Hashable, Sendable {
    public var home: SnapshotEndpoint
    /// Work or school — the other end of the trip they make twice a day.
    public var away: SnapshotEndpoint
    /// The hour the widget stops assuming they are outbound. Noon by default: a
    /// commuter leaving at seven and coming back at six is on the right side of it
    /// both times, and a rider who disagrees can still open the app.
    ///
    /// Only consulted when there is no usable location fix to reason from.
    public var turnaroundHour: Int
    /// The last place the app saw the rider, and when.
    ///
    /// A widget extension gets no location fix of its own, so the app lends it the
    /// last one it had. With it the widget can apply the same rule the app does —
    /// near home means heading out, anywhere else means heading home — instead of
    /// guessing from the clock and disagreeing with the screen it sits beside.
    public var lastFix: LocationFix?

    /// The hour the clock starts calling a rider homeward when there is no fix.
    public static let defaultTurnaroundHour = 12

    public init(
        home: SnapshotEndpoint,
        away: SnapshotEndpoint,
        turnaroundHour: Int = SavedCommute.defaultTurnaroundHour,
        lastFix: LocationFix? = nil
    ) {
        self.home = home
        self.away = away
        self.turnaroundHour = turnaroundHour
        self.lastFix = lastFix
    }

    /// Inside this, the rider counts as being at home.
    ///
    /// One mile: far enough to cover the walk to any of the stations a rider would
    /// use from home, close enough that being inside it means they haven't left yet.
    public static let nearHomeMeters: Double = 1609.34

    /// How long a fix is worth trusting.
    ///
    /// A fix taken at home this morning is worthless by the afternoon — it would have
    /// the widget offering the trip *to* work while the rider is sitting at work. One
    /// commute's worth of staleness is the most that can be defended, and past that
    /// the clock is the better guess.
    public static let fixLifetime: TimeInterval = 90 * 60

    /// True when the rider is presumed to be heading out rather than home.
    ///
    /// Distance first, clock second. Being within a mile of home is direct evidence
    /// of which way they are facing; the hour of the day is only a proxy for it.
    public func outbound(at moment: Date, calendar: Calendar = .septa) -> Bool {
        if metersFromHome(at: moment) != nil, let lastFix, let homePoint = home.coordinate {
            return Self.isHeadingOut(from: lastFix.coordinate, home: homePoint, away: away.coordinate)
        }
        return calendar.component(.hour, from: moment) < turnaroundHour
    }

    /// The one rule the app and the widget both apply to a fix.
    ///
    /// Within a mile of home means setting out. But someone who lives within a mile
    /// of where they go is "near home" at the office as well, and would be told to
    /// travel from the office to the office — so when the other anchor is nearer than
    /// home, they are at it, and heading back.
    public static func isHeadingOut(from fix: Coordinate, home: Coordinate, away: Coordinate?) -> Bool {
        let fromHome = fix.distance(to: home)
        guard fromHome <= nearHomeMeters else { return false }
        if let away, fix.distance(to: away) < fromHome { return false }
        return true
    }

    /// Whether this would send the rider the same way as `other` at this moment.
    ///
    /// The direction is all the widget takes from a commute, so it is all that is
    /// worth reloading for. Whether the fix is fresh counts too: a stored one that has
    /// aged out has quietly stopped being distance-based, and replacing it with a live
    /// fix restores the rule even when the verdict happens to match.
    public func agrees(
        with other: SavedCommute?,
        at moment: Date,
        calendar: Calendar = .septa
    ) -> Bool {
        guard let other else { return false }
        return home == other.home
            && away == other.away
            && turnaroundHour == other.turnaroundHour
            && outbound(at: moment, calendar: calendar) == other.outbound(at: moment, calendar: calendar)
            && (metersFromHome(at: moment) == nil) == (other.metersFromHome(at: moment) == nil)
    }

    /// How long the direction worked out at `moment` can still be relied on.
    ///
    /// A widget hands WidgetKit a stretch of future entries and cannot revise them, so
    /// a timeline that runs past the moment the rider counts as facing the other way
    /// would sit there offering the trip they have already made. This is when that
    /// could first happen: the fix ageing out, or — when the clock is deciding — the
    /// turnaround.
    public func directionStableUntil(
        from moment: Date,
        calendar: Calendar = .septa
    ) -> Date {
        if let lastFix, metersFromHome(at: moment) != nil {
            return lastFix.at.addingTimeInterval(Self.fixLifetime)
        }
        let changes = [turnaroundHour, 0].compactMap {
            calendar.nextDate(
                after: moment,
                matching: DateComponents(hour: $0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        }
        // An hour is a safe floor if the calendar can't answer, which it can't in
        // time zones that skip the hour being asked for.
        return changes.min() ?? moment.addingTimeInterval(3600)
    }

    /// How far the rider was from home when last seen, if that is still recent
    /// enough to mean anything and home has coordinates to measure against.
    public func metersFromHome(at moment: Date) -> Double? {
        guard let lastFix,
              abs(moment.timeIntervalSince(lastFix.at)) <= Self.fixLifetime,
              let origin = home.coordinate else { return nil }
        return lastFix.coordinate.distance(to: origin)
    }
}

/// Where the rider was, and when the app saw them there.
public struct LocationFix: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var at: Date

    public init(latitude: Double, longitude: Double, at: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.at = at
    }

    public init(_ coordinate: Coordinate, at: Date) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, at: at)
    }

    public var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// One end of a snapshot trip.
///
/// `Endpoint` itself isn't `Codable` — it is a routing input, and giving it a wire
/// format would make every future change to it a migration. This is the wire
/// format, and it converts.
public struct SnapshotEndpoint: Codable, Hashable, Sendable {
    /// What to call this end on screen: "Erie", "Home".
    public var name: String
    /// Set when the rider is starting from (or heading to) a station itself.
    public var stationID: StationID?
    public var latitude: Double?
    public var longitude: Double?

    public init(name: String, stationID: StationID? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        self.stationID = stationID
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ endpoint: Endpoint, name: String) {
        switch endpoint {
        case .station(let id):
            self.init(name: name, stationID: id)
        case .place(_, let coordinate):
            self.init(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// Set for a saved address. A station-based endpoint carries an ID instead, and
    /// resolving that to a position needs the network, which is the caller's to hold.
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Back to something the planner accepts, or `nil` if the record is unusable.
    public var endpoint: Endpoint? {
        if let stationID { return .station(stationID) }
        guard let latitude, let longitude else { return nil }
        return .place(name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude))
    }
}

/// The rider's own settings, in the form both processes need them.
///
/// This exists because the app and the widget were each building `PlannerOptions`
/// their own way, and so answering the same question differently: the app from the
/// rider's saved walking speed, boarding margin and transfer preference, the widget
/// from the library defaults. A slower walker's countdown on the home screen did not
/// match the countdown in the widget beside it, and neither was wrong on its own
/// terms — they were answering two subtly different questions.
///
/// Now there is one conversion, used by both.
public struct RiderTuning: Codable, Hashable, Sendable {
    public var walkingMilesPerHour: Double
    public var maxWalkMinutes: Double
    public var boardingBufferSeconds: Double
    public var allowTransfers: Bool
    public var stepFreeOnly: Bool

    public init(
        walkingMilesPerHour: Double = 3.0,
        maxWalkMinutes: Double = 15,
        boardingBufferSeconds: Double = 30,
        allowTransfers: Bool = true,
        stepFreeOnly: Bool = false
    ) {
        self.walkingMilesPerHour = walkingMilesPerHour
        self.maxWalkMinutes = maxWalkMinutes
        self.boardingBufferSeconds = boardingBufferSeconds
        self.allowTransfers = allowTransfers
        self.stepFreeOnly = stepFreeOnly
    }

    public func plannerOptions() -> PlannerOptions {
        var options = PlannerOptions()
        options.walking.milesPerHour = walkingMilesPerHour
        options.maxWalkSeconds = maxWalkMinutes * 60
        options.boardingBufferSeconds = boardingBufferSeconds
        options.maxTransfers = allowTransfers ? 2 : 0
        options.requiresStepFreeAccess = stepFreeOnly
        return options
    }
}

extension Calendar {
    /// The calendar the timetable is written in.
    ///
    /// Everything the rider reads is Eastern time — the schedule, every clock on the
    /// cards — so "which side of noon is it" has to be Eastern too. With the device's
    /// own calendar, a phone set to another zone (or a test runner on UTC) flips the
    /// widget's direction at the wrong hour.
    public static var septa: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ServiceCalendar.easternTimeZone
        return calendar
    }
}

/// The container the app and its widget share.
///
/// Declared in `SEPTACommute.entitlements` and `SEPTACommuteWidget.entitlements`, and
/// wired to both targets through `CODE_SIGN_ENTITLEMENTS` — which is all Xcode's
/// Signing & Capabilities dialog writes, so it is done in the project file instead.
/// The two must name the same group; a mismatch is silent, and looks exactly like a
/// widget with nothing to show.
///
/// The identifier tracks the bundle identifier by convention, so renaming the app
/// means renaming `baseAppGroupID`, both entitlements files, and nothing else.
///
/// **Sideloading renames the group.** SideStore and AltStore re-sign the app with the
/// rider's own free team, and to keep identifiers unique per team they append the
/// team ID: `group.com.thussenthan.Overtake` becomes
/// `group.com.thussenthan.Overtake.<TEAMID>`. A hardcoded constant then points the
/// app and the widget at a group that was never provisioned, each silently falls back
/// to its own private defaults, and the widget shows its empty state forever. So the
/// group is looked up at runtime from what this binary was actually signed with.
///
/// `UserDefaults(suiteName:)` is not a reliable probe — it hands back a usable object
/// even for a group the process isn't entitled to — so availability is judged by
/// whether the system will give this process the group's *container directory*. The
/// fallback to `.standard` keeps the *app* working either way; only the widget goes
/// quiet.
public enum SharedStore {
    /// The group the project's entitlements declare, before any re-signer touches it.
    public static let baseAppGroupID = "group.com.thussenthan.Overtake"

    /// The group this process can actually open: the one it was signed with, which on
    /// a sideloaded build carries a team-ID suffix. Resolved once, because the app
    /// and its widget each resolve it independently and have to land on the same one.
    public static let appGroupID: String = resolveAppGroupID()

    /// Chooses among the groups a bundle says it was signed with.
    ///
    /// Candidates come from, in order: the `ALTAppGroups` key AltStore-family
    /// re-signers write into Info.plist; the entitlements in the embedded
    /// provisioning profile, which a sideloaded build always carries; then the
    /// declared constant. Only groups that are the declared one or an extension of it
    /// are considered, and only one the system will open is returned.
    static func resolveAppGroupID(
        bundle: Bundle = .main,
        canOpen: (String) -> Bool = SharedStore.containerExists
    ) -> String {
        let candidates = declaredGroups(in: bundle) + provisionedGroups(in: bundle)
        for group in candidates where group.hasPrefix(baseAppGroupID) && canOpen(group) {
            return group
        }
        return baseAppGroupID
    }

    static func containerExists(_ group: String) -> Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    /// The groups AltStore and SideStore record in Info.plist when they re-sign.
    static func declaredGroups(in bundle: Bundle) -> [String] {
        bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    /// The groups in the embedded provisioning profile's entitlements.
    ///
    /// The profile is a signed blob with a plain-text property list inside it, so the
    /// list is cut out by its XML markers rather than by unpacking the signature.
    /// Absent on a simulator or App Store build, which is fine: those are not renamed.
    static func provisionedGroups(in bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let profile = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound),
                  options: [],
                  format: nil
              ) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static let snapshotKey = "commuteSnapshot.v1"
    private static let appearanceKey = "appearance.v1"
    private static let tuningKey = "riderTuning.v1"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// False when the shared container isn't there — a missing entitlement, a group
    /// that isn't provisioned, or the two targets naming different ones.
    ///
    /// Worth exposing rather than swallowing. The failure is otherwise completely
    /// silent: the app keeps working against its own defaults, the widget reads an
    /// empty store, and the only symptom is a widget that says the addresses aren't
    /// set when they plainly are.
    public static var isSharedContainerAvailable: Bool {
        containerExists(appGroupID)
    }

    public static func snapshot(from defaults: UserDefaults = SharedStore.defaults) -> CommuteSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(CommuteSnapshot.self, from: data)
    }

    /// Light, dark, or follow the phone — whichever the rider chose in the app.
    ///
    /// A widget is rendered by the system and follows the *system* appearance, so an
    /// app that defaults to dark gets a light widget on a light phone and looks like
    /// two different products. The preference has to cross the process boundary for
    /// the widget to honour it, and there is now a container to cross it in.
    public static func appearance(from defaults: UserDefaults = SharedStore.defaults) -> String? {
        defaults.string(forKey: appearanceKey)
    }

    /// Returns true when the stored value changed, so the caller knows whether a
    /// widget reload is warranted.
    @discardableResult
    public static func saveAppearance(
        _ raw: String,
        to defaults: UserDefaults = SharedStore.defaults
    ) -> Bool {
        guard appearance(from: defaults) != raw else { return false }
        defaults.set(raw, forKey: appearanceKey)
        return true
    }

    /// The rider's settings, so the widget plans the trip the way the app does.
    public static func tuning(from defaults: UserDefaults = SharedStore.defaults) -> RiderTuning? {
        guard let data = defaults.data(forKey: tuningKey) else { return nil }
        return try? JSONDecoder().decode(RiderTuning.self, from: data)
    }

    @discardableResult
    public static func saveTuning(
        _ tuning: RiderTuning,
        to defaults: UserDefaults = SharedStore.defaults
    ) -> Bool {
        guard Self.tuning(from: defaults) != tuning,
              let data = try? JSONEncoder().encode(tuning) else { return false }
        defaults.set(data, forKey: tuningKey)
        return true
    }

    /// Forgets the trip on file, for when the rider has no places left to plan between.
    /// Returns true when there was one, so the caller knows to reload the widget.
    @discardableResult
    public static func clearSnapshot(from defaults: UserDefaults = SharedStore.defaults) -> Bool {
        guard defaults.data(forKey: snapshotKey) != nil else { return false }
        defaults.removeObject(forKey: snapshotKey)
        return true
    }

    /// Writes the snapshot, and reports whether it changed the trip on file.
    ///
    /// The return value is what the caller uses to decide whether to reload the
    /// widget, so a replan that reaches the same conclusion costs nothing.
    @discardableResult
    public static func save(
        _ snapshot: CommuteSnapshot,
        to defaults: UserDefaults = SharedStore.defaults
    ) -> Bool {
        let changed = !snapshot.describesSameTrip(as: Self.snapshot(from: defaults))
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: snapshotKey)
        return changed
    }
}
