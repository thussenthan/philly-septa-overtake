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

    func refreshIfNeeded() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < statusMaxAge { return }
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
                informationData = try await fetch("station_information.json")
                informationFetchedAt = Date()
            }
            let status = try await fetch("station_status.json")
            guard let informationData else { return }
            stations = try IndegoFeed.decode(information: informationData, status: status)
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
