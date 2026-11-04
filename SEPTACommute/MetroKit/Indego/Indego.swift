import Foundation

// Indego, Philadelphia's bike share, as a supplemental way to make the trip.
//
// Pure Foundation like the rest of MetroKit: the app fetches the live GBFS feed
// (https://gbfs.bcycle.com/bcycle_indego/) and hands the decoded docks in here.
// Nothing in this file replaces or reorders the Metro answer — it produces one
// more option the home screen lists underneath it.

/// One Indego dock, with what is in it right now.
public struct IndegoStation: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    public var classicBikes: Int
    public var electricBikes: Int
    public var openDocks: Int
    public var isRenting: Bool
    public var isReturning: Bool

    public init(
        id: String, name: String, coordinate: Coordinate,
        classicBikes: Int, electricBikes: Int, openDocks: Int,
        isRenting: Bool = true, isReturning: Bool = true
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.classicBikes = classicBikes
        self.electricBikes = electricBikes
        self.openDocks = openDocks
        self.isRenting = isRenting
        self.isReturning = isReturning
    }
}

public enum IndegoBike: String, Sendable, Hashable, CaseIterable {
    case classic, electric

    public var label: String { self == .classic ? "Classic bike" : "E-bike" }
    /// Typical city riding speed including lights, in metres per second.
    /// Classic ≈ 9 mph, electric ≈ 12.5 mph (pedal-assist tops out at 17).
    public var metersPerSecond: Double { self == .classic ? 4.0 : 5.6 }
}

/// How the rider pays for Indego. Set in Settings.
///
/// Indego's published rates (rideindego.com/pricing, November 2026). The pass fee
/// itself is sunk once bought, so a ride's price is only what that ride adds:
///
/// | Pass | Classic | E-bike | Overtime |
/// |---|---|---|---|
/// | Single Ride | $4.50 for 30 min | +30¢/min | +30¢/min after 30 min |
/// | Guest Pass, Indego30, Indego365 | 60 min included | +20¢/min | +20¢/min after 60 min |
/// | Indego365 Plus | 60 min included | two 30-min rides a day included, then +20¢/min | +20¢/min |
/// | Access passes (ACCESS cardholders) | 60 min included | +7¢/min (Plus: two 30-min rides included) | +7¢/min |
public enum IndegoPass: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case payAsYouGo
    case dayPass
    case indego30
    case indego365
    case indego365Plus
    case access            // Indego30 Access
    case access365
    case access365Plus

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .payAsYouGo: return "Single Ride (no pass)"
        case .dayPass: return "Guest Pass (24 h)"
        case .indego30: return "Indego30"
        case .indego365: return "Indego365"
        case .indego365Plus: return "Indego365 Plus"
        case .access: return "Indego30 Access"
        case .access365: return "Indego365 Access"
        case .access365Plus: return "Indego365 Plus Access"
        }
    }

    /// What the pass costs and what it covers, for the Settings footnote.
    public var passPriceNote: String {
        switch self {
        case .payAsYouGo: return "$4.50 per 30-min classic ride; e-bikes +30¢/min; over 30 min +30¢/min"
        case .dayPass: return "$15 for 24 h; 60-min classic rides; e-bikes +20¢/min"
        case .indego30: return "$20 / 30 days; 60-min classic rides; e-bikes +20¢/min"
        case .indego365: return "$156 / year; 60-min classic rides; e-bikes +20¢/min"
        case .indego365Plus: return "$230 / year; two 30-min e-bike rides a day included, then +20¢/min"
        case .access: return "$5 / 30 days for ACCESS cardholders; e-bikes +7¢/min"
        case .access365: return "$48 / year for ACCESS cardholders; e-bikes +7¢/min"
        case .access365Plus: return "$100 / year for ACCESS cardholders; two 30-min e-bike rides a day, then +7¢/min"
        }
    }

    /// Flat charge per ride (only Single Ride has one).
    var unlockFee: Double { self == .payAsYouGo ? 4.50 : 0 }

    /// Riding time covered before overtime starts.
    var includedMinutes: Double { self == .payAsYouGo ? 30 : 60 }

    /// Overtime and e-bike surcharge, per minute.
    var perMinute: Double {
        switch self {
        case .payAsYouGo: return 0.30
        case .access, .access365, .access365Plus: return 0.07
        case .dayPass, .indego30, .indego365, .indego365Plus: return 0.20
        }
    }

    /// E-bike minutes per ride covered by the pass (the Plus passes' daily rides).
    var includedElectricMinutes: Double {
        self == .indego365Plus || self == .access365Plus ? 30 : 0
    }

    /// Estimated cost of one ride of `minutes` on `bike`.
    ///
    /// Assumes a Plus rider still has an included e-bike ride left today.
    public func price(minutes: Double, bike: IndegoBike) -> Double {
        let m = max(1, minutes.rounded(.up))
        var total = unlockFee + max(0, m - includedMinutes) * perMinute
        if bike == .electric {
            total += max(0, m - includedElectricMinutes) * perMinute
        }
        return (total * 100).rounded() / 100
    }
}

