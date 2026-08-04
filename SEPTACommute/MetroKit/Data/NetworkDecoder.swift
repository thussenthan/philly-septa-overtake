import Foundation

/// Decodes the bundled network from a compact line-oriented text form.
///
/// The data used to be emitted as Swift literals — arrays of `ServicePattern`
/// containing arrays of `PatternStop` containing arrays of departure times. That
/// is pleasant to read and fine at 900 lines, but at 22,000 lines Swift's type
/// checker needs more memory than a laptop has: inference over deeply nested
/// heterogeneous literals blows up, and `swift test` dies before it runs anything.
///
/// String literals cost the type checker nothing, so the data ships as text and is
/// parsed once, lazily, on first use. Parsing the whole Metro map is a few
/// milliseconds of string splitting.
///
/// The format is one record per line, fields separated by `|`:
///
///     M|feedVersion|feedStart|feedEnd|generated|source
///     L|id|badge|name|colorHex
///     S|id|name|subtitle|intersection|lat|lon|lineIDs,csv|1 (accessible), 0, or -
///     P|id|lineID|routeID|kind|direction|headsign
///     O|station:arrivalOffset:dwell,station:arrivalOffset:dwell,...
///     D|day,day|blocks
///
/// `O` and `D` records attach to the most recent `P`. Blocks in a `D` record are
/// separated by `;`, and are either `f:from:until:every` or `t:time,time,time`.
public enum NetworkDecoder {

    public struct DecodeError: Error, CustomStringConvertible {
        public var line: Int
        public var reason: String
        public var description: String { "network data line \(line): \(reason)" }
    }

    /// Parses the joined chunks into a `Network`.
    ///
    /// Traps on malformed data rather than returning an optional: the input is
    /// generated and committed alongside this code, so a failure is a build-time
    /// bug, and a silently empty network would surface as "no trains ever" at
    /// arbitrary distance from the cause.
    public static func decode(_ chunks: [String]) -> Network {
        do {
            return try parse(chunks)
        } catch {
            preconditionFailure("bundled network data is malformed: \(error)")
        }
    }

    static func parse(_ chunks: [String]) throws -> Network {
        var lines: [Line] = []
        var stations: [Station] = []
        var patterns: [ServicePattern] = []

        var provenance = DataProvenance(fidelity: .official, source: "unknown", generated: "unknown")

        // The pattern currently being assembled from its P/O/D records.
        var pendingHeader: (id: String, line: String, route: String, kind: String, direction: String, headsign: String)?
        var pendingStops: [PatternStop] = []
        var pendingBlocks: [DayType: [ScheduleBlock]] = [:]

        func flushPattern() throws {
            guard let header = pendingHeader else { return }
            guard !pendingStops.isEmpty else {
                throw DecodeError(line: 0, reason: "pattern \(header.id) has no stops")
            }
            guard let kind = PatternKind(rawValue: header.kind) else {
                throw DecodeError(line: 0, reason: "unknown pattern kind \(header.kind)")
            }
            guard let direction = Direction(rawValue: header.direction) else {
                throw DecodeError(line: 0, reason: "unknown direction \(header.direction)")
            }
            patterns.append(ServicePattern(
                id: PatternID(header.id),
                lineID: LineID(header.line),
                routeID: RouteID(header.route),
                kind: kind,
                direction: direction,
                headsign: header.headsign,
                stops: pendingStops,
                schedule: Schedule(blocks: pendingBlocks)
            ))
            pendingHeader = nil
            pendingStops = []
            pendingBlocks = [:]
        }

        var lineNumber = 0
        for chunk in chunks {
            for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                lineNumber += 1
                let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let tag = fields.first, !tag.isEmpty else { continue }

                switch tag {
                case "M":
                    guard fields.count >= 6 else { throw DecodeError(line: lineNumber, reason: "short M record") }
                    provenance = DataProvenance(
                        fidelity: .official,
                        source: fields[5],
                        generated: fields[4],
                        validUntil: fields[3],
                        notes: "Regenerate with tools/build_schedule.py"
                    )

                case "L":
                    guard fields.count >= 5 else { throw DecodeError(line: lineNumber, reason: "short L record") }
                    lines.append(Line(
                        id: LineID(fields[1]),
                        badge: fields[2],
                        name: fields[3],
                        colorHex: fields[4]
                    ))

                case "S":
                    guard fields.count >= 9 else { throw DecodeError(line: lineNumber, reason: "short S record") }
                    guard let latitude = Double(fields[5]), let longitude = Double(fields[6]) else {
                        throw DecodeError(line: lineNumber, reason: "bad coordinate for \(fields[1])")
                    }
                    let accessible: Bool?
                    switch fields[8] {
                    case "1": accessible = true
                    case "0": accessible = false
                    default: accessible = nil
                    }
                    stations.append(Station(
                        id: StationID(fields[1]),
                        name: fields[2],
                        subtitle: fields[3].isEmpty ? nil : fields[3],
                        intersection: fields[4].isEmpty ? nil : fields[4],
                        coordinate: Coordinate(latitude: latitude, longitude: longitude),
                        lines: fields[7].isEmpty ? [] : fields[7].split(separator: ",").map { LineID(String($0)) },
                        isAccessible: accessible
                    ))

                case "P":
                    try flushPattern()
                    guard fields.count >= 7 else { throw DecodeError(line: lineNumber, reason: "short P record") }
                    pendingHeader = (fields[1], fields[2], fields[3], fields[4], fields[5], fields[6])

                case "O":
                    guard fields.count >= 2 else { throw DecodeError(line: lineNumber, reason: "short O record") }
                    for entry in fields[1].split(separator: ",") {
                        let parts = entry.split(separator: ":")
                        guard parts.count >= 2, let arrival = Double(parts[1]) else {
                            throw DecodeError(line: lineNumber, reason: "bad stop \(entry)")
                        }
                        let dwell = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
                        pendingStops.append(PatternStop(
                            station: StationID(String(parts[0])),
                            offset: arrival,
                            dwell: dwell
                        ))
                    }

                case "D":
                    guard fields.count >= 3 else { throw DecodeError(line: lineNumber, reason: "short D record") }
                    var blocks: [ScheduleBlock] = []
                    for spec in fields[2].split(separator: ";") {
                        let parts = spec.split(separator: ":")
                        guard let kind = parts.first else { continue }
                        if kind == "f" {
                            guard parts.count >= 4,
                                  let from = Int(parts[1]), let until = Int(parts[2]), let every = Int(parts[3])
                            else { throw DecodeError(line: lineNumber, reason: "bad frequency \(spec)") }
                            blocks.append(.frequency(from: from, until: until, every: every))
                        } else if kind == "t" {
                            guard parts.count >= 2 else { throw DecodeError(line: lineNumber, reason: "bad departures \(spec)") }
                            let times = parts[1].split(separator: ",").compactMap { Int($0) }
                            guard !times.isEmpty else { throw DecodeError(line: lineNumber, reason: "empty departures") }
                            blocks.append(.departures(times))
                        } else {
                            throw DecodeError(line: lineNumber, reason: "unknown block \(spec)")
                        }
                    }
                    for name in fields[1].split(separator: ",") {
                        guard let day = DayType(rawValue: String(name)) else {
                            throw DecodeError(line: lineNumber, reason: "unknown day \(name)")
                        }
                        pendingBlocks[day, default: []].append(contentsOf: blocks)
                    }

                default:
                    throw DecodeError(line: lineNumber, reason: "unknown record type \(tag)")
                }
            }
        }
        try flushPattern()

        return Network(lines: lines, stations: stations, patterns: patterns, provenance: provenance)
    }
}
