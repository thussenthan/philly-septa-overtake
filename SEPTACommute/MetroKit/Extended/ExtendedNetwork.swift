import Foundation

/// How a route runs, as SEPTA's `route_type` says.
///
/// `trolley` covers the subway-surface and suburban trolleys *and* the trackless
/// trolleys (59, 66, 75) — the same set the Metro planner covers.
public enum ExtendedMode: String, Sendable, Hashable, CaseIterable {
    case bus, trolley, metro, rail
}

/// One SEPTA route in the all-of-SEPTA timetable.
public struct ExtendedRoute: Sendable, Hashable {
    public var shortName: String
    public var longName: String
    public var mode: ExtendedMode
    /// Route colour as six hex digits, no `#`. May be empty.
    public var colorHex: String
}

public enum ExtendedNetworkError: Error, Sendable, CustomStringConvertible {
    case unrecognizedHeader
    case malformed(line: Int, reason: String)

    public var description: String {
        switch self {
        case .unrecognizedHeader: return "not a SEPTAExtended timetable"
        case let .malformed(line, reason): return "SEPTAExtended line \(line): \(reason)"
        }
    }
}

/// Every bus, trolley, Metro and Regional Rail trip SEPTA schedules, decoded from
/// the bundled `SEPTAExtended.txt` written by `tools/build_extended.py`.
///
/// Built once and immutable; it is safe to share between threads and tasks. The
/// decoder also builds the indexes the planner needs: which patterns serve each
/// stop, a spatial grid for nearest-stop lookups, and footpaths between stops
/// within ``footpathRadius`` metres.
public final class ExtendedNetwork: Sendable {
    /// Walking links are built between stops at most this far apart (straight line).
    public static let footpathRadius: Double = 250

    // MARK: Feed metadata

    public let busFeedVersion: String
    public let railFeedVersion: String
    /// First and last dates (yyyyMMdd) for which *both* feeds are authoritative.
    public let validFrom: String
    public let validUntil: String

    // MARK: Fares

    /// Bus / trolley / Metro pay-per-ride on SEPTA Key, USD.
    public let busFare: Double
    /// Free transfers on SEPTA Key are allowed within this many seconds of the paid boarding.
    public let transferWindowSeconds: Int
    public let freeTransfers: Int

    // MARK: Network

    public let routes: [ExtendedRoute]
    public let stopNames: [String]
    public let stopCoordinates: [Coordinate]

    // Regional Rail fare classes: per stop (-1 off the railway), and class × class
    // fare tables in cents.
    let stopFareClass: [Int16]
    let fareClassCount: Int
    let fareClassIsCenterCity: [Bool]
    let fareWeekdayCents: [Int32]
    let fareWeekendCents: [Int32]

    // Patterns: CSR over stops/offsets/flags.
    let patternRoute: [Int32]
    let patternHeadsign: [String]
    let patternDirection: [String]
    let patternStart: [Int32]          // count + 1
    let patternStops: [Int32]
    let patternOffsets: [Int32]        // cumulative seconds from trip start
    let patternFlags: [UInt8]          // bit 1 no pickup, bit 2 no drop-off
    // Trip starts: for pattern p and day type d (0 = Monday), starts[lo..<hi] with
    // lo = tripRanges[(p * 7 + d) * 2], hi = tripRanges[(p * 7 + d) * 2 + 1].
    let tripRanges: [Int32]
    let tripStarts: [Int32]

    // Which (pattern, position) pairs serve each stop.
    let stopPatternStart: [Int32]
    let stopPatternIndex: [Int32]
    let stopPatternPosition: [Int32]
    /// True for stops served by anything other than buses.
    let stopIsRapid: [Bool]

    // Footpaths: CSR, straight-line metres.
    let footStart: [Int32]
    let footStop: [Int32]
    let footMeters: [Float]

