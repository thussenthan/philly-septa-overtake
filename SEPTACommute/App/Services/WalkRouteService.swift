import Foundation
import MapKit

/// Walking times along real streets, from Apple Maps, for every walk the rider
/// sees outside the main plan: to and from bike docks, and the ends of an
/// alternative route. Cached for the session; a failed request isn't retried for
/// a couple of minutes.
actor WalkRouteService {
    static let shared = WalkRouteService()

    private var cache: [String: TimeInterval] = [:]
    private var failed: [String: Date] = [:]
    private var inFlight: Set<String> = []

    var all: [String: TimeInterval] { cache }

    func hasFailed(_ key: String) -> Bool {
        failed[key].map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    /// Measure each pair not already known. Returns true when anything new landed.
    func measure(_ pairs: [(from: Coordinate, to: Coordinate)]) async -> Bool {
        var changed = false
        for pair in pairs {
            let key = MeasuredWalks.key(from: pair.from, to: pair.to)
            guard cache[key] == nil, !inFlight.contains(key), !hasFailed(key) else { continue }
            // Already there: nothing to ask Apple about.
            if pair.from.distance(to: pair.to) < 25 {
                cache[key] = 0
                changed = true
                continue
            }
            inFlight.insert(key)
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: pair.from.clCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pair.to.clCoordinate))
            request.transportType = .walking
            let route = try? await MKDirections(request: request).calculate().routes.first
            inFlight.remove(key)
            if let route {
                cache[key] = route.expectedTravelTime
                changed = true
            } else {
                failed[key] = Date()
            }
        }
        return changed
    }

    func failedKeys() -> Set<String> {
        Set(failed.filter { Date().timeIntervalSince($0.value) < 120 }.keys)
    }
}
