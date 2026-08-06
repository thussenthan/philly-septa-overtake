import Foundation

/// Asks, occasionally, whether SEPTA has published a newer timetable than this build.
///
/// The app cannot answer that from its own data. SEPTA's feed declares a fortnight of
/// validity while its rail timetables change a few times a year, so the declared
/// window says almost nothing about whether the bundled times are still right —
/// warning on it would mean warning for months at a stretch, about nothing, until the
/// rider stopped reading the warnings. The honest version of the question has to be
/// asked over the network, and this asks it: one small request against SEPTA's own
/// GTFS releases, at most once a day.
///
/// Nothing here affects routing. The bundled timetable is used either way; this only
/// decides whether the Service & data screen says an update is worth installing.
@MainActor
final class ScheduleFreshnessService: ObservableObject {
    /// Set only when SEPTA has published a strictly newer feed than the bundled one.
    @Published private(set) var publishedVersion: String?

    /// Feed versions appear when SEPTA publishes a new feed, which is a matter of
    /// weeks. Asking daily is already generous; asking on every launch would spend a
    /// rider's data to be told the same thing.
    private let minimumRefreshInterval: TimeInterval = 24 * 3600
    private static let checkedAtKey = "scheduleFreshness.checkedAt"
    private static let versionKey = "scheduleFreshness.publishedVersion"

    private let bundledVersion: String
    private let session: URLSession
    private let defaults: UserDefaults
    private var isFetching = false

    init(
        bundledVersion: String = SEPTAData.feedVersion,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.bundledVersion = bundledVersion
        self.session = session
        self.defaults = defaults
        // Remembered across launches so the notice survives being offline, and so a
        // cold start doesn't have to wait on the network to know what it knew before.
        if let stored = defaults.string(forKey: Self.versionKey),
           ScheduleFreshness.isSuperseded(bundled: bundledVersion, remote: stored) {
            publishedVersion = stored
        }
    }

    /// True once a newer feed is known to exist. What the UI actually asks.
    var isSuperseded: Bool { publishedVersion != nil }

    func refreshIfNeeded() {
        let last = defaults.object(forKey: Self.checkedAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= minimumRefreshInterval, !isFetching else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        var request = URLRequest(url: ScheduleFreshness.releasesURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let remote = ScheduleFreshness.version(fromReleasesJSON: data) else {
                // Deliberately not surfaced. A rider cannot act on "the update check
                // failed", and saying so would put an error on screen every time they
                // opened the app on the platform with no signal.
                return
            }
            defaults.set(Date(), forKey: Self.checkedAtKey)
            if ScheduleFreshness.isSuperseded(bundled: bundledVersion, remote: remote) {
                defaults.set(remote, forKey: Self.versionKey)
                publishedVersion = remote
            } else {
                // Covers the case that matters after an app update: the build caught
                // up, so the notice has to go away by itself.
                defaults.removeObject(forKey: Self.versionKey)
                publishedVersion = nil
            }
        } catch {
            return
        }
    }
}
