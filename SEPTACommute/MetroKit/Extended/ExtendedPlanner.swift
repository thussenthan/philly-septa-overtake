import Foundation

/// A walk between two places, as part of an ``ExtendedItinerary``.
public struct ExtendedWalk: Sendable, Hashable {
    public var from: Coordinate
    public var to: Coordinate
    public var fromName: String
    public var toName: String
    public var seconds: TimeInterval

    public init(from: Coordinate, to: Coordinate, fromName: String, toName: String, seconds: TimeInterval) {
        self.from = from
        self.to = to
        self.fromName = fromName
        self.toName = toName
        self.seconds = seconds
    }
}

/// One vehicle ridden, as part of an ``ExtendedItinerary``.
public struct ExtendedRide: Sendable, Hashable {
    /// "47", "CHE", "L1".
    public var routeShortName: String
    public var routeLongName: String
    public var mode: ExtendedMode
    /// Six hex digits, no `#`. May be empty.
    public var colorHex: String
    public var headsign: String
    /// SEPTA's direction word ("Northbound", "Inbound"); may be empty.
    public var direction: String
    public var boardName: String
    public var boardCoordinate: Coordinate
    public var departure: Date
    public var alightName: String
    public var alightCoordinate: Coordinate
    public var arrival: Date
    /// The street or track the vehicle follows, for drawing on a map: starts exactly
    /// at ``boardCoordinate``, follows SEPTA's route shape, ends exactly at
    /// ``alightCoordinate``. When the route has no usable shape it is the stops
    /// ridden through, as ``stopCoordinates``. Its point count is not a stop count.
    public var path: [Coordinate]
    /// Every stop ridden through, board...alight inclusive.
    public var stopCoordinates: [Coordinate]
    /// Stops ridden past (not counting the boarding stop).
    public var stopCount: Int { max(0, stopCoordinates.count - 1) }
}

public enum ExtendedLeg: Sendable, Hashable {
    case walk(ExtendedWalk)
    case ride(ExtendedRide)
}

/// A door-to-door plan over all of SEPTA.
public struct ExtendedItinerary: Sendable, Hashable, Identifiable {
    public var id: String
    public var legs: [ExtendedLeg]
    /// Last moment to leave the origin: first boarding − access walk − boarding margin.
    public var leaveBy: Date
    /// Arrival at the destination door.
    public var arrival: Date
    /// Estimated adult fare on SEPTA Key, USD. A lower bound when `fareIsKnown`
    /// is false: some Regional Rail pair had no fare in the feed.
    public var fare: Double
    /// False when part of the fare couldn't be priced. Such an itinerary must not
    /// win a price comparison on a number that is really "unknown".
    public var fareIsKnown: Bool = true
    /// True when any ride is a bus or Regional Rail — something the Metro planner can't offer.
    public var usesBusOrRail: Bool

    public var rides: [ExtendedRide] {
        legs.compactMap { if case let .ride(r) = $0 { return r } else { return nil } }
    }

    public var walkingSeconds: TimeInterval {
        legs.reduce(0) { total, leg in
            if case let .walk(w) = leg { return total + w.seconds }
            return total
        }
    }
}

