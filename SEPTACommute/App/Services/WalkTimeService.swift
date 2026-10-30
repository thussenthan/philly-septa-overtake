import Foundation
import MapKit

/// Replaces the geometric walking estimate with real walking directions.
///
/// The engine's estimate is deliberately conservative, but it cannot know about
/// the things that actually cost a rider time: a rail viaduct with no crossing,
/// a one-way pedestrian bridge, a station entrance on the far corner. MapKit
/// does, so the app measures the handful of walks that matter and hands the
/// numbers back to the planner.
///
/// What is kept is the route's *length*, not MapKit's time for it: MapKit walks at
/// its own pace, and a rider who has told the app they walk at 4 mph should get a
/// countdown at 4 mph — the same pace the widget, which has no MapKit, plans with.
///
/// Results are cached and rounded to a 50 m grid, because a rider who has moved
/// two metres does not need their walk re-measured.
@MainActor
final class WalkTimeService: ObservableObject {
    /// Never issue more than this many directions requests per plan. MapKit
    /// throttles aggressively and the estimate is a perfectly good fallback.
    private let maxRequestsPerPlan = 6

    private struct CacheKey: Hashable {
        var fromCell: Int
        var toCell: Int
    }

    /// Metres along the street, per measured walk.
    private var cache: [CacheKey: Double] = [:]
    private var inFlight: Set<CacheKey> = []
    /// When a failed measurement may be tried again. The plan is recomputed every
    /// thirty seconds and on every fix; without this, an offline or throttled phone
    /// re-requested the same six walks each time, which is how throttling gets worse.
    private var retryAfter: [CacheKey: Date] = [:]
    private static let retryInterval: TimeInterval = 5 * 60

    private func isCoolingDown(_ key: CacheKey) -> Bool {
        retryAfter[key].map { $0 > Date() } ?? false
    }

    /// Measure walks between `coordinate` and each station, filling in whatever
    /// is already cached immediately and fetching the rest.
    ///
    /// Returns the overrides available *now*; call again after `onUpdate` fires
    /// to pick up newly measured legs.
    func overrides(
        from coordinate: Coordinate?,
        to destination: Coordinate?,
        accessStations: [Station],
        egressStations: [Station],
        metersPerSecond: Double
    ) -> WalkTimeOverrides {
        var overrides = WalkTimeOverrides()
        guard metersPerSecond > 0 else { return overrides }
        if let coordinate {
            for station in accessStations {
                let key = cacheKey(coordinate, station.coordinate)
                if let meters = cache[key] {
                    overrides[.access(station.id)] = meters / metersPerSecond
                }
            }
        }
        if let destination {
            for station in egressStations {
                let key = cacheKey(station.coordinate, destination)
                if let meters = cache[key] {
                    overrides[.egress(station.id)] = meters / metersPerSecond
                }
            }
        }
        return overrides
    }

    /// Kick off measurement for anything not yet cached.
    /// `onUpdate` fires once per newly measured leg.
    func measure(
        from coordinate: Coordinate?,
        to destination: Coordinate?,
        accessStations: [Station],
        egressStations: [Station],
        onUpdate: @escaping @MainActor () -> Void
    ) {
        var work: [(CacheKey, Coordinate, Coordinate)] = []

        if let coordinate {
            for station in accessStations {
                let key = cacheKey(coordinate, station.coordinate)
                guard cache[key] == nil, !inFlight.contains(key), !isCoolingDown(key) else { continue }
                work.append((key, coordinate, station.coordinate))
            }
        }
        if let destination {
            for station in egressStations {
                let key = cacheKey(station.coordinate, destination)
                guard cache[key] == nil, !inFlight.contains(key), !isCoolingDown(key) else { continue }
                work.append((key, station.coordinate, destination))
            }
        }

        for (key, from, to) in work.prefix(maxRequestsPerPlan) {
            inFlight.insert(key)
            Task { [weak self] in
                let meters = await Self.walkingMeters(from: from, to: to)
                guard let self else { return }
                self.inFlight.remove(key)
                guard let meters else {
                    self.retryAfter[key] = Date().addingTimeInterval(Self.retryInterval)
                    return
                }
                self.cache[key] = meters
                onUpdate()
            }
        }
    }

    /// Rounds to roughly a 50 m grid so nearby requests share a cache entry.
    private func cacheKey(_ from: Coordinate, _ to: Coordinate) -> CacheKey {
        CacheKey(fromCell: cell(from), toCell: cell(to))
    }

    private func cell(_ coordinate: Coordinate) -> Int {
        // ~0.00045° of latitude is ~50 m; longitude cells are coarser but that is
        // fine at Philadelphia's latitude.
        let lat = Int((coordinate.latitude / 0.00045).rounded())
        let lon = Int((coordinate.longitude / 0.00058).rounded())
        return lat &* 1_000_003 &+ lon
    }

    private static func walkingMeters(from: Coordinate, to: Coordinate) async -> Double? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
        ))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first, route.distance > 0 else { return nil }
            return route.distance
        } catch {
            // Offline, throttled, or no walking route: the estimate stands.
            return nil
        }
    }
}