    // Spatial grid on a local equirectangular projection (metres).
    let stopX: [Double]
    let stopY: [Double]
    let gridOriginX: Double
    let gridOriginY: Double
    let gridColumns: Int
    let gridRows: Int
    let gridStart: [Int32]
    let gridStops: [Int32]
    static let gridCell: Double = 250

    public var stopCount: Int { stopNames.count }
    public var patternCount: Int { patternRoute.count }
    public var footpathCount: Int { footStop.count }
    /// Scheduled departures summed over the seven day types.
    public var weeklyTripCount: Int {
        var total = 0
        for p in 0..<patternCount {
            for d in 0..<7 {
                let i = (p * 7 + d) * 2
                total += Int(tripRanges[i + 1] - tripRanges[i])
            }
        }
        return total
    }

    // MARK: Projection

    static let refLongitude = -75.5
    static let refLatitude = 39.5
    static let metersPerDegreeLat = 110_574.0
    static let metersPerDegreeLon = 111_320.0 * cos(40.0 * Double.pi / 180)

    @inline(__always)
    static func project(_ c: Coordinate) -> (x: Double, y: Double) {
        ((c.longitude - refLongitude) * metersPerDegreeLon, (c.latitude - refLatitude) * metersPerDegreeLat)
    }

    // MARK: Lookups

    /// Stops within `meters` (straight line) of `coordinate`, nearest first.
    public func nearestStops(to coordinate: Coordinate, within meters: Double, limit: Int = .max) -> [(stop: Int, meters: Double)] {
        let (x, y) = Self.project(coordinate)
        var found: [(stop: Int, meters: Double)] = []
        forEachStop(nearX: x, y: y, within: meters) { s, d in found.append((s, d)) }
        found.sort { $0.meters < $1.meters }
        if found.count > limit { found.removeSubrange(limit...) }
        return found
    }

    func forEachStop(nearX x: Double, y: Double, within meters: Double, _ body: (Int, Double) -> Void) {
        let cell = Self.gridCell
        let c0 = max(0, Int(((x - meters - gridOriginX) / cell).rounded(.down)))
        let c1 = min(gridColumns - 1, Int(((x + meters - gridOriginX) / cell).rounded(.down)))
        let r0 = max(0, Int(((y - meters - gridOriginY) / cell).rounded(.down)))
        let r1 = min(gridRows - 1, Int(((y + meters - gridOriginY) / cell).rounded(.down)))
        guard c0 <= c1, r0 <= r1 else { return }
        let limit = meters * meters
        for r in r0...r1 {
            for c in c0...c1 {
                let cellIndex = r * gridColumns + c
                for k in Int(gridStart[cellIndex])..<Int(gridStart[cellIndex + 1]) {
                    let s = Int(gridStops[k])
                    let dx = stopX[s] - x, dy = stopY[s] - y
                    let d2 = dx * dx + dy * dy
                    if d2 <= limit { body(s, d2.squareRoot()) }
                }
            }
        }
    }

    /// Straight-line metres between a stop and a coordinate, on the planner's projection.
    func meters(fromStop s: Int, to coordinate: Coordinate) -> Double {
        let (x, y) = Self.project(coordinate)
        let dx = stopX[s] - x, dy = stopY[s] - y
        return (dx * dx + dy * dy).squareRoot()
    }