/// Round-based (RAPTOR) planner over the whole SEPTA network.
///
/// Round *k* finds the earliest arrival at every stop using at most *k* vehicles,
/// with footpaths of up to ``ExtendedNetwork/footpathRadius`` between rides. The
/// result is the Pareto set over (arrival, number of rides): an itinerary with more
/// rides is only returned when it arrives strictly earlier. Each itinerary is then
/// tightened backwards — earlier rides move to the latest trip of the same pattern
/// that still makes the connection — so `leaveBy` isn't padded with needless waits.
public struct ExtendedPlanner: Sendable {
    public var network: ExtendedNetwork
    public var walking: WalkingModel
    /// Arrive at the first stop this long before the vehicle; part of `leaveBy`.
    public var boardingMarginSeconds: TimeInterval
    /// Minimum time between stepping off one vehicle (plus any walk) and the next departure.
    public var transferSlackSeconds: TimeInterval = 60
    /// Most vehicles in one itinerary (3 = two changes).
    public var maxRides: Int = 3
    /// Stops this close to the origin/destination are access/egress candidates.
    public var accessRadiusMeters: Double = 1000
    /// Cap on access/egress candidates at each end.
    public var maxAccessStops: Int = 160
    /// A walk-only option is considered when origin and destination are this close.
    public var walkOnlyMaxMeters: Double = 3000
    /// Modes the search may not ride. Lets the app ask "what would the bus do?"
    /// when the Metro would otherwise win every round.
    public var excludedModes: Set<ExtendedMode> = []
    public var timeZone: TimeZone = TimeZone(identifier: "America/New_York") ?? .current
    /// Leave out the modes whose feed no longer covers the service date (see
    /// ``ExtendedNetwork/busValidUntil`` / ``ExtendedNetwork/railValidUntil``): a
    /// stale timetable would otherwise be presented as fact.
    public var skipExpiredModes = true

    public init(network: ExtendedNetwork, walking: WalkingModel = WalkingModel(), boardingMarginSeconds: TimeInterval = 30) {
        self.network = network
        self.walking = walking
        self.boardingMarginSeconds = boardingMarginSeconds
    }

    // MARK: - Plan

    /// Pareto-optimal itineraries by number of rides, sorted by arrival.
    public func plan(from origin: Coordinate, to destination: Coordinate, departAt: Date) -> [ExtendedItinerary] {
        let net = network
        guard walking.metersPerSecond.isFinite, walking.metersPerSecond > 0 else { return [] }
        let service = ServiceFrame(departAt: departAt, timeZone: timeZone)
        let t0 = Int32(departAt.timeIntervalSince(service.start).rounded(.up))
        let clock = ServiceDayClock(net: net, frame: service)
        var excluded = excludedModes
        if skipExpiredModes { excluded.formUnion(net.expiredModes(onServiceDate: service.yyyyMMdd)) }

        let access = candidates(near: origin)
        let egress = candidates(near: destination)
        let directMeters = origin.distance(to: destination)
        let walkOnlySeconds = walking.startupSeconds + walking.walkSeconds(straightLineMeters: directMeters)

        var results: [ExtendedItinerary] = []
        var bestArrival = Int32.max
        if directMeters <= walkOnlyMaxMeters {
            bestArrival = t0 + Self.seconds(walkOnlySeconds)
            results.append(ExtendedItinerary(
                id: "walk",
                legs: [.walk(ExtendedWalk(from: origin, to: destination, fromName: "Start", toName: "Destination",
                                          seconds: walkOnlySeconds))],
                leaveBy: departAt,
                arrival: departAt.addingTimeInterval(walkOnlySeconds),
                fare: 0, usesBusOrRail: false))
        }
        guard !access.isEmpty, !egress.isEmpty else { return results }

        var search = RaptorSearch(net: net, rounds: maxRides, clock: clock,
                            slack: Int32(transferSlackSeconds.rounded(.up)), walking: walking)
        let margin = Int32(boardingMarginSeconds.rounded(.up))
        let accessSeconds = access.map { Self.seconds(walking.startupSeconds + walking.walkSeconds(straightLineMeters: $0.meters)) }
        let egressSeconds = egress.map { Self.seconds(walking.walkSeconds(straightLineMeters: $0.meters)) }
        for (i, a) in access.enumerated() {
            search.seed(stop: a.stop, at: t0 + accessSeconds[i] + margin)
        }
        if !excluded.isEmpty {
            search.skipPattern = (0..<net.patternCount).map {
                excluded.contains(net.routes[Int(net.patternRoute[$0])].mode)
            }
        }
        search.egress = zip(egress.map(\.stop), egressSeconds).map { ($0, $1) }
        search.targetBound = bestArrival

        for k in 1...max(1, maxRides) {
            guard search.runRound(k) else { break }
            // Best door arrival using exactly this round's labels.
            var arrival = Int32.max, via = -1
            for (s, e) in search.egress {
                let label = search.tau[k * search.n + s]
                if label != .max, label + e < arrival { arrival = label + e; via = s }
            }
            guard via >= 0, arrival < bestArrival else { continue }
            bestArrival = arrival
            search.targetBound = arrival
            guard var journey = search.reconstruct(stop: via, round: k) else { continue }
            tighten(&journey, clock: clock)
            let accessIndex = access.firstIndex { $0.stop == journey.accessStop } ?? 0
            let egressIndex = egress.firstIndex { $0.stop == via } ?? 0
            results.append(itinerary(journey, origin: origin, destination: destination, service: service,
                                     accessSeconds: accessSeconds[accessIndex],
                                     egressSeconds: egressSeconds[egressIndex], margin: margin))
        }

        // Pareto by rides: drop any option a fewer-ride option reaches no later.
        results.sort { ($0.rides.count, $0.arrival) < ($1.rides.count, $1.arrival) }
        var kept: [ExtendedItinerary] = []
        for r in results where !kept.contains(where: { $0.arrival <= r.arrival }) {
            kept.append(r)
        }
        return kept.sorted { $0.arrival < $1.arrival }
    }

