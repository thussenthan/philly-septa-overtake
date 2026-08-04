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
    }

    /// Turn a suggestion into a coordinate.
    func resolve(_ suggestion: Suggestion) async -> (address: String, coordinate: Coordinate)? {
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
