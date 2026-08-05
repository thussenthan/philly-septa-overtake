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
    /// Prefers the saved commute, flipped by time of day, over whatever the app last
    /// looked at. That is deliberate: a widget should show the trip you take twice a
    /// day, not the one you idly checked on Sunday. The app's own guess is
    /// location-based and better, but a widget has no usable location fix, and the
    /// clock is a good enough proxy for which way a commuter is pointing.
    public func trip(at moment: Date, calendar: Calendar = .autoupdatingCurrent) -> (origin: SnapshotEndpoint, destination: SnapshotEndpoint) {
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
    public func describesSameTrip(as other: CommuteSnapshot?) -> Bool {
        guard let other else { return false }
        return origin == other.origin
            && destination == other.destination
            && reason == other.reason
            && commute == other.commute
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
    public var turnaroundHour: Int

    public init(home: SnapshotEndpoint, away: SnapshotEndpoint, turnaroundHour: Int = 12) {
        self.home = home
        self.away = away
        self.turnaroundHour = turnaroundHour
    }

    /// True when the rider is presumed to be heading out rather than home.
    public func outbound(at moment: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.component(.hour, from: moment) < turnaroundHour
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

    /// Back to something the planner accepts, or `nil` if the record is unusable.
    public var endpoint: Endpoint? {
        if let stationID { return .station(stationID) }
        guard let latitude, let longitude else { return nil }
        return .place(name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude))
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
/// means renaming this, both entitlements files, and nothing else.
///
/// `UserDefaults(suiteName:)` returns nil if the entitlement is missing or the group
/// isn't provisioned, so the fallback to `.standard` keeps the *app* working; only
/// the widget goes quiet.
public enum SharedStore {
    public static let appGroupID = "group.com.example.SEPTACommute"

    private static let snapshotKey = "commuteSnapshot.v1"

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
        UserDefaults(suiteName: appGroupID) != nil
    }

    public static func snapshot(from defaults: UserDefaults = SharedStore.defaults) -> CommuteSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(CommuteSnapshot.self, from: data)
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
