import Foundation
@testable import MetroKit

/// A tiny synthetic line, so planner behaviour can be asserted against times
/// chosen by hand rather than whatever SEPTA happens to be running this month.
///
/// Six stations, 400 m apart along a north-south street:
///
///     a — b — c — d — e — f        (southbound)
///
/// * `local` stops at all six, 2 min between stations, every 10 min from 08:00.
/// * `express` stops at a, c, f only, 2 min between its stops, every 20 min from
///   08:04 — it leaves A after the 08:00 local and still reaches F two minutes
///   earlier, which is exactly the tradeoff the app exists to resolve.
enum Fixture {
    static let lineID: LineID = "T"

    static let stations: [Station] = {
        let names = ["a", "b", "c", "d", "e", "f"]
        return names.enumerated().map { index, name in
            Station(
                id: StationID(name),
                name: name.uppercased(),
                intersection: "\(name.uppercased()) St",
                // ~0.0036° of latitude is ~400 m.
                coordinate: Coordinate(latitude: 40.0 - Double(index) * 0.0036, longitude: -75.16),
                lines: [lineID],
                // C has no elevator, so step-free routing must avoid changing there
                // — which is exactly where the overtake happens.
                isAccessible: name != "c"
            )
        }
    }()

    /// Seconds after midnight for a `HH:MM` string on the fixture's service day.
    static func sam(_ hour: Int, _ minute: Int) -> Int { hour * 3600 + minute * 60 }

    // Distinct route IDs matter twice over: the planner only considers changing
    // trains at stations served by more than one route, so a fixture sharing one
    // route would never produce a transfer — and the route ID is what the card
    // shows on its badge, the way SEPTA's own map writes B1 and B2.
    static let localSouth = ServicePattern(
        id: "T-local-south",
        lineID: lineID,
        routeID: "T1",
        kind: .local,
        direction: .southbound,
        headsign: "F",
        stops: (0..<6).map { PatternStop(station: stations[$0].id, offset: TimeInterval($0 * 120)) },
        schedule: Schedule(everyDay: [.frequency(from: sam(8, 0), until: sam(11, 0), every: 600)])
    )

    static let expressSouth = ServicePattern(
        id: "T-express-south",
        lineID: lineID,
        routeID: "T2",
        kind: .express,
        direction: .southbound,
        headsign: "F express",
        stops: [
            PatternStop(station: "a", offset: 0),
            PatternStop(station: "c", offset: 120),
            PatternStop(station: "f", offset: 240),
        ],
        // Weekdays only, mirroring SEPTA's express, so weekend behaviour is testable.
        schedule: Schedule([
            (DayType.weekdays, [.frequency(from: sam(8, 4), until: sam(10, 4), every: 1200)]),
        ])
    )

    static let localNorth = ServicePattern(
        id: "T-local-north",
        lineID: lineID,
        routeID: "T1",
        kind: .local,
        direction: .northbound,
        headsign: "A",
        stops: (0..<6).map { index in
            PatternStop(station: stations[5 - index].id, offset: TimeInterval(index * 120))
        },
        schedule: Schedule(everyDay: [.frequency(from: sam(8, 0), until: sam(11, 0), every: 600)])
    )

    static let provenance = DataProvenance(
        fidelity: .official,
        source: "fixture",
        generated: "2026-01-01",
        validUntil: "20991231"
    )

    static let network = Network(
        lines: [Line(id: lineID, badge: "T", name: "Test Line", colorHex: "000000")],
        stations: stations,
        patterns: [localSouth, expressSouth, localNorth],
        provenance: provenance
    )

    static let calendar = ServiceCalendar(usesHolidaySchedule: false)

    static func planner(_ configure: (inout PlannerOptions) -> Void = { _ in }) -> JourneyPlanner {
        var options = PlannerOptions()
        // Remove geometric fuzz from the fixtures so assertions are about routing.
        options.walking.startupSeconds = 0
        options.walking.stationEntrySeconds = 0
        options.walking.stationExitSeconds = 0
        options.boardingBufferSeconds = 0
        options.minTransferSeconds = 60
        configure(&options)
        return JourneyPlanner(network: network, calendar: calendar, options: options)
    }

    /// A Wednesday, so the weekday timetable applies.
    static func date(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 4
        components.hour = hour
        components.minute = minute
        components.second = second
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = ServiceCalendar.easternTimeZone
        return gregorian.date(from: components)!
    }

    static func coordinate(of station: StationID, offsetMeters: Double = 0) -> Coordinate {
        let base = stations.first { $0.id == station }!.coordinate
        // Shift east so the offset is a pure walking distance.
        let degrees = offsetMeters / (111_320 * cos(base.latitude * .pi / 180))
        return Coordinate(latitude: base.latitude, longitude: base.longitude + degrees)
    }
}

extension Journey {
    /// Compact description used in test failure messages: "local a→c / express c→f".
    var trace: String {
        rides.map { "\($0.kind.rawValue) \($0.boardStation)→\($0.alightStation)" }
            .joined(separator: " / ")
    }
}