/// A door-to-door bike-share trip: walk to a dock, ride, dock, walk.
public struct IndegoOption: Sendable, Hashable, Identifiable {
    public var bike: IndegoBike
    public var pickup: IndegoStation
    public var dropoff: IndegoStation
    public var walkToPickup: TimeInterval
    public var rideSeconds: TimeInterval
    public var walkFromDropoff: TimeInterval
    public var leaveAt: Date
    public var arrival: Date
    public var price: Double
    /// Bikes of this kind at the pickup dock right now.
    public var bikesAvailable: Int
    /// Straight-line ride distance in metres.
    public var rideMeters: Double

    public var id: String { "\(bike.rawValue)-\(pickup.id)-\(dropoff.id)" }
    public var totalDuration: TimeInterval { arrival.timeIntervalSince(leaveAt) }
}

public struct IndegoPlanner: Sendable {
    public var walking: WalkingModel
    public var pass: IndegoPass
    /// Furthest a rider will walk to or from a dock.
    public var maxWalkMeters: Double = 900
    /// Unlocking at the kiosk and docking at the far end.
    public var unlockSeconds: TimeInterval = 60
    public var dockSeconds: TimeInterval = 45
    /// Streets are not straight lines; bikes follow them a bit more closely than
    /// walkers cut corners, so a slightly higher factor than walking.
    public var rideCircuity: Double = 1.3

    public init(walking: WalkingModel = WalkingModel(), pass: IndegoPass = .payAsYouGo) {
        self.walking = walking
        self.pass = pass
    }

