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
    var toll: Double
    var wear: Double
    var parking: Double

    var id: String { "drive-\(name)-\(Int(meters))" }
    var cost: Double { fuel + toll + wear + parking }
    var arrival: Date { departure.addingTimeInterval(seconds) }

    /// Fuel from the car's highway rating for the miles the directions spend on
    /// highways, and its city rating for the rest.
    static func priced(_ route: DrivingService.Route, car: CarProfile, departure: Date) -> DrivingEstimate {
        let miles = route.meters / Coordinate.metersPerMile
        let highwayShare = route.meters > 0 ? min(1, route.highwayMeters / route.meters) : 0
        let city = max(car.cityMPG, 1), highway = max(car.highwayMPG, 1)
        let gallons = miles * (highwayShare / highway + (1 - highwayShare) / city)
        return DrivingEstimate(
            name: route.name,
            seconds: route.seconds,
            meters: route.meters,
            departure: departure,
            fuel: gallons * car.gasPrice,
            toll: route.toll,
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
        var highwayMeters: Double
        var toll: Double
    }

    /// Road names that mean highway driving, anywhere: interstates and US routes,
    /// expressways, freeways, turnpikes, motorways, autoroutes, autobahns.
    private static let highwayPattern = try! NSRegularExpression(
        pattern: #"\b(I-\d+|US-\d+|Interstate|Expressway|Expy|Freeway|Fwy|Turnpike|Tpke|Motorway|M\d+|A\d+|Autobahn|Autoroute|Autopista|Autostrada|Thruway|Parkway|Pkwy)\b"#,
        options: [.caseInsensitive]
    )

    private static func isHighway(_ instructions: String) -> Bool {
        highwayPattern.firstMatch(in: instructions, range: NSRange(instructions.startIndex..., in: instructions)) != nil
    }

    private var cache: (key: String, at: Date, routes: [Route])?

    /// Every distinct route worth pricing, each with its real toll.
    ///
    /// With a HERE key: HERE's alternatives (up to six) and its best toll-free
    /// route, tolls itemised by HERE for wherever the route goes. Without one:
    /// Apple Maps' alternatives and its best toll-free and highway-free routes,
    /// minus any Apple marks as tolled — there is no honest price for those.
    /// Which are worth showing is the Best value frontier's call.
    func estimates(from: Coordinate, to: Coordinate, car: CarProfile, hereKey: String?, now: Date) async -> [DrivingEstimate] {
        let key = String(format: "%.4f,%.4f>%.4f,%.4f|%@", from.latitude, from.longitude, to.latitude, to.longitude, hereKey == nil ? "apple" : "here")
        let routes: [Route]
        // Traffic moves; five minutes is fresh enough for "about how long".
        if let cache, cache.key == key, now.timeIntervalSince(cache.at) < 300 {
            routes = cache.routes
        } else {
            var candidates: [Route] = []
            if let hereKey {
                for avoid in [false, true] {
                    let found = (try? await HereRouting.routes(from: from, to: to, key: hereKey, avoidTolls: avoid, now: now)) ?? []
                    candidates += found.map {
                        Route(name: $0.name, seconds: $0.seconds, meters: $0.meters, highwayMeters: $0.highwayMeters, toll: $0.toll)
                    }
                }
            }
            if candidates.isEmpty {
                for variant in [Variant.any, .noTolls, .noHighways] {
                    candidates += await Self.routes(from: from, to: to, now: now, variant: variant)
                }
            }
            var found: [Route] = []
            for route in candidates {
                // The same road twice, from two requests, is one option.
                let duplicate = found.contains {
                    ($0.name == route.name && abs($0.meters - route.meters) < 500 && abs($0.toll - route.toll) < 0.01)
                        || (abs($0.meters - route.meters) < 150 && abs($0.seconds - route.seconds) < 45)
                }
                if !duplicate { found.append(route) }
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
            // Apple Maps can't say what a toll costs; without HERE there is no
            // honest price for this route, so it isn't ranked.
            if route.hasTolls { return nil }
            let highwayMeters = route.steps.filter { isHighway($0.instructions) }.reduce(0) { $0 + $1.distance }
            return Route(name: route.name, seconds: route.expectedTravelTime, meters: route.distance,
                         highwayMeters: highwayMeters, toll: 0)
        }
    }
}