    func meters(fromStop a: Int, toStop b: Int) -> Double {
        let dx = stopX[a] - stopX[b], dy = stopY[a] - stopY[b]
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Regional Rail SEPTA Key fare between two rail stops, USD; nil when either is not a rail stop.
    public func railFare(fromStop a: Int, toStop b: Int, weekend: Bool) -> Double? {
        guard a >= 0, b >= 0, a < stopCount, b < stopCount else { return nil }
        let ca = Int(stopFareClass[a]), cb = Int(stopFareClass[b])
        guard ca >= 0, cb >= 0 else { return nil }
        let table = weekend ? fareWeekendCents : fareWeekdayCents
        return Double(table[ca * fareClassCount + cb]) / 100
    }

    /// True for a Regional Rail stop in the Center City fare zone.
    public func isCenterCityRailStop(_ s: Int) -> Bool {
        guard s >= 0, s < stopCount else { return false }
        let c = Int(stopFareClass[s])
        return c >= 0 && fareClassIsCenterCity[c]
    }

    // MARK: Decoding

    /// Decodes the contents of `SEPTAExtended.txt`.
    public static func decode(_ text: String) throws -> ExtendedNetwork {
        var text = text
        let parts = try text.withUTF8 { buffer -> Parts in
            var parser = ExtendedTextParser(buffer)
            return try parser.parse()
        }
        return ExtendedNetwork(parts)
    }

    /// Loads and decodes `SEPTAExtended.txt` from a bundle (the app's main bundle by default).
    public static func load(from bundle: Bundle = .main, resource: String = "SEPTAExtended") throws -> ExtendedNetwork? {
        guard let url = bundle.url(forResource: resource, withExtension: "txt") else { return nil }
        let data = try Data(contentsOf: url)
        return try decode(String(decoding: data, as: UTF8.self))
    }

    struct Parts {
        var busVersion = "", railVersion = "", validFrom = "", validUntil = ""
        var busFare = 2.9, window = 7200, free = 2
        var routes: [ExtendedRoute] = []
        var names: [String] = []
        var lats: [Double] = []
        var lons: [Double] = []
        var fareClass: [Int16] = []
        var classCC: [Bool] = []
        var weekday: [Int32] = []
        var weekend: [Int32] = []
        var patternRoute: [Int32] = []
        var headsign: [String] = []
        var direction: [String] = []
        var patternStart: [Int32] = [0]
        var stops: [Int32] = []
        var offsets: [Int32] = []
        var flags: [UInt8] = []
        var tripRanges: [Int32] = []
        var tripStarts: [Int32] = []
    }

    private init(_ p: Parts) {
        busFeedVersion = p.busVersion
        railFeedVersion = p.railVersion
        validFrom = p.validFrom
        validUntil = p.validUntil
        busFare = p.busFare
        transferWindowSeconds = p.window
        freeTransfers = p.free
        routes = p.routes
        stopNames = p.names
        let n = p.names.count
        var coords: [Coordinate] = []
        coords.reserveCapacity(n)
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let c = Coordinate(latitude: p.lats[i], longitude: p.lons[i])
            coords.append(c)
            (xs[i], ys[i]) = Self.project(c)
        }
        stopCoordinates = coords
        stopX = xs
        stopY = ys
        stopFareClass = p.fareClass
        fareClassCount = p.classCC.count
        fareClassIsCenterCity = p.classCC
        fareWeekdayCents = p.weekday
        fareWeekendCents = p.weekend
        patternRoute = p.patternRoute
        patternHeadsign = p.headsign
        patternDirection = p.direction
        patternStart = p.patternStart
        patternStops = p.stops
        patternOffsets = p.offsets
        patternFlags = p.flags
        tripRanges = p.tripRanges
        tripStarts = p.tripStarts

        // Stop → (pattern, position), and which stops see anything but buses.
        let patternTotal = p.patternRoute.count
        var counts = [Int32](repeating: 0, count: n + 1)
        for s in p.stops { counts[Int(s) + 1] += 1 }
        for i in 0..<n { counts[i + 1] += counts[i] }
        var fill = counts
        var spIndex = [Int32](repeating: 0, count: p.stops.count)
        var spPos = [Int32](repeating: 0, count: p.stops.count)
        var rapid = [Bool](repeating: false, count: n)
        for pi in 0..<patternTotal {
            let isRapid = p.routes[Int(p.patternRoute[pi])].mode != .bus
            let lo = Int(p.patternStart[pi]), hi = Int(p.patternStart[pi + 1])
            for k in lo..<hi {
                let s = Int(p.stops[k])
                let slot = Int(fill[s])
                spIndex[slot] = Int32(pi)
                spPos[slot] = Int32(k - lo)
                fill[s] += 1
                if isRapid { rapid[s] = true }
            }
        }
        stopPatternStart = counts
        stopPatternIndex = spIndex
        stopPatternPosition = spPos
        stopIsRapid = rapid

        // Grid.
        let cell = Self.gridCell
        let minX = (xs.min() ?? 0) - 1, minY = (ys.min() ?? 0) - 1
        let maxX = (xs.max() ?? 0) + 1, maxY = (ys.max() ?? 0) + 1
        let columns = max(1, Int(((maxX - minX) / cell).rounded(.up)))
        let rows = max(1, Int(((maxY - minY) / cell).rounded(.up)))
        var cellOf = [Int32](repeating: 0, count: n)
        var gridCounts = [Int32](repeating: 0, count: columns * rows + 1)
        for i in 0..<n {
            let c = min(columns - 1, Int((xs[i] - minX) / cell))
            let r = min(rows - 1, Int((ys[i] - minY) / cell))
            let index = r * columns + c
            cellOf[i] = Int32(index)
            gridCounts[index + 1] += 1
        }
        for i in 0..<(columns * rows) { gridCounts[i + 1] += gridCounts[i] }
        var gridFill = gridCounts
        var gridList = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let index = Int(cellOf[i])
            gridList[Int(gridFill[index])] = Int32(i)
            gridFill[index] += 1
        }
        gridOriginX = minX
        gridOriginY = minY
        gridColumns = columns
        gridRows = rows
        gridStart = gridCounts
        gridStops = gridList

