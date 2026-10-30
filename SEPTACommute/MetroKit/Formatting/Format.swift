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

    /// Below this, a countdown shows seconds; above it, whole minutes.
    ///
    /// A ticking seconds digit is a demand for attention, and eleven minutes out there
    /// is nothing to attend to — it reads as urgent when it isn't, and the eye is drawn
    /// to a number that means nothing. Inside two minutes it is the opposite: the
    /// difference between 1:50 and 0:20 is the difference between finishing your coffee
    /// and running, and "1 min" cannot express it.
    public static let countdownSecondsThreshold: TimeInterval = 120

    /// A live countdown: "9 min" far out, "1:47" close in, "now" when it's gone.
    ///
    /// Minutes are floored rather than rounded, deliberately. A countdown that rounds
    /// up says "5 min" with 4:31 left, and the one thing this number must never do is
    /// promise time the rider doesn't have.
    public static func countdown(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "now" }
        let whole = Int(seconds.rounded(.down))
        if seconds > countdownSecondsThreshold {
            let total = whole / 60
            if total < 60 { return "\(total) min" }
            let hours = total / 60
            let remainder = total % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
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
        clockFormatter.string(for: date, timeZone: timeZone)
    }

    private static let clockFormatter = ClockFormatterCache()

    /// "now", "in 4 min", "6 min ago" — the phrasing that follows "Leave …".
    public static func relativeLeave(_ seconds: TimeInterval) -> String {
        if seconds <= 30 { return "now" }
        if seconds < 90 { return "in about a minute" }
        // Floored, like `countdown`: "in 3 min" with two and a half minutes left
        // promises time the rider doesn't have.
        return "in \(minutes((seconds / 60).rounded(.down) * 60))"
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


/// One `DateFormatter` for `Format.clock`, rebuilt when the phone's locale or its
/// 12/24-hour setting changes.
///
/// Building a `DateFormatter` costs far more than formatting with one, and the clock is
/// drawn dozens of times per screen — every departure row, every stop on the strip.
final class ClockFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatter: DateFormatter?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func string(for date: Date, timeZone: TimeZone) -> String {
        lock.lock()
        defer { lock.unlock() }
        if formatter == nil || formatter?.timeZone != timeZone {
            let built = DateFormatter()
            built.timeZone = timeZone
            built.locale = .autoupdatingCurrent
            built.setLocalizedDateFormatFromTemplate("j:mm")
            formatter = built
        }
        return formatter!.string(from: date)
    }

    private func invalidate() {
        lock.lock()
        formatter = nil
        lock.unlock()
    }
}