    // MARK: - Access / egress

    /// Stops near a place worth trying: the nearest few, every non-bus stop, and the
    /// nearest stop of every pattern in reach — walking past one stop of a route to
    /// a farther stop of the same route rarely helps, but a different route might.
    func candidates(near coordinate: Coordinate) -> [(stop: Int, meters: Double)] {
        var near = network.nearestStops(to: coordinate, within: accessRadiusMeters)
        if near.isEmpty { near = network.nearestStops(to: coordinate, within: accessRadiusMeters * 2.5, limit: 8) }
        var seen = Set<Int32>()
        var kept: [(stop: Int, meters: Double)] = []
        for (rank, c) in near.enumerated() {
            let lo = Int(network.stopPatternStart[c.stop]), hi = Int(network.stopPatternStart[c.stop + 1])
            var fresh = false
            for k in lo..<hi where seen.insert(network.stopPatternIndex[k]).inserted { fresh = true }
            if rank < 24 || fresh || network.stopIsRapid[c.stop] {
                kept.append(c)
                if kept.count >= maxAccessStops { break }
            }
        }
        return kept
    }

    // MARK: - Tighten

    /// Move every ride but the last to the latest trip of its pattern that still
    /// makes the next connection.
    func tighten(_ journey: inout RaptorJourney, clock: ServiceDayClock) {
        let net = network
        guard journey.rides.count >= 2 else { return }
        let slack = Int32(transferSlackSeconds.rounded(.up))
        for i in stride(from: journey.rides.count - 2, through: 0, by: -1) {
            let next = journey.rides[i + 1]
            let nextBoard = next.start + net.boardOffset(next.pattern, next.boardPos)
            let ride = journey.rides[i]
            let alightStop = net.stop(ride.pattern, ride.alightPos)
            let boardStop = net.stop(next.pattern, next.boardPos)
            let walk = alightStop == boardStop ? 0 : Self.seconds(walking.walkSeconds(straightLineMeters: net.meters(fromStop: alightStop, toStop: boardStop)))
            let deadline = nextBoard - walk - slack
            let latest = clock.latestTrip(pattern: ride.pattern, position: ride.alightPos, arriveBy: deadline)
            if latest != .min, latest > ride.start { journey.rides[i].start = latest }
        }
    }

    // MARK: - Build the public value

