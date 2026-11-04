import Foundation
import MapKit

/// The rider's car, for pricing a drive. Set in onboarding or Settings.
struct CarProfile: Codable, Equatable {
    var cityMPG: Double = 25
    var highwayMPG: Double = 33
    /// Regular gas, $/gallon. Philadelphia averaged about $3.30 in late 2026.
    var gasPrice: Double = 3.30
    /// What a tolled route costs — Apple Maps says whether a route has tolls, not
    /// how much. The Delaware River bridges into Philadelphia are $6 with E-ZPass.
    var typicalToll: Double = 6
    /// Parking at the far end, if the rider pays for it.
    var parking: Double = 0

    /// Tires, oil and maintenance per mile (AAA's 2025 figure is about 10¢).
    static let wearPerMile = 0.10
    /// Finding a space and walking from it.
    static let parkingSeconds: TimeInterval = 5 * 60
}

/// One way to drive the trip, priced.
struct DrivingEstimate: Equatable, Identifiable {
    var seconds: TimeInterval
    var meters: Double
    var hasTolls: Bool
    var departure: Date
    var fuel: Double
    var tolls: Double
    var wear: Double
    var parking: Double

    var id: String { hasTolls ? "drive-tolls" : "drive" }
    var cost: Double { fuel + tolls + wear + parking }
    var arrival: Date { departure.addingTimeInterval(seconds + CarProfile.parkingSeconds) }

    /// Fuel from the route's average speed: slow means city driving, fast means
    /// highway, and in between is a blend of the car's two ratings.
    static func priced(route seconds: TimeInterval, meters: Double, hasTolls: Bool, car: CarProfile, departure: Date) -> DrivingEstimate {
        let miles = meters / Coordinate.metersPerMile
        let mph = seconds > 0 ? miles / (seconds / 3600) : 0
        let highwayShare = min(1, max(0, (mph - 20) / 30))
        let city = max(car.cityMPG, 1), highway = max(car.highwayMPG, 1)
        let gallons = miles * (highwayShare / highway + (1 - highwayShare) / city)
        return DrivingEstimate(
            seconds: seconds,
            meters: meters,
            hasTolls: hasTolls,
            departure: departure,
            fuel: gallons * car.gasPrice,
            tolls: hasTolls ? car.typicalToll : 0,
            wear: miles * CarProfile.wearPerMile,
            parking: car.parking
        )
    }
}

/// Drive times from Apple Maps, with traffic, for the Best value list.
actor DrivingService {
    static let shared = DrivingService()

    private struct Route: Equatable { var seconds: TimeInterval; var meters: Double; var hasTolls: Bool }
    private var cache: (key: String, at: Date, routes: [Route])?

    /// The fastest route, and — when it has tolls — the fastest one without.
    func estimates(from: Coordinate, to: Coordinate, car: CarProfile, now: Date) async -> [DrivingEstimate] {
        let key = String(format: "%.4f,%.4f>%.4f,%.4f", from.latitude, from.longitude, to.latitude, to.longitude)
        let routes: [Route]
        // Traffic moves; five minutes is fresh enough for "about how long".
        if let cache, cache.key == key, now.timeIntervalSince(cache.at) < 300 {
            routes = cache.routes
        } else {
            var found: [Route] = []
            if let fastest = await Self.route(from: from, to: to, now: now, avoidTolls: false) {
                found.append(fastest)
                if fastest.hasTolls, let free = await Self.route(from: from, to: to, now: now, avoidTolls: true), !free.hasTolls {
                    found.append(free)
                }
            }
            guard !found.isEmpty else { return [] }
            cache = (key, now, found)
            routes = found
        }
        return routes.map {
            DrivingEstimate.priced(route: $0.seconds, meters: $0.meters, hasTolls: $0.hasTolls, car: car, departure: now)
        }
    }

    private static func route(from: Coordinate, to: Coordinate, now: Date, avoidTolls: Bool) async -> Route? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .automobile
        request.departureDate = now
        if avoidTolls { request.tollPreference = .avoid }
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        return Route(seconds: route.expectedTravelTime, meters: route.distance, hasTolls: route.hasTolls)
    }
}
