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

    public init(
        origin: SnapshotEndpoint,
        destination: SnapshotEndpoint,
        reason: String? = nil,
        savedAt: Date
    ) {
        self.origin = origin
        self.destination = destination
        self.reason = reason
        self.savedAt = savedAt
    }

    /// Whether this describes the same trip, ignoring when it was saved.
    ///
    /// The app replans every thirty seconds; rewriting the snapshot and asking
    /// WidgetKit to reload each time would burn the widget's refresh budget to say
    /// nothing new.
    public func describesSameTrip(as other: CommuteSnapshot?) -> Bool {
        guard let other else { return false }
        return origin == other.origin && destination == other.destination && reason == other.reason
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
/// **Both targets must declare the same App Group.** In Xcode: select each target →
/// Signing & Capabilities → + Capability → App Groups → add the identifier below.
/// Until that is done `UserDefaults(suiteName:)` returns nil, so the fallback keeps
/// the *app* working — the widget simply has nothing to read.
public enum SharedStore {
    /// Change this to match your own bundle identifier prefix.
    public static let appGroupID = "group.com.example.septacommute"

    private static let snapshotKey = "commuteSnapshot.v1"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
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