    func itinerary(_ j: RaptorJourney, origin: Coordinate, destination: Coordinate, service: ServiceFrame,
                   accessSeconds: Int32, egressSeconds: Int32, margin: Int32) -> ExtendedItinerary {
        let net = network
        func date(_ seconds: Int32) -> Date { service.date(seconds) }
        var legs: [ExtendedLeg] = []
        var idParts: [String] = []
        var rides: [ExtendedRide] = []
        var rideStops: [(board: Int, alight: Int, departure: Int32, mode: ExtendedMode)] = []

        let firstRide = j.rides[0]
        let firstBoardStop = net.stop(firstRide.pattern, firstRide.boardPos)
        let firstDeparture = firstRide.start + net.boardOffset(firstRide.pattern, firstRide.boardPos)
        legs.append(.walk(ExtendedWalk(from: origin, to: net.stopCoordinates[firstBoardStop], fromName: "Start",
                                       toName: net.stopNames[firstBoardStop], seconds: TimeInterval(accessSeconds))))
        for (i, r) in j.rides.enumerated() {
            let base = Int(net.patternStart[r.pattern])
            let route = net.routes[Int(net.patternRoute[r.pattern])]
            let board = Int(net.patternStops[base + r.boardPos])
            let alight = Int(net.patternStops[base + r.alightPos])
            let departure = r.start + net.patternBoardOffsets[base + r.boardPos]
            let arrival = r.start + net.patternOffsets[base + r.alightPos]
            let stops = (r.boardPos...r.alightPos).map { net.stopCoordinates[Int(net.patternStops[base + $0])] }
            let path = net.ridePath(pattern: r.pattern, boardPos: r.boardPos, alightPos: r.alightPos)
            let ride = ExtendedRide(
                routeShortName: route.shortName, routeLongName: route.longName, mode: route.mode,
                colorHex: route.colorHex, headsign: net.patternHeadsign[r.pattern],
                direction: net.patternDirection[r.pattern],
                boardName: net.stopNames[board], boardCoordinate: net.stopCoordinates[board], departure: date(departure),
                alightName: net.stopNames[alight], alightCoordinate: net.stopCoordinates[alight], arrival: date(arrival),
                path: path, stopCoordinates: stops)
            if i > 0 {
                let previous = rideStops[i - 1].alight
                if previous != board {
                    let seconds = walking.walkSeconds(straightLineMeters: net.meters(fromStop: previous, toStop: board))
                    legs.append(.walk(ExtendedWalk(from: net.stopCoordinates[previous], to: net.stopCoordinates[board],
                                                   fromName: net.stopNames[previous], toName: net.stopNames[board],
                                                   seconds: seconds.rounded(.up))))
                }
            }
            legs.append(.ride(ride))
            rides.append(ride)
            rideStops.append((board, alight, departure, route.mode))
            idParts.append("\(route.shortName)@\(board)>\(alight)#\(departure)")
        }
        let last = rideStops[rideStops.count - 1]
        var doorArrival = j.rides.last.map { $0.start + net.offset($0.pattern, $0.alightPos) } ?? firstDeparture
        // The search may have reached the egress stop on foot from where the last
        // ride stopped; that walk is part of the trip.
        var exitStop = last.alight
        if j.egressStop != last.alight {
            let seconds = Self.seconds(walking.walkSeconds(straightLineMeters: net.meters(fromStop: last.alight, toStop: j.egressStop)))
            legs.append(.walk(ExtendedWalk(from: net.stopCoordinates[last.alight], to: net.stopCoordinates[j.egressStop],
                                           fromName: net.stopNames[last.alight], toName: net.stopNames[j.egressStop],
                                           seconds: TimeInterval(seconds))))
            doorArrival += seconds
            exitStop = j.egressStop
        }
        legs.append(.walk(ExtendedWalk(from: net.stopCoordinates[exitStop], to: destination,
                                       fromName: net.stopNames[exitStop], toName: "Destination",
                                       seconds: TimeInterval(egressSeconds))))
        doorArrival += egressSeconds
        let priced = fare(rideStops) { service.isWeekendFare(at: $0) }
        return ExtendedItinerary(
            id: idParts.joined(separator: "|"),
            legs: legs,
            leaveBy: date(firstDeparture - accessSeconds - margin),
            arrival: date(doorArrival),
            fare: priced.amount,
            fareIsKnown: priced.known,
            usesBusOrRail: rides.contains { $0.mode == .bus || $0.mode == .rail })
    }