    /// The best option for each kind of bike that is actually available, cheapest
    /// kind first. Empty when no dock with a bike is in walking range of the origin,
    /// or no dock with space is in range of the destination, or the trip is too short
    /// for a bike to be worth it.
    public func options(
        from origin: Coordinate,
        to destination: Coordinate,
        stations: [IndegoStation],
        departAt now: Date
    ) -> [IndegoOption] {
        guard origin.distance(to: destination) > 500 else { return [] }

        func walkSeconds(_ meters: Double) -> TimeInterval {
            walking.walkSeconds(straightLineMeters: meters)
        }

        let renting = stations
            .filter { $0.isRenting }
            .map { ($0, $0.coordinate.distance(to: origin)) }
            .filter { $0.1 <= maxWalkMeters }
            .sorted { $0.1 < $1.1 }
        /// The nearest docks that have this kind of bike: a nearer dock with none
        /// must not crowd out a farther one that has one.
        func pickups(for bike: IndegoBike) -> ArraySlice<(IndegoStation, Double)> {
            renting
                .filter { (bike == .classic ? $0.0.classicBikes : $0.0.electricBikes) > 0 }
                .prefix(12)
        }
        let dropoffs = stations
            .filter { $0.isReturning && $0.openDocks > 0 }
            .map { ($0, $0.coordinate.distance(to: destination)) }
            .filter { $0.1 <= maxWalkMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        guard !renting.isEmpty, !dropoffs.isEmpty else { return [] }

        var result: [IndegoOption] = []
        for bike in IndegoBike.allCases {
            var best: IndegoOption?
            for (pickup, accessMeters) in pickups(for: bike) {
                let available = bike == .classic ? pickup.classicBikes : pickup.electricBikes
                guard available > 0 else { continue }
                for (dropoff, egressMeters) in dropoffs where dropoff.id != pickup.id {
                    let rideMeters = pickup.coordinate.distance(to: dropoff.coordinate)
                    let ride = rideMeters * rideCircuity / bike.metersPerSecond + unlockSeconds + dockSeconds
                    let access = walking.startupSeconds + walkSeconds(accessMeters)
                    let egress = walkSeconds(egressMeters)
                    let arrival = now.addingTimeInterval(access + ride + egress)
                    if let current = best, current.arrival <= arrival { continue }
                    best = IndegoOption(
                        bike: bike,
                        pickup: pickup,
                        dropoff: dropoff,
                        walkToPickup: access,
                        rideSeconds: ride,
                        walkFromDropoff: egress,
                        leaveAt: now,
                        arrival: arrival,
                        price: pass.price(minutes: ride / 60, bike: bike),
                        bikesAvailable: available,
                        rideMeters: rideMeters
                    )
                }
            }
            if let best { result.append(best) }
        }
        // Cheapest first, which in practice is the classic bike whenever there is one.
        return result.sorted { ($0.price, $0.arrival) < ($1.price, $1.arrival) }
    }
}

// MARK: - GBFS decoding

/// Decodes Indego's GBFS v1.1 `station_information` and `station_status` feeds.
public enum IndegoFeed {
    struct Envelope<T: Decodable>: Decodable { var data: T }
    struct InfoData: Decodable { var stations: [Info] }
    struct Info: Decodable {
        var station_id: String
        var name: String
        var lat: Double
        var lon: Double
    }
    struct StatusData: Decodable { var stations: [Status] }
    struct Status: Decodable {
        struct Types: Decodable {
            var classic: Int?
            var smart: Int?
            var electric: Int?
        }
        var station_id: String
        var num_bikes_available: Int?
        var num_docks_available: Int?
        var is_installed: Int?
        var is_renting: Int?
        var is_returning: Int?
        var num_bikes_available_types: Types?
    }

    public static func decode(information: Data, status: Data) throws -> [IndegoStation] {
        let decoder = JSONDecoder()
        let info = try decoder.decode(Envelope<InfoData>.self, from: information).data.stations
        let statuses = try decoder.decode(Envelope<StatusData>.self, from: status).data.stations
        let byID = Dictionary(statuses.map { ($0.station_id, $0) }, uniquingKeysWith: { a, _ in a })
        return info.compactMap { station in
            guard let s = byID[station.station_id], (s.is_installed ?? 1) == 1 else { return nil }
            let types = s.num_bikes_available_types
            let electric = types?.electric ?? 0
            // "smart" bikes are classic bikes with a lock on board; same price.
            let classic = types.map { ($0.classic ?? 0) + ($0.smart ?? 0) }
                ?? max(0, (s.num_bikes_available ?? 0) - electric)
            return IndegoStation(
                id: station.station_id,
                name: station.name,
                coordinate: Coordinate(latitude: station.lat, longitude: station.lon),
                classicBikes: classic,
                electricBikes: electric,
                openDocks: s.num_docks_available ?? 0,
                isRenting: (s.is_renting ?? 1) == 1,
                isReturning: (s.is_returning ?? 1) == 1
            )
        }
    }
}
