import Foundation

/// Fetches Indego's live dock availability from its public GBFS feed.
///
/// No key, no dependency. Station locations change rarely and are cached for an
/// hour; availability is refetched at most once a minute, when a plan asks.
@MainActor
final class IndegoService: ObservableObject {
    @Published private(set) var stations: [IndegoStation] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    private let base = URL(string: "https://gbfs.bcycle.com/bcycle_indego/")!
    private var informationData: Data?
    private var informationFetchedAt: Date?
    private var inFlight: Task<Void, Never>?

    private let statusMaxAge: TimeInterval = 60
    private let informationMaxAge: TimeInterval = 3600

    /// After a failure, wait this long before trying again rather than firing a
    /// request (with its ten-second timeout) on every replan.
    private let retryAfterFailure: TimeInterval = 60
    private var lastFailure: Date?

    func refreshIfNeeded() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < statusMaxAge { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < retryAfterFailure { return }
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in
            await self?.refresh()
            self?.inFlight = nil
        }
    }

    func refresh() async {
        do {
            if informationData == nil
                || informationFetchedAt.map({ Date().timeIntervalSince($0) > informationMaxAge }) ?? true {
                // Dock locations barely change: a failed refresh keeps the old ones
                // rather than costing the live counts too.
                if let fresh = try? await fetch("station_information.json") {
                    informationData = fresh
                    informationFetchedAt = Date()
                } else if informationData == nil {
                    throw URLError(.cannotLoadFromNetwork)
                }
            }
            let status = try await fetch("station_status.json")
            guard let informationData else { return }
            stations = try IndegoFeed.decode(information: informationData, status: status)
            lastUpdated = Date()
            lastError = nil
            lastFailure = nil
        } catch {
            lastError = error.localizedDescription
            lastFailure = Date()
        }
    }

    private func fetch(_ name: String) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(name))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