    /// SEPTA Key estimate: Regional Rail priced per unbroken run of rail rides by
    /// zone (first boarding → last alighting); bus, trolley and Metro at the flat
    /// fare with up to `freeTransfers` free changes inside the transfer window.
    /// Changes between rail and the rest are not discounted. `weekend` says whether
    /// the weekend rail fare applies to a departure (service-frame seconds).
    func fare(_ rides: [(board: Int, alight: Int, departure: Int32, mode: ExtendedMode)],
              weekend: (Int32) -> Bool) -> (amount: Double, known: Bool) {
        let net = network
        var total = 0.0
        var known = true
        var paidAt: Int32?
        var transfersUsed = 0
        var i = 0
        while i < rides.count {
            let r = rides[i]
            if r.mode == .rail {
                var j = i
                while j + 1 < rides.count, rides[j + 1].mode == .rail { j += 1 }
                if let railFare = net.railFare(fromStop: r.board, toStop: rides[j].alight, weekend: weekend(r.departure)) {
                    total += railFare
                } else {
                    known = false
                }
                i = j + 1
                continue
            }
            if let paid = paidAt, Int(r.departure - paid) <= net.transferWindowSeconds, transfersUsed < net.freeTransfers {
                transfersUsed += 1
            } else {
                total += net.busFare
                paidAt = r.departure
                transfersUsed = 0
            }
            i += 1
        }
        return ((total * 100).rounded() / 100, known)
    }

    /// Whole seconds for the search, rounded up and clamped: an infinite or NaN
    /// walk (a zero walking speed) must not trap converting to Int32.
    static func seconds(_ t: TimeInterval) -> Int32 {
        guard !t.isNaN else { return 0 }
        return Int32(min(max(t.rounded(.up), 0), Double(unreachable)))
    }

    /// Far beyond any trip, yet small enough to add to a time of day without overflow.
    static let unreachable: Int32 = 10_000_000
}

/// The service day a query is planned in, and its neighbours, as the Metro
/// planner's ``ServiceCalendar`` sees them: times count from noon − 12 h (the
/// GTFS convention, right on the days the clocks change), and holidays run the
/// substitute (Sunday) timetable.
struct ServiceFrame {
    let calendar: ServiceCalendar
    let yesterday: ServiceDay
    let today: ServiceDay
    let tomorrow: ServiceDay
    /// Today's date, yyyyMMdd.
    let yyyyMMdd: String

