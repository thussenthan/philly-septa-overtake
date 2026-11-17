import Foundation
import MapKit

/// Address autocomplete for the "where do you live?" fields.
///
/// Results are biased to a box around Philadelphia so typing "1500 Market" does
/// not offer San Francisco first.
@MainActor
final class AddressSearch: NSObject, ObservableObject {
    struct Suggestion: Identifiable, Hashable {
        var id: String { "\(title)|\(subtitle)" }
        var title: String
        var subtitle: String
        /// Known already for a searched place or typed coordinates; `nil` for a
        /// completer suggestion, which still has to be looked up.
        var coordinate: Coordinate?

        var combined: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
    }

    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            completer.queryFragment = query
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions = []
            }
            searchPlaces()
        }
    }

    /// Businesses and landmarks ("Aldi", "Trader Joe's"), which the completer is
    /// poor at: a full search returns their coordinates directly.
    @Published private(set) var places: [Suggestion] = []
    private var placeTask: Task<Void, Never>?

    /// Places first, then address completions that aren't the same thing again.
    var allSuggestions: [Suggestion] {
        let titles = Set(places.map { $0.title.lowercased() })
        return places + suggestions.filter { !titles.contains($0.title.lowercased()) }
    }

    private func searchPlaces() {
        placeTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, Coordinate.parse(text) == nil else {
            places = []
            return
        }
        placeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.region = Self.philadelphiaRegion
            request.resultTypes = [.pointOfInterest, .address]
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, let self else { return }
            let center = Coordinate(latitude: Self.serviceRegion.center.latitude, longitude: Self.serviceRegion.center.longitude)
            self.places = (response?.mapItems ?? []).compactMap { item -> Suggestion? in
                let c = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                // SEPTA's service area only; "Aldi" has stores in every state.
                guard c.distance(to: center) <= 85_000 else { return nil }
                let address = Self.describe(item.placemark, fallback: "")
                let title = item.name ?? address
                guard !title.isEmpty else { return nil }
                return Suggestion(title: title, subtitle: title == address ? "" : address, coordinate: c)
            }
            .prefix(8).map { $0 }
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var isResolving = false
    @Published var errorMessage: String?

    private let completer = MKLocalSearchCompleter()

    /// Roughly Philadelphia and its inner suburbs.
    static let philadelphiaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.9800, longitude: -75.1600),
        latitudinalMeters: 26_000,
        longitudinalMeters: 26_000
    )

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.philadelphiaRegion
        // Suggest only places SEPTA reaches. The region alone is a preference,
        // and "1500 Market St" came back in San Francisco and Harrisburg.
        if #available(iOS 18.0, *) {
            completer.region = Self.serviceRegion
            completer.regionPriority = .required
        }
    }

    /// Everywhere SEPTA runs, Regional Rail included: Trenton to Wilmington,
    /// Thorndale to Doylestown.
    static let serviceRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.25),
        latitudinalMeters: 150_000,
        longitudinalMeters: 150_000
    )

    /// Turn a suggestion into a coordinate.
    func resolve(_ suggestion: Suggestion) async -> (address: String, coordinate: Coordinate)? {
        if let known = suggestion.coordinate {
            return (address: suggestion.subtitle.isEmpty ? suggestion.title : suggestion.combined, coordinate: known)
        }
        isResolving = true
        defer { isResolving = false }

        // Resolved by text rather than by holding onto the completion object:
        // `MKLocalSearchCompletion` is not safe to carry across actors, and the
        // combined title plus a Philadelphia-biased region is precise enough.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = suggestion.combined
        request.region = Self.philadelphiaRegion

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                errorMessage = "Couldn't find that address."
                return nil
            }
            let coordinate = item.placemark.coordinate
            return (
                address: Self.describe(item.placemark, fallback: suggestion.combined),
                coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
        } catch {
            errorMessage = "Address lookup failed. Check your connection and try again."
            return nil
        }
    }

    /// Resolve free text, for a rider who types an address and hits return
    /// without picking a suggestion.
    func resolveRawQuery() async -> (address: String, coordinate: Coordinate)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await resolve(Suggestion(title: trimmed, subtitle: ""))
    }

    private static func describe(_ placemark: MKPlacemark, fallback: String) -> String {
        var parts: [String] = []
        if let number = placemark.subThoroughfare, let street = placemark.thoroughfare {
            parts.append("\(number) \(street)")
        } else if let street = placemark.thoroughfare {
            parts.append(street)
        } else if let name = placemark.name {
            parts.append(name)
        }
        if let city = placemark.locality { parts.append(city) }
        if let state = placemark.administrativeArea { parts.append(state) }
        return parts.isEmpty ? fallback : parts.joined(separator: ", ")
    }
}

extension AddressSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Flattened to plain strings here, so nothing non-Sendable crosses over.
        let mapped = completer.results.prefix(12).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor [weak self] in
            self?.suggestions = mapped
            self?.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            // An empty or in-progress fragment fails routinely; only surface a
            // problem when the rider has actually typed something.
            guard let self, !self.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.suggestions = []
        }
    }
}
