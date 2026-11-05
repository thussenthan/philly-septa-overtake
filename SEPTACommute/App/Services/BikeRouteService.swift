import Foundation
import MapKit

/// Measures a bike ride between two docks: Apple Maps' cycling route for its
/// length, and an elevation profile along it for how much it climbs.
///
/// Philadelphia is flat until it isn't — Manayunk, East Falls and the climb out
/// of the river valleys are where an e-bike earns its surcharge. Elevation comes
/// from Open-Meteo's free elevation API (Copernicus 90 m DEM), sampled along the
/// route; it is cached for the session, since docks and hills don't move.
actor BikeRouteService {
    static let shared = BikeRouteService()

    private var cache: [String: IndegoRouteInfo] = [:]
    private var inFlight: Set<String> = []
    private var failed: [String: Date] = [:]

    func cached(_ key: String) -> IndegoRouteInfo? { cache[key] }

    var all: [String: IndegoRouteInfo] { cache }

    /// Measure each pair not already known. Returns true when anything new landed.
    func measure(_ pairs: [(key: String, from: Coordinate, to: Coordinate)]) async -> Bool {
        var changed = false
        for pair in pairs {
            guard cache[pair.key] == nil, !inFlight.contains(pair.key) else { continue }
            if let at = failed[pair.key], Date().timeIntervalSince(at) < 300 { continue }
            inFlight.insert(pair.key)
            let info = await Self.fetch(from: pair.from, to: pair.to)
            inFlight.remove(pair.key)
            if let info {
                cache[pair.key] = info
                changed = true
            } else {
                failed[pair.key] = Date()
            }
        }
        return changed
    }

    private static func fetch(from: Coordinate, to: Coordinate) async -> IndegoRouteInfo? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .cycling
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }

        let polyline = route.polyline
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        await StreetRoutes.shared.store(from: from.clCoordinate, to: to.clCoordinate, type: .cycling, path: points)
        let climb = await climbMeters(along: points, length: route.distance)
        return IndegoRouteInfo(meters: route.distance, climbMeters: climb)
    }

    /// Samples the route every ~75 m (at most 100 points, the API's limit per call)
    /// and adds up the ascent.
    private static func climbMeters(along points: [CLLocationCoordinate2D], length: Double) async -> Double? {
        guard points.count >= 2 else { return nil }
        let spacing = max(75, length / 99)
        var samples: [CLLocationCoordinate2D] = [points[0]]
        var carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            var segment = a.distance(to: b)
            var start = a
            while carried + segment >= spacing {
                let t = (spacing - carried) / segment
                let next = CLLocationCoordinate2D(
                    latitude: start.latitude + (b.latitude - start.latitude) * t,
                    longitude: start.longitude + (b.longitude - start.longitude) * t
                )
                samples.append(next)
                segment -= spacing - carried
                start = next
                carried = 0
            }
            carried += segment
        }
        if let last = points.last { samples.append(last) }
        samples = Array(samples.prefix(100))

        let latitudes = samples.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")
        let longitudes = samples.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
        guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(latitudes)&longitude=\(longitudes)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        struct Response: Decodable { var elevation: [Double] }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let profile = try? JSONDecoder().decode(Response.self, from: data).elevation,
              profile.count == samples.count else { return nil }
        return IndegoRouteInfo.climb(profile: profile)
    }
}
