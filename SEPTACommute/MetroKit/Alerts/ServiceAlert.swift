import Foundation

/// What kind of disruption SEPTA is reporting.
///
/// Ordered by how much it should worry a rider, so the worst one on a journey is
/// the one that gets shown.
public enum AlertSeverity: Int, Sendable, Comparable, CaseIterable {
    /// Worth knowing, not worth changing plans over.
    case advisory = 0
    /// Detour or altered stopping pattern.
    case detour = 1
    /// Running late.
    case delay = 2
    /// Reduced or rerouted service.
    case modifiedService = 3
    /// Not running.
    case suspended = 4

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .advisory: return "Advisory"
        case .detour: return "Detour"
        case .delay: return "Delays"
        case .modifiedService: return "Modified service"
        case .suspended: return "Suspended"
        }
    }
}

/// One disruption affecting one line.
public struct ServiceAlert: Sendable, Hashable, Identifiable {
    /// The line this applies to, or `nil` for a system-wide notice.
    public var lineID: LineID?
    public var severity: AlertSeverity
    /// Rider-facing text, with SEPTA's HTML stripped out.
    public var message: String
    /// The operator's own route label, for attribution ("Broad Street Line").
    public var routeName: String
    public var lastUpdated: String?

    public var id: String { "\(lineID?.rawValue ?? "system")|\(severity.rawValue)|\(message)" }

    public init(
        lineID: LineID?,
        severity: AlertSeverity,
        message: String,
        routeName: String,
        lastUpdated: String? = nil
    ) {
        self.lineID = lineID
        self.severity = severity
        self.message = message
        self.routeName = routeName
        self.lastUpdated = lastUpdated
    }

    public var appliesToWholeSystem: Bool { lineID == nil }
}

/// Alerts for the whole network, and the lookups a plan needs.
public struct AlertDigest: Sendable {
    public var alerts: [ServiceAlert]
    public var fetchedAt: Date

    public init(alerts: [ServiceAlert], fetchedAt: Date) {
        self.alerts = alerts
        self.fetchedAt = fetchedAt
    }

    public static let empty = AlertDigest(alerts: [], fetchedAt: .distantPast)

    /// Alerts affecting any of these lines, worst first, plus system-wide notices.
    public func alerts(affecting lines: Set<LineID>) -> [ServiceAlert] {
        alerts
            .filter { alert in
                guard let lineID = alert.lineID else { return true }
                return lines.contains(lineID)
            }
            .sorted { $0.severity > $1.severity }
    }

    /// The single worst alert on a journey, which is what a card has room for.
    public func worstAlert(for journey: Journey) -> ServiceAlert? {
        let lines = Set(journey.rides.map(\.lineID))
        guard !lines.isEmpty else { return nil }
        return alerts(affecting: lines).first
    }
}