    init(departAt: Date, timeZone: TimeZone) {
        let calendar = ServiceCalendar(timeZone: timeZone)
        self.calendar = calendar
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let today = calendar.serviceDay(containing: departAt)
        func neighbour(_ days: Int) -> ServiceDay {
            let noon = gregorian.date(byAdding: .day, value: days, to: today.noon)
                ?? today.noon.addingTimeInterval(TimeInterval(days * 86_400))
            return calendar.serviceDay(containing: noon)
        }
        self.today = today
        yesterday = neighbour(-1)
        tomorrow = neighbour(1)
        let parts = gregorian.dateComponents([.year, .month, .day], from: today.noon)
        yyyyMMdd = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Today's nominal midnight; search times are seconds after it.
    var start: Date { today.start }

    func date(_ seconds: Int32) -> Date { start.addingTimeInterval(TimeInterval(seconds)) }

    /// Seconds from today's start to another service day's start: ±86 400, or
    /// ±82 800 / ±90 000 across a clock change.
    func shift(to day: ServiceDay) -> Int32 { Int32(day.start.timeIntervalSince(start).rounded()) }

    /// Weekend (or holiday) Regional Rail fare for a departure at `seconds`.
    func isWeekendFare(at seconds: Int32) -> Bool {
        calendar.dayType(for: date(seconds)).isWeekend
    }

    static func index(_ day: DayType) -> Int { DayType.allCases.firstIndex(of: day) ?? 0 }
}

// MARK: - Internals

struct RaptorRide {
    var pattern: Int
    var start: Int32
    var boardPos: Int
    var alightPos: Int
}

struct RaptorJourney {
    var accessStop: Int
    var rides: [RaptorRide]
    /// Where the rider leaves the network: the last ride's alighting stop, or a stop
    /// a footpath away from it.
    var egressStop: Int
}

extension ExtendedNetwork {
    @inline(__always) func stop(_ pattern: Int, _ position: Int) -> Int {
        Int(patternStops[Int(patternStart[pattern]) + position])
    }

    @inline(__always) func offset(_ pattern: Int, _ position: Int) -> Int32 {
        patternOffsets[Int(patternStart[pattern]) + position]
    }

    /// When to be at the stop to board: the pattern's fastest trip, not its median.
    @inline(__always) func boardOffset(_ pattern: Int, _ position: Int) -> Int32 {
        patternBoardOffsets[Int(patternStart[pattern]) + position]
    }
}

/// Trip lookups for one service day, including the previous day's after-midnight
/// trips and the next day's early ones. A trip is identified by its start time in
/// seconds after this service day's midnight.
struct ServiceDayClock {
    let net: ExtendedNetwork
    let days: (Int, Int, Int)   // day types (0 = Monday): yesterday, today, tomorrow
    /// Each day's start relative to today's, in seconds.
    let shifts: (Int32, Int32, Int32)

    init(net: ExtendedNetwork, days: (Int, Int, Int), shifts: (Int32, Int32, Int32) = (-86_400, 0, 86_400)) {
        self.net = net
        self.days = days
        self.shifts = shifts
    }

    init(net: ExtendedNetwork, frame: ServiceFrame) {
        self.init(net: net,
                  days: (ServiceFrame.index(frame.yesterday.dayType), ServiceFrame.index(frame.today.dayType),
                         ServiceFrame.index(frame.tomorrow.dayType)),
                  shifts: (frame.shift(to: frame.yesterday), 0, frame.shift(to: frame.tomorrow)))
    }

    /// Earliest trip start whose boarding time at `position` is ≥ `time`, or `.max`.
    @inline(__always)
    func earliestTrip(pattern: Int, position: Int, departAtOrAfter time: Int32) -> Int32 {
        let off = net.boardOffset(pattern, position)
        var best = Int32.max
        best = min(best, earliest(pattern, days.0, shifts.0, time - off))
        best = min(best, earliest(pattern, days.1, shifts.1, time - off))
        best = min(best, earliest(pattern, days.2, shifts.2, time - off))
        return best
    }