        // Footpaths.
        var fStart = [Int32](repeating: 0, count: n + 1)
        var fStop: [Int32] = []
        var fMeters: [Float] = []
        fStop.reserveCapacity(n * 24)
        fMeters.reserveCapacity(n * 24)
        let radius = Self.footpathRadius
        let limit = radius * radius
        for i in 0..<n {
            let x = xs[i], y = ys[i]
            let c0 = max(0, Int((x - radius - minX) / cell)), c1 = min(columns - 1, Int((x + radius - minX) / cell))
            let r0 = max(0, Int((y - radius - minY) / cell)), r1 = min(rows - 1, Int((y + radius - minY) / cell))
            for r in r0...r1 {
                for c in c0...c1 {
                    let index = r * columns + c
                    for k in Int(gridCounts[index])..<Int(gridCounts[index + 1]) {
                        let j = Int(gridList[k])
                        if j == i { continue }
                        let dx = xs[j] - x, dy = ys[j] - y
                        let d2 = dx * dx + dy * dy
                        if d2 <= limit {
                            fStop.append(Int32(j))
                            fMeters.append(Float(d2.squareRoot()))
                        }
                    }
                }
            }
            fStart[i + 1] = Int32(fStop.count)
        }
        footStart = fStart
        footStop = fStop
        footMeters = fMeters
    }
}

// MARK: - ExtendedTextParser

private struct ExtendedTextParser {
    let b: UnsafeBufferPointer<UInt8>
    var line = 0
    var fields: [(Int, Int)] = []

    init(_ buffer: UnsafeBufferPointer<UInt8>) { b = buffer }

    static let tab = UInt8(ascii: "\t"), newline = UInt8(ascii: "\n"), comma = UInt8(ascii: ","),
               minus = UInt8(ascii: "-"), dot = UInt8(ascii: "."), zero = UInt8(ascii: "0"),
               colon = UInt8(ascii: ":"), cr = UInt8(ascii: "\r")

    func fail(_ reason: String) -> ExtendedNetworkError { .malformed(line: line, reason: reason) }

