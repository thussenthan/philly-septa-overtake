import Foundation

/// Number and time formatting shared by the engine's prose and the UI.
///
/// Kept in `MetroKit` so the sentence a test asserts on is the sentence a rider
/// reads. All of it is time-zone aware: a commuter app that renders 8:12 PM as
/// 12:12 AM because the device is in UTC is worse than useless.
public enum Format {
    public static var timeZone: TimeZone = ServiceCalendar.easternTimeZone

    // MARK: - Durations

    /// "4 min", "1 hr 12 min", "under a minute".
    public static func minutes(_ seconds: TimeInterval) -> String {
        let total = Int((abs(seconds) / 60).rounded())
        if total == 0 { return "under a minute" }
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let remainder = total % 60
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    /// Compact form for tight spaces: "4m", "1h12m".
    public static func compactMinutes(_ seconds: TimeInterval) -> String {
        let total = Int((abs(seconds) / 60).rounded())
        if total < 60 { return "\(total)m" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
    }

    /// A live countdown: "4:07", "0:12", "now".
    public static func countdown(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "now" }
        let whole = Int(seconds.rounded(.down))
        if whole >= 3600 {
            return "\(whole / 3600):\(pad((whole % 3600) / 60)):\(pad(whole % 60))"
        }
        return "\(whole / 60):\(pad(whole % 60))"
    }

    /// "+3 min" / "−2 min" / "same time", for comparing options.
    public static func signedMinutes(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())
        if total == 0 { return "same time" }
        return total > 0 ? "+\(total) min" : "−\(-total) min"
    }

    // MARK: - Instants

    /// "8:14 PM", in the agency's time zone.
    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// "now", "in 4 min", "6 min ago" — the phrasing that follows "Leave …".
    public static func relativeLeave(_ seconds: TimeInterval) -> String {
        if seconds <= 30 { return "now" }
        if seconds < 90 { return "in about a minute" }
        return "in \(minutes(seconds))"
    }

    // MARK: - Distance

    /// Whether the rider's locale wants metres or feet.
    ///
    /// `measurementSystem` is available unconditionally at this package's minimum
    /// platforms, so no availability check is needed. The `usesMetricSystem`
    /// fallback exists only for non-Darwin Foundation, where the modern spelling
    /// is absent — and is compiled out on Apple platforms, where it is deprecated.
    static var prefersMetric: Bool {
        #if canImport(Darwin)
        return Locale.autoupdatingCurrent.measurementSystem != .us
        #else
        return Locale.autoupdatingCurrent.usesMetricSystem
        #endif
    }

    /// Uses the unit the rider's locale expects.
    public static func distance(meters: Double) -> String {
        if prefersMetric {
            if meters < 950 { return "\(Int((meters / 10).rounded()) * 10) m" }
            return String(format: "%.1f km", meters / 1000)
        }
        let miles = meters / Coordinate.metersPerMile
        if miles < 0.19 {
            let feet = Int((meters * 3.28084 / 50).rounded()) * 50
            return "\(feet) ft"
        }
        return String(format: "%.1f mi", miles)
    }

    // MARK: - Helpers

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "3 stops" / "1 stop".
    public static func stops(_ count: Int) -> String {
        count == 1 ? "1 stop" : "\(count) stops"
    }
}