    @inline(__always)
    private func earliest(_ pattern: Int, _ day: Int, _ shift: Int32, _ startAtLeast: Int32) -> Int32 {
        let slot = (pattern * 7 + day) * 2
        var lo = Int(net.tripRanges[slot]), hi = Int(net.tripRanges[slot + 1])
        guard lo < hi else { return .max }
        let target = startAtLeast - shift
        return net.tripStarts.withUnsafeBufferPointer { starts in
            if starts[hi - 1] < target { return .max }
            while lo < hi {
                let mid = (lo + hi) >> 1
                if starts[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            return starts[lo] + shift
        }
    }

    /// Latest trip start whose time at `position` is ≤ `time`, or `.min`.
    func latestTrip(pattern: Int, position: Int, arriveBy time: Int32) -> Int32 {
        let off = net.offset(pattern, position)
        var best = Int32.min
        for (day, shift) in [(days.0, shifts.0), (days.1, shifts.1), (days.2, shifts.2)] {
            let slot = (pattern * 7 + day) * 2
            var lo = Int(net.tripRanges[slot]), hi = Int(net.tripRanges[slot + 1])
            let target = time - off - shift
            // first index with start > target
            while lo < hi {
                let mid = (lo + hi) >> 1
                if net.tripStarts[mid] <= target { lo = mid + 1 } else { hi = mid }
            }
            if lo > Int(net.tripRanges[slot]) {
                best = max(best, net.tripStarts[lo - 1] + shift)
            }
        }
        return best
    }
}

/// The RAPTOR labels for one query.
struct RaptorSearch {
    let net: ExtendedNetwork
    let n: Int
    let rounds: Int
    let clock: ServiceDayClock
    let slack: Int32
    let walking: WalkingModel
    var egress: [(Int, Int32)] = []
    var targetBound = Int32.max
    /// Per pattern; empty means ride anything.
    var skipPattern: [Bool] = []

    // Flat (rounds + 1) × n.
    var tau: [Int32]
    var rideArr: [Int32]
    var ridePattern: [Int32]
    var rideStart: [Int32]
    var rideBoardPos: [Int16]
    var rideAlightPos: [Int16]
    var walkArr: [Int32]
    var walkFrom: [Int32]
    var best: [Int32]

    var marked: [Int32] = []
    var isMarked: [Bool]
    var queuePos: [Int32]
    var touched: [Int32] = []
    var footWalkSeconds: [Int32]

    init(net: ExtendedNetwork, rounds: Int, clock: ServiceDayClock, slack: Int32, walking: WalkingModel) {
        self.net = net
        n = net.stopCount
        self.rounds = max(1, rounds)
        self.clock = clock
        self.slack = slack
        self.walking = walking
        let size = (self.rounds + 1) * n
        tau = [Int32](repeating: .max, count: size)
        rideArr = [Int32](repeating: .max, count: size)
        ridePattern = [Int32](repeating: -1, count: size)
        rideStart = [Int32](repeating: 0, count: size)
        rideBoardPos = [Int16](repeating: 0, count: size)
        rideAlightPos = [Int16](repeating: 0, count: size)
        walkArr = [Int32](repeating: .max, count: size)
        walkFrom = [Int32](repeating: -1, count: size)
        best = [Int32](repeating: .max, count: n)
        isMarked = [Bool](repeating: false, count: n)
        queuePos = [Int32](repeating: .max, count: net.patternCount)
        // Footpath walking times, once per query (the walking model is a parameter).
        let speed = walking.metersPerSecond > 0 ? walking.circuityFactor / walking.metersPerSecond : 1e9
        footWalkSeconds = net.footMeters.map { ExtendedPlanner.seconds(Double($0) * speed) }
    }

    mutating func seed(stop: Int, at time: Int32) {
        if time < tau[stop] {
            tau[stop] = time
            best[stop] = min(best[stop], time)
            if !isMarked[stop] { isMarked[stop] = true; marked.append(Int32(stop)) }
        }
    }

    /// One RAPTOR round. Returns false when nothing was marked going in.
    mutating func runRound(_ k: Int) -> Bool {
        guard !marked.isEmpty else { return false }
        let base = k * n, prev = (k - 1) * n
        // τ_k starts as τ_{k-1}.
        for s in 0..<n { tau[base + s] = tau[prev + s] }

        // Queue patterns from the stops improved last round, at the earliest position.
        for s32 in marked {
            let s = Int(s32)
            isMarked[s] = false
            for e in Int(net.stopPatternStart[s])..<Int(net.stopPatternStart[s + 1]) {
                let p = Int(net.stopPatternIndex[e])
                let pos = net.stopPatternPosition[e]
                if queuePos[p] == .max { touched.append(Int32(p)) }
                if pos < queuePos[p] { queuePos[p] = pos }
            }
        }
        marked.removeAll(keepingCapacity: true)

        let boardSlack: Int32 = k > 1 ? slack : 0
        for p32 in touched {
            let p = Int(p32)
            let from = Int(queuePos[p])
            queuePos[p] = .max
            if !skipPattern.isEmpty, skipPattern[p] { continue }
            let lo = Int(net.patternStart[p]), hi = Int(net.patternStart[p + 1])
            var tripStart = Int32.max
            var boardPos = -1
            for i in from..<(hi - lo) {
                let s = Int(net.patternStops[lo + i])
                let off = net.patternOffsets[lo + i]
                let boardOff = net.patternBoardOffsets[lo + i]
                let flags = net.patternFlags[lo + i]
                if tripStart != .max, flags & 2 == 0 {
                    let arrival = tripStart + off
                    if arrival < best[s], arrival < targetBound {
                        let slot = base + s
                        tau[slot] = arrival
                        rideArr[slot] = arrival
                        ridePattern[slot] = Int32(p)
                        rideStart[slot] = tripStart
                        rideBoardPos[slot] = Int16(boardPos)
                        rideAlightPos[slot] = Int16(i)
                        best[s] = arrival
                        if !isMarked[s] { isMarked[s] = true; marked.append(Int32(s)) }
                    }
                }
                if flags & 1 == 0 {
                    let label = tau[prev + s]
                    if label != .max {
                        let ready = label + boardSlack
                        if tripStart == .max || ready < tripStart + boardOff {
                            let t = clock.earliestTrip(pattern: p, position: i, departAtOrAfter: ready)
                            if t < tripStart {
                                tripStart = t
                                boardPos = i
                            }
                        }
                    }
                }
            }
        }
        touched.removeAll(keepingCapacity: true)

        // Footpaths from stops reached by a ride this round.
        let rideMarked = marked
        for s32 in rideMarked {
            let s = Int(s32)
            let from = rideArr[base + s]
            guard from != .max else { continue }
            for e in Int(net.footStart[s])..<Int(net.footStart[s + 1]) {
                let t = Int(net.footStop[e])
                let arrival = from + footWalkSeconds[e]
                if arrival < best[t], arrival < targetBound {
                    tau[base + t] = arrival
                    walkArr[base + t] = arrival
                    walkFrom[base + t] = Int32(s)
                    best[t] = arrival
                    if !isMarked[t] { isMarked[t] = true; marked.append(Int32(t)) }
                }
            }
        }
        return true
    }

    /// Walk the labels back from `stop` at round `round` to an access stop.
    func reconstruct(stop: Int, round: Int) -> RaptorJourney? {
        var s = stop, k = round
        var mustRide = false
        var rides: [RaptorRide] = []
        var guardCount = 0
        while k > 0 {
            guardCount += 1
            if guardCount > 64 { return nil }
            let slot = k * n + s
            let label = tau[slot]
            if !mustRide, walkArr[slot] != .max, walkArr[slot] == label, walkFrom[slot] >= 0 {
                s = Int(walkFrom[slot])
                mustRide = true
                continue
            }
            if rideArr[slot] != .max, mustRide || rideArr[slot] == label, ridePattern[slot] >= 0 {
                let p = Int(ridePattern[slot])
                let ride = RaptorRide(pattern: p, start: rideStart[slot],
                                       boardPos: Int(rideBoardPos[slot]), alightPos: Int(rideAlightPos[slot]))
                rides.append(ride)
                s = net.stop(p, ride.boardPos)
                k -= 1
                mustRide = false
                continue
            }
            if mustRide { return nil }
            k -= 1
        }
        guard !rides.isEmpty, tau[s] != .max else { return nil }
        return RaptorJourney(accessStop: s, rides: rides.reversed(), egressStop: stop)
    }
}
