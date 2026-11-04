import Foundation
import MapKit

/// The rider's car, for pricing a drive. Set in onboarding or Settings.
struct CarProfile: Codable, Equatable {
    var cityMPG: Double = 25
    var highwayMPG: Double = 33
    /// Regular gas, $/gallon. Philadelphia averaged about $3.30 in late 2026.
    var gasPrice: Double = 3.30
    /// Parking at the far end, if the rider pays for it.
    var parking: Double = 0

    /// Tires, oil and maintenance per mile (AAA's 2025 figure is about 10¢).
    static let wearPerMile = 0.10
}

/// One way to drive the trip, priced.
struct DrivingEstimate: Equatable, Identifiable {
    var name: String
    var seconds: TimeInterval
    var meters: Double
    var departure: Date
    var fuel: Double
    var tolls: [Tolls.Charge]
    var wear: Double
    var parking: Double

    var id: String { "drive-\(name)-\(Int(meters))" }
    var tollTotal: Double { tolls.reduce(0) { $0 + $1.amount } }
    var cost: Double { fuel + tollTotal + wear + parking }
    var arrival: Date { departure.addingTimeInterval(seconds) }

    /// Fuel from the route's average speed: slow means city driving, fast means
    /// highway, and in between is a blend of the car's two ratings.
    static func priced(_ route: DrivingService.Route, car: CarProfile, departure: Date) -> DrivingEstimate {
        let miles = route.meters / Coordinate.metersPerMile
        let mph = route.seconds > 0 ? miles / (route.seconds / 3600) : 0
        let highwayShare = min(1, max(0, (mph - 20) / 30))
        let city = max(car.cityMPG, 1), highway = max(car.highwayMPG, 1)
        let gallons = miles * (highwayShare / highway + (1 - highwayShare) / city)
        return DrivingEstimate(
            name: route.name,
            seconds: route.seconds,
            meters: route.meters,
            departure: departure,
            fuel: gallons * car.gasPrice,
            tolls: route.tolls,
            wear: miles * CarProfile.wearPerMile,
            parking: car.parking
        )
    }
}

/// Drive times from Apple Maps, with traffic, for the Best value list.
actor DrivingService {
    static let shared = DrivingService()

    struct Route: Equatable {
        var name: String
        var seconds: TimeInterval
        var meters: Double
        var tolls: [Tolls.Charge]
    }

    private var cache: (key: String, at: Date, routes: [Route])?

    /// Every distinct route Apple Maps offers — its alternatives, and the best
    /// without tolls and without highways — each priced with the tolls it actually
    /// passes. Which are worth showing is the Best value frontier's call: a route
    /// with one toll in the middle can beat both the all-toll and toll-free ones.
    func estimates(from: Coordinate, to: Coordinate, car: CarProfile, now: Date) async -> [DrivingEstimate] {
        let key = String(format: "%.4f,%.4f>%.4f,%.4f", from.latitude, from.longitude, to.latitude, to.longitude)
        let routes: [Route]
        // Traffic moves; five minutes is fresh enough for "about how long".
        if let cache, cache.key == key, now.timeIntervalSince(cache.at) < 300 {
            routes = cache.routes
        } else {
            var found: [Route] = []
            for variant in [Variant.any, .noTolls, .noHighways] {
                for route in await Self.routes(from: from, to: to, now: now, variant: variant) {
                    // The same road twice, from two requests, is one option.
                    let duplicate = found.contains {
                        abs($0.meters - route.meters) < 150 && abs($0.seconds - route.seconds) < 45
                    }
                    if !duplicate { found.append(route) }
                }
            }
            guard !found.isEmpty else { return [] }
            cache = (key, now, found)
            routes = found
        }
        return routes.map { DrivingEstimate.priced($0, car: car, departure: now) }
    }

    enum Variant { case any, noTolls, noHighways }

    private static func routes(from: Coordinate, to: Coordinate, now: Date, variant: Variant) async -> [Route] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .automobile
        request.departureDate = now
        request.requestsAlternateRoutes = variant == .any
        switch variant {
        case .any: break
        case .noTolls: request.tollPreference = .avoid
        case .noHighways: request.highwayPreference = .avoid
        }
        guard let response = try? await MKDirections(request: request).calculate() else { return [] }
        return response.routes.compactMap { route in
            let polyline = route.polyline
            var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
            polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
            let path = points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            let steps = route.steps.map { Tolls.Step(instructions: $0.instructions, meters: $0.distance) }
            let tolls = Tolls.charges(path: path, steps: steps)
            // Apple Maps knows of a toll the table doesn't: leave the route out
            // rather than rank it on a price that is missing a charge.
            if route.hasTolls && tolls.isEmpty { return nil }
            return Route(name: route.name, seconds: route.expectedTravelTime, meters: route.distance, tolls: tolls)
        }
    }
}
