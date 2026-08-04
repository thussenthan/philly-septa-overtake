import Foundation

/// Fetches SEPTA's service alerts and keeps the most recent set in memory.
///
/// Alerts are advice, not routing input. The planner works off the published
/// timetable and does not know that the L is single-tracking tonight; what the app
/// can honestly do is put SEPTA's own words next to the option that uses that
/// line, so a rider knows the schedule it was planned from may not hold. Letting
/// alert text change the routing would mean parsing prose, and getting it wrong
/// would send someone to a platform on the strength of a guess.
///
/// The last good response is cached on disk, so opening the app underground shows
/// this morning's alerts rather than nothing at all.
@MainActor
final class AlertService: ObservableObject {
    @Published private(set) var digest: AlertDigest = .empty
    @Published private(set) var lastError: String?

    /// SEPTA's alerts endpoint. One JSON array, every route, no key required.
    static let endpoint = URL(string: "https://www3.septa.org/api/Alerts/index.php")!

    /// Alerts change on the order of hours. Refetching more often than this would
    /// spend a rider's data to re-read the same sentence.
    private let minimumRefreshInterval: TimeInterval = 5 * 60

    private let session: URLSession
    private let cacheURL: URL?
    private var isFetching = false

    init(session: URLSession = .shared) {
        self.session = session
        self.cacheURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("septa-alerts.json")
        loadCache()
    }

    /// Whether the alerts on screen are old enough to be worth replacing.
    var isStale: Bool {
        Date().timeIntervalSince(digest.fetchedAt) >= minimumRefreshInterval
    }

    /// Fetch if the cached set has aged out. Safe to call on every appearance.
    func refreshIfNeeded() {
        guard isStale, !isFetching else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 12
        // The endpoint sends no useful caching headers, and a stale 304 here would
        // silently freeze the alert list.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "SEPTA's alert service returned \(http.statusCode)."
                return
            }
            let fetched = try AlertsFeed.decode(data, fetchedAt: Date())
            digest = fetched
            lastError = nil
            writeCache(data)
        } catch is CancellationError {
            return
        } catch {
            // Keep whatever is already on screen: yesterday's alert is better than
            // an error message, and the cards never claimed to be live.
            lastError = "Couldn't reach SEPTA's alert service."
        }
    }

    // MARK: - Disk cache

    private func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
        guard let modified = attributes?[.modificationDate] as? Date,
              // A response from last week describes disruptions that have long since
              // been cleared, and showing it would be worse than showing nothing.
              Date().timeIntervalSince(modified) < 24 * 3600,
              let decoded = try? AlertsFeed.decode(data, fetchedAt: modified)
        else { return }
        digest = decoded
    }

    private func writeCache(_ data: Data) {
        guard let cacheURL else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