    func string(_ f: (Int, Int)) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: b[f.0..<f.1]), as: UTF8.self)
    }

    func int(_ f: (Int, Int)) throws -> Int {
        var i = f.0, sign = 1, value = 0
        if i < f.1, b[i] == Self.minus { sign = -1; i += 1 }
        guard i < f.1 else { throw fail("expected a number") }
        while i < f.1 {
            let d = Int(b[i]) - 48
            guard d >= 0, d <= 9 else { throw fail("expected a number") }
            value = value * 10 + d
            i += 1
        }
        return sign * value
    }

    func double(_ f: (Int, Int)) throws -> Double {
        var i = f.0, sign = 1.0, whole = 0.0, frac = 0.0, scale = 1.0, seenDot = false
        if i < f.1, b[i] == Self.minus { sign = -1; i += 1 }
        guard i < f.1 else { throw fail("expected a decimal") }
        while i < f.1 {
            let c = b[i]
            if c == Self.dot { seenDot = true } else {
                let d = Double(Int(c) - 48)
                guard d >= 0, d <= 9 else { throw fail("expected a decimal") }
                if seenDot { scale *= 10; frac = frac * 10 + d } else { whole = whole * 10 + d }
            }
            i += 1
        }
        return sign * (whole + frac / scale)
    }

    /// Comma-separated integers; with `delta`, each after the first adds to the previous.
    func list(_ f: (Int, Int), delta: Bool, _ body: (Int) -> Void) throws {
        var i = f.0
        guard i < f.1 else { return }
        var previous = 0, first = true
        while i <= f.1 {
            var sign = 1, value = 0, digits = 0
            if i < f.1, b[i] == Self.minus { sign = -1; i += 1 }
            while i < f.1, b[i] != Self.comma {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { throw fail("expected a list of numbers") }
                value = value * 10 + d
                digits += 1
                i += 1
            }
            guard digits > 0 else { throw fail("empty list element") }
            var v = sign * value
            if delta, !first { v += previous }
            body(v)
            previous = v
            first = false
            i += 1
        }
    }

    mutating func parse() throws -> ExtendedNetwork.Parts {
        var parts = ExtendedNetwork.Parts()
        var i = 0
        let end = b.count
        var currentPattern = -1
        var sawHeader = false
        while i < end {
            var lineEnd = i
            while lineEnd < end, b[lineEnd] != Self.newline { lineEnd += 1 }
            line += 1
            var contentEnd = lineEnd
            if contentEnd > i, b[contentEnd - 1] == Self.cr { contentEnd -= 1 }
            fields.removeAll(keepingCapacity: true)
            var fieldStart = i
            var k = i
            while k < contentEnd {
                if b[k] == Self.tab {
                    fields.append((fieldStart, k))
                    fieldStart = k + 1
                }
                k += 1
            }
            fields.append((fieldStart, contentEnd))
            let lineStart = i
            i = lineEnd + 1
            if contentEnd == lineStart { continue }

            let tagRange = fields[0]
            let tag = tagRange.1 - tagRange.0 == 1 ? b[tagRange.0] : 0
            if !sawHeader {
                guard string(tagRange) == "SEPTAEXT", fields.count >= 2, try int(fields[1]) == 1 else {
                    throw ExtendedNetworkError.unrecognizedHeader
                }
                sawHeader = true
                continue
            }
            switch tag {
            case UInt8(ascii: "S"):
                guard fields.count >= 4 else { throw fail("stop needs 4 fields") }
                parts.names.append(string(fields[1]))
                parts.lats.append(try double(fields[2]))
                parts.lons.append(try double(fields[3]))
                parts.fareClass.append(fields.count >= 5 ? Int16(try int(fields[4])) : -1)
            case UInt8(ascii: "T"):
                guard currentPattern >= 0, fields.count >= 3 else { throw fail("trips without a pattern") }
                let lo = Int32(parts.tripStarts.count)
                try list(fields[2], delta: true) { parts.tripStarts.append(Int32($0)) }
                let hi = Int32(parts.tripStarts.count)
                for d in fields[1].0..<fields[1].1 {
                    let day = Int(b[d]) - 49
                    guard day >= 0, day < 7 else { throw fail("bad day digit") }
                    let slot = (currentPattern * 7 + day) * 2
                    parts.tripRanges[slot] = lo
                    parts.tripRanges[slot + 1] = hi
                }
            case UInt8(ascii: "P"):
                guard fields.count >= 6 else { throw fail("pattern needs 6 fields") }
                let route = try int(fields[1])
                guard route >= 0, route < parts.routes.count else { throw fail("unknown route") }
                parts.patternRoute.append(Int32(route))
                parts.headsign.append(string(fields[2]))
                parts.direction.append(string(fields[3]))
                let first = parts.stops.count
                let stopCount = parts.names.count
                var badStop = false
                try list(fields[4], delta: true) { v in
                    if v < 0 || v >= stopCount { badStop = true }
                    parts.stops.append(Int32(v))
                }
                if badStop { throw fail("stop index out of range") }
                try list(fields[5], delta: true) { parts.offsets.append(Int32($0)) }
                let count = parts.stops.count - first
                guard parts.offsets.count == parts.stops.count, count >= 2 else { throw fail("stops and offsets differ") }
                parts.flags.append(contentsOf: repeatElement(0, count: count))
                if fields.count >= 7, fields[6].1 > fields[6].0 {
                    // "pos:bits,pos:bits"
                    var a = fields[6].0
                    let z = fields[6].1
                    while a < z {
                        var c = a
                        while c < z, b[c] != Self.colon { c += 1 }
                        let pos = try int((a, c))
                        var e = c + 1
                        while e < z, b[e] != Self.comma { e += 1 }
                        let bits = try int((c + 1, e))
                        guard pos >= 0, pos < count else { throw fail("flag position out of range") }
                        parts.flags[first + pos] = UInt8(bits)
                        a = e + 1
                    }
                }
                parts.patternStart.append(Int32(parts.stops.count))
                parts.tripRanges.append(contentsOf: repeatElement(0, count: 14))
                currentPattern += 1
            case UInt8(ascii: "R"):
                guard fields.count >= 4 else { throw fail("route needs 4 fields") }
                let mode = ExtendedMode(rawValue: string(fields[3])) ?? .bus
                parts.routes.append(ExtendedRoute(
                    shortName: string(fields[1]), longName: string(fields[2]), mode: mode,
                    colorHex: fields.count >= 5 ? string(fields[4]) : ""))
            case UInt8(ascii: "C"):
                guard fields.count >= 3 else { throw fail("fare class needs 3 fields") }
                parts.classCC.append(try int(fields[2]) == 1)
            case UInt8(ascii: "X"):
                guard fields.count >= 3 else { throw fail("fare row needs 3 fields") }
                try list(fields[1], delta: false) { parts.weekday.append(Int32($0)) }
                try list(fields[2], delta: false) { parts.weekend.append(Int32($0)) }
            case UInt8(ascii: "M"):
                guard fields.count >= 5 else { throw fail("metadata needs 5 fields") }
                parts.busVersion = string(fields[1])
                parts.railVersion = string(fields[2])
                parts.validFrom = string(fields[3])
                parts.validUntil = string(fields[4])
            case UInt8(ascii: "B"):
                guard fields.count >= 4 else { throw fail("bus fare needs 4 fields") }
                parts.busFare = try double(fields[1])
                parts.window = try int(fields[2])
                parts.free = try int(fields[3])
            default:
                continue  // unknown record types are skipped, for forward compatibility
            }
        }
        guard sawHeader else { throw ExtendedNetworkError.unrecognizedHeader }
        let classes = parts.classCC.count
        guard parts.weekday.count == classes * classes, parts.weekend.count == classes * classes else {
            throw ExtendedNetworkError.malformed(line: line, reason: "fare table is not square")
        }
        for c in parts.fareClass where Int(c) >= classes {
            throw ExtendedNetworkError.malformed(line: line, reason: "fare class out of range")
        }
        return parts
    }
}
