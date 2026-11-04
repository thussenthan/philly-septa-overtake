import Foundation

/// Tolls for a drive around Philadelphia, worked out from the route itself.
///
/// Apple Maps says whether a route has tolls, not what they cost, so the app keeps
/// its own table of the region's toll facilities and prices the route against it:
///
/// - **Bridges** are found by where the route crosses the river, and charged in the
///   direction they collect. Every Delaware River crossing here tolls traffic
///   heading west, into Pennsylvania or Delaware, and is free the other way.
/// - **Toll roads** are found by name in the route's directions and charged per mile
///   driven on them.
///
/// E-ZPass passenger-car rates, November 2026. Toll-by-plate costs more.
public enum Tolls {
    public struct Bridge: Sendable {
        public var name: String
        /// Midspan.
        public var at: Coordinate
        /// Charged when crossing westbound; free eastbound.
        public var westbound: Double
    }

    public struct TollRoad: Sendable {
        public var name: String
        /// Lower-cased fragments that identify it in turn-by-turn instructions.
        public var matches: [String]
        public var perMile: Double
    }

    public static let bridges: [Bridge] = [
        // Delaware River Port Authority: $6, unchanged for 2026.
        Bridge(name: "Ben Franklin Bridge", at: Coordinate(latitude: 39.9531, longitude: -75.1350), westbound: 6),
        Bridge(name: "Walt Whitman Bridge", at: Coordinate(latitude: 39.9054, longitude: -75.1285), westbound: 6),
        Bridge(name: "Betsy Ross Bridge", at: Coordinate(latitude: 39.9928, longitude: -75.0603), westbound: 6),
        Bridge(name: "Commodore Barry Bridge", at: Coordinate(latitude: 39.8270, longitude: -75.3735), westbound: 6),
        // Burlington County Bridge Commission.
        Bridge(name: "Tacony-Palmyra Bridge", at: Coordinate(latitude: 40.0123, longitude: -75.0434), westbound: 5),
        Bridge(name: "Burlington-Bristol Bridge", at: Coordinate(latitude: 40.0838, longitude: -74.8679), westbound: 5),
        // Delaware River Joint Toll Bridge Commission: $2 from January 2026.
        Bridge(name: "Scudder Falls Bridge", at: Coordinate(latitude: 40.2617, longitude: -74.8547), westbound: 2),
        Bridge(name: "Trenton-Morrisville Toll Bridge", at: Coordinate(latitude: 40.2006, longitude: -74.7675), westbound: 2),
        // Delaware River and Bay Authority, into Delaware.
        Bridge(name: "Delaware Memorial Bridge", at: Coordinate(latitude: 39.6896, longitude: -75.5165), westbound: 5),
    ]

    public static let roads: [TollRoad] = [
        // 13.8¢ a mile in 2022, raised about 4–5% a year since.
        TollRoad(name: "Pennsylvania Turnpike", matches: ["pennsylvania turnpike", "pa turnpike", "i-276"], perMile: 0.16),
        TollRoad(name: "New Jersey Turnpike", matches: ["new jersey turnpike", "nj turnpike"], perMile: 0.12),
        TollRoad(name: "Atlantic City Expressway", matches: ["atlantic city expressway", "atlantic city expy"], perMile: 0.07),
    ]

    /// One stretch of turn-by-turn directions: what it says, and how far it goes.
    public struct Step: Sendable {
        public var instructions: String
        public var meters: Double
        public init(instructions: String, meters: Double) {
            self.instructions = instructions
            self.meters = meters
        }
    }

    public struct Charge: Sendable, Hashable {
        public var name: String
        public var amount: Double
    }

    /// Every toll the route pays, in order.
    public static func charges(path: [Coordinate], steps: [Step]) -> [Charge] {
        var result: [Charge] = []
        for bridge in bridges {
            if let westbound = crossing(of: bridge.at, by: path), westbound, bridge.westbound > 0 {
                result.append(Charge(name: bridge.name, amount: bridge.westbound))
            }
        }
        for road in roads {
            let meters = steps
                .filter { step in road.matches.contains { step.instructions.lowercased().contains($0) } }
                .reduce(0) { $0 + $1.meters }
            if meters > 0 {
                let amount = (meters / Coordinate.metersPerMile * road.perMile * 100).rounded() / 100
                result.append(Charge(name: road.name, amount: max(amount, 0.5)))
            }
        }
        return result
    }

    /// Whether the path passes over the point, and if so whether it was heading
    /// west there. Checked against each segment rather than each vertex, because a
    /// bridge is often one long straight segment with its vertices on the banks.
    static func crossing(of point: Coordinate, by path: [Coordinate], within radius: Double = 200) -> Bool? {
        guard path.count >= 2 else { return nil }
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(point.latitude * .pi / 180)
        func local(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * metersPerDegreeLon, (c.latitude - point.latitude) * metersPerDegreeLat)
        }
        for (a, b) in zip(path, path.dropFirst()) {
            let p = local(a), q = local(b)
            let dx = q.x - p.x, dy = q.y - p.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / lengthSquared)) : 0
            let cx = p.x + t * dx, cy = p.y + t * dy
            if (cx * cx + cy * cy).squareRoot() <= radius {
                return dx < 0
            }
        }
        return nil
    }
}
