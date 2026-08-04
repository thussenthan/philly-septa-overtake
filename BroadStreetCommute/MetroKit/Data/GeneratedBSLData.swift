// swiftlint:disable all
// -----------------------------------------------------------------------------
// GENERATED FILE — do not edit by hand.
//
// Produced by tools/build_schedule.py from SEPTA's official GTFS feed:
//   https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip
//   feed_version v202607261  valid 20260726–20260808
//
// Timetables are sampled from one ordinary date per day type so that
// single-date extras (special-event trips) do not leak into the schedule:
//   saturday: 2026-08-01
//   sunday: 2026-07-26
//   weekday: 2026-07-28
//
// Re-run `python3 tools/build_schedule.py` when SEPTA publishes a new feed.
// -----------------------------------------------------------------------------

import Foundation

public enum BSLData {

    /// GTFS `feed_version` this file was generated from.
    public static let feedVersion = "v202607261"
    /// Last date SEPTA declares this timetable valid, `yyyyMMdd`.
    public static let feedEndDate = "20260808"
    public static let feedStartDate = "20260726"

    public static let provenance = DataProvenance(
        fidelity: .official,
        source: "SEPTA GTFS v202607261",
        generated: "2026-08-04",
        validUntil: "20260808",
        notes: "Sampled from SEPTA GTFS; regenerate with tools/build_schedule.py"
    )

    public static let lines: [Line] = [
        Line(id: "B", badge: "B", name: "Broad Street Line", colorHex: "F26100"),
        Line(id: "B-OWL", badge: "B", name: "Broad Street Owl Bus", colorHex: "F26100"),
    ]

    public static let stations: [Station] = [
        Station(
            id: "8th-and-market",
            name: "8th & Market",
            subtitle: nil,
            intersection: "8th St & Market St",
            coordinate: Coordinate(latitude: 39.951138, longitude: -75.153589),
            lines: ["B"],
            isAccessible: true
        ),
        Station(
            id: "allegheny",
            name: "Allegheny",
            subtitle: nil,
            intersection: "Broad St & Allegheny Ave",
            coordinate: Coordinate(latitude: 40.001589, longitude: -75.152875),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "cecil-b-moore",
            name: "Cecil B. Moore",
            subtitle: "Temple University",
            intersection: "Broad St & Cecil B. Moore Ave",
            coordinate: Coordinate(latitude: 39.978668, longitude: -75.157883),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "chinatown",
            name: "Chinatown",
            subtitle: nil,
            intersection: "8th St & Vine St",
            coordinate: Coordinate(latitude: 39.955027, longitude: -75.152748),
            lines: ["B"],
            isAccessible: false
        ),
        Station(
            id: "city-hall",
            name: "City Hall",
            subtitle: "15th St",
            intersection: "Broad St & Market St",
            coordinate: Coordinate(latitude: 39.952468, longitude: -75.164093),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "ellsworth-federal",
            name: "Ellsworth-Federal",
            subtitle: nil,
            intersection: "Broad St & Federal St",
            coordinate: Coordinate(latitude: 39.936177, longitude: -75.167129),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "erie",
            name: "Erie",
            subtitle: nil,
            intersection: "Broad St & Erie Ave",
            coordinate: Coordinate(latitude: 40.009234, longitude: -75.151203),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "fairmount",
            name: "Fairmount",
            subtitle: nil,
            intersection: "Broad St & Fairmount Ave",
            coordinate: Coordinate(latitude: 39.967034, longitude: -75.16042),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "fern-rock",
            name: "Fern Rock",
            subtitle: "Transit Center",
            intersection: "10th St & Nedro Ave",
            coordinate: Coordinate(latitude: 40.04185, longitude: -75.136757),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "girard",
            name: "Girard",
            subtitle: nil,
            intersection: "Broad St & Girard Ave",
            coordinate: Coordinate(latitude: 39.971469, longitude: -75.15944),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "hunting-park",
            name: "Hunting Park",
            subtitle: nil,
            intersection: "Broad St & Hunting Park Ave",
            coordinate: Coordinate(latitude: 40.016933, longitude: -75.149529),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "logan",
            name: "Logan",
            subtitle: nil,
            intersection: "Broad St & Rockland St",
            coordinate: Coordinate(latitude: 40.030617, longitude: -75.146533),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "lombard-south",
            name: "Lombard-South",
            subtitle: nil,
            intersection: "Broad St & South St",
            coordinate: Coordinate(latitude: 39.944073, longitude: -75.165424),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "north-philadelphia",
            name: "North Philadelphia",
            subtitle: nil,
            intersection: "Broad St & Glenwood Ave",
            coordinate: Coordinate(latitude: 39.993939, longitude: -75.154588),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "nrg",
            name: "NRG",
            subtitle: "Sports Complex",
            intersection: "Broad St & Pattison Ave",
            coordinate: Coordinate(latitude: 39.905428, longitude: -75.173857),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "olney",
            name: "Olney",
            subtitle: "Transit Center",
            intersection: "Broad St & Olney Ave",
            coordinate: Coordinate(latitude: 40.039055, longitude: -75.144723),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "oregon",
            name: "Oregon",
            subtitle: nil,
            intersection: "Broad St & Oregon Ave",
            coordinate: Coordinate(latitude: 39.916785, longitude: -75.171373),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "race-vine",
            name: "Race-Vine",
            subtitle: nil,
            intersection: "Broad St & Race St",
            coordinate: Coordinate(latitude: 39.957026, longitude: -75.162595),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "snyder",
            name: "Snyder",
            subtitle: nil,
            intersection: "Broad St & Snyder Ave",
            coordinate: Coordinate(latitude: 39.924375, longitude: -75.169705),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
        Station(
            id: "spring-garden",
            name: "Spring Garden",
            subtitle: nil,
            intersection: "Broad St & Spring Garden St",
            coordinate: Coordinate(latitude: 39.962383, longitude: -75.161429),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "susquehanna-dauphin",
            name: "Susquehanna-Dauphin",
            subtitle: nil,
            intersection: "Broad St & Susquehanna Ave",
            coordinate: Coordinate(latitude: 39.987026, longitude: -75.156068),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "tasker-morris",
            name: "Tasker-Morris",
            subtitle: nil,
            intersection: "Broad St & Morris St",
            coordinate: Coordinate(latitude: 39.929809, longitude: -75.168522),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "walnut-locust",
            name: "Walnut-Locust",
            subtitle: nil,
            intersection: "Broad St & Locust St",
            coordinate: Coordinate(latitude: 39.948734, longitude: -75.164415),
            lines: ["B", "B-OWL"],
            isAccessible: true
        ),
        Station(
            id: "wyoming",
            name: "Wyoming",
            subtitle: nil,
            intersection: "Broad St & Wyoming Ave",
            coordinate: Coordinate(latitude: 40.02456, longitude: -75.147856),
            lines: ["B", "B-OWL"],
            isAccessible: false
        ),
    ]

    public static let patterns: [ServicePattern] = [
        // B1 southbound: Fern Rock → NRG, 22 stops, 40.25 min, 349 trips
        ServicePattern(
            id: "B1-southbound-fern-rock-nrg-22",
            lineID: "B",
            kind: .local,
            direction: .southbound,
            headsign: "NRG",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 225),
                PatternStop(station: "logan", offset: 360),
                PatternStop(station: "wyoming", offset: 435),
                PatternStop(station: "hunting-park", offset: 525),
                PatternStop(station: "erie", offset: 675),
                PatternStop(station: "allegheny", offset: 765),
                PatternStop(station: "north-philadelphia", offset: 870),
                PatternStop(station: "susquehanna-dauphin", offset: 975),
                PatternStop(station: "cecil-b-moore", offset: 1065),
                PatternStop(station: "girard", offset: 1170),
                PatternStop(station: "fairmount", offset: 1275),
                PatternStop(station: "spring-garden", offset: 1350),
                PatternStop(station: "race-vine", offset: 1440),
                PatternStop(station: "city-hall", offset: 1560),
                PatternStop(station: "walnut-locust", offset: 1665),
                PatternStop(station: "lombard-south", offset: 1800),
                PatternStop(station: "ellsworth-federal", offset: 1890),
                PatternStop(station: "tasker-morris", offset: 1980),
                PatternStop(station: "snyder", offset: 2100),
                PatternStop(station: "oregon", offset: 2190),
                PatternStop(station: "nrg", offset: 2415),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([17760, 18780, 19710, 20640, 21240, 21840, 22350, 22860]), .frequency(from: 23400, until: 64980, every: 420), .departures([65640, 66240]), .frequency(from: 66900, until: 69900, every: 600), .departures([70530, 71130, 71730, 72390]), .frequency(from: 73080, until: 81720, every: 720), .departures([82560, 83280, 84000, 84660, 85500, 86640])],
                .saturday: [.departures([18000, 18900, 19800, 20700, 21600, 22440, 23280, 24000, 24720, 25380, 26040]), .frequency(from: 26700, until: 71700, every: 600), .frequency(from: 72360, until: 81720, every: 720), .departures([82560, 83280, 84000, 84660, 85500, 86640])],
                .sunday: [.departures([18300, 19500, 20460, 21420, 22380, 23280]), .frequency(from: 24180, until: 32820, every: 720), .frequency(from: 33420, until: 68820, every: 600), .frequency(from: 69480, until: 81720, every: 720), .departures([82560, 83280, 84000, 84660, 85500, 86640])],
            ])
        ),
        // B1 southbound: Fern Rock → NRG, 9 stops, 34.25 min, 3 trips
        ServicePattern(
            id: "B1-southbound-fern-rock-nrg-9",
            lineID: "B",
            kind: .local,
            direction: .southbound,
            headsign: "NRG",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "city-hall", offset: 1200),
                PatternStop(station: "walnut-locust", offset: 1305),
                PatternStop(station: "lombard-south", offset: 1440),
                PatternStop(station: "ellsworth-federal", offset: 1530),
                PatternStop(station: "tasker-morris", offset: 1620),
                PatternStop(station: "snyder", offset: 1740),
                PatternStop(station: "oregon", offset: 1830),
                PatternStop(station: "nrg", offset: 2055),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([16800])],
                .saturday: [.departures([16800])],
                .sunday: [.departures([16800])],
            ])
        ),
        // B1 northbound: NRG → Fern Rock, 22 stops, 37.75 min, 346 trips
        ServicePattern(
            id: "B1-northbound-nrg-fern-rock-22",
            lineID: "B",
            kind: .local,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 135),
                PatternStop(station: "snyder", offset: 240),
                PatternStop(station: "tasker-morris", offset: 330),
                PatternStop(station: "ellsworth-federal", offset: 420),
                PatternStop(station: "lombard-south", offset: 525),
                PatternStop(station: "walnut-locust", offset: 615),
                PatternStop(station: "city-hall", offset: 705),
                PatternStop(station: "race-vine", offset: 825),
                PatternStop(station: "spring-garden", offset: 915),
                PatternStop(station: "fairmount", offset: 1005),
                PatternStop(station: "girard", offset: 1095),
                PatternStop(station: "cecil-b-moore", offset: 1215),
                PatternStop(station: "susquehanna-dauphin", offset: 1320),
                PatternStop(station: "north-philadelphia", offset: 1410),
                PatternStop(station: "allegheny", offset: 1500),
                PatternStop(station: "erie", offset: 1605),
                PatternStop(station: "hunting-park", offset: 1725),
                PatternStop(station: "wyoming", offset: 1800),
                PatternStop(station: "logan", offset: 1875),
                PatternStop(station: "olney", offset: 1980),
                PatternStop(station: "fern-rock", offset: 2265),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([18435, 19455, 20475, 21375, 22305, 23205, 23955, 24375, 24915, 25455]), .frequency(from: 25995, until: 66735, every: 420), .departures([67185]), .frequency(from: 67665, until: 72465, every: 600), .departures([73125, 73785]), .frequency(from: 74445, until: 83085, every: 720), .departures([83925, 84645, 85365, 86085, 86805])],
                .saturday: [.departures([18705, 19725, 20745, 21645, 22545, 23445, 24345, 25125, 25905, 26625, 27345, 28065, 28785]), .frequency(from: 29445, until: 74445, every: 600), .frequency(from: 75165, until: 83085, every: 720), .departures([83925, 84645, 85365, 86085, 86805])],
                .sunday: [.departures([18900, 19980, 21060, 22140, 23145, 24105, 25065, 25965, 26865]), .frequency(from: 27705, until: 34185, every: 720), .frequency(from: 34785, until: 70185, every: 600), .frequency(from: 70845, until: 83085, every: 720), .departures([83925, 84645, 85365, 86085, 86805])],
            ])
        ),
        // B1 northbound: NRG → Fern Rock, 16 stops, 35.00 min, 3 trips
        ServicePattern(
            id: "B1-northbound-nrg-fern-rock-16",
            lineID: "B",
            kind: .local,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "city-hall", offset: 540),
                PatternStop(station: "race-vine", offset: 660),
                PatternStop(station: "spring-garden", offset: 750),
                PatternStop(station: "fairmount", offset: 840),
                PatternStop(station: "girard", offset: 930),
                PatternStop(station: "cecil-b-moore", offset: 1050),
                PatternStop(station: "susquehanna-dauphin", offset: 1155),
                PatternStop(station: "north-philadelphia", offset: 1245),
                PatternStop(station: "allegheny", offset: 1335),
                PatternStop(station: "erie", offset: 1440),
                PatternStop(station: "hunting-park", offset: 1560),
                PatternStop(station: "wyoming", offset: 1635),
                PatternStop(station: "logan", offset: 1710),
                PatternStop(station: "olney", offset: 1815),
                PatternStop(station: "fern-rock", offset: 2100),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([17460])],
                .saturday: [.departures([17460])],
                .sunday: [.departures([17460])],
            ])
        ),
        // B1 northbound: NRG → Fern Rock, 22 stops, 41.25 min, 3 trips
        ServicePattern(
            id: "B1-northbound-nrg-fern-rock-22-v2",
            lineID: "B",
            kind: .local,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 135),
                PatternStop(station: "snyder", offset: 240),
                PatternStop(station: "tasker-morris", offset: 330),
                PatternStop(station: "ellsworth-federal", offset: 420),
                PatternStop(station: "lombard-south", offset: 525),
                PatternStop(station: "walnut-locust", offset: 615),
                PatternStop(station: "city-hall", offset: 915),
                PatternStop(station: "race-vine", offset: 1035),
                PatternStop(station: "spring-garden", offset: 1125),
                PatternStop(station: "fairmount", offset: 1215),
                PatternStop(station: "girard", offset: 1305),
                PatternStop(station: "cecil-b-moore", offset: 1425),
                PatternStop(station: "susquehanna-dauphin", offset: 1530),
                PatternStop(station: "north-philadelphia", offset: 1620),
                PatternStop(station: "allegheny", offset: 1710),
                PatternStop(station: "erie", offset: 1815),
                PatternStop(station: "hunting-park", offset: 1935),
                PatternStop(station: "wyoming", offset: 2010),
                PatternStop(station: "logan", offset: 2085),
                PatternStop(station: "olney", offset: 2190),
                PatternStop(station: "fern-rock", offset: 2475),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([87315])],
                .saturday: [.departures([87315])],
                .sunday: [.departures([87315])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 39.82 min, 21 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 120),
                PatternStop(station: "logan", offset: 239),
                PatternStop(station: "wyoming", offset: 320),
                PatternStop(station: "hunting-park", offset: 426),
                PatternStop(station: "erie", offset: 540),
                PatternStop(station: "allegheny", offset: 645),
                PatternStop(station: "north-philadelphia", offset: 711),
                PatternStop(station: "susquehanna-dauphin", offset: 832),
                PatternStop(station: "cecil-b-moore", offset: 960),
                PatternStop(station: "girard", offset: 1020),
                PatternStop(station: "fairmount", offset: 1094),
                PatternStop(station: "spring-garden", offset: 1153),
                PatternStop(station: "race-vine", offset: 1218),
                PatternStop(station: "city-hall", offset: 1320, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1680),
                PatternStop(station: "lombard-south", offset: 1746),
                PatternStop(station: "ellsworth-federal", offset: 1860),
                PatternStop(station: "tasker-morris", offset: 1952),
                PatternStop(station: "snyder", offset: 2040),
                PatternStop(station: "oregon", offset: 2159),
                PatternStop(station: "nrg", offset: 2389),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.frequency(from: 10680, until: 15180, every: 900), .departures([15780])],
                .saturday: [.frequency(from: 10680, until: 16080, every: 900)],
                .sunday: [.frequency(from: 10680, until: 16080, every: 900)],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 43.82 min, 13 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v2",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 180),
                PatternStop(station: "logan", offset: 299),
                PatternStop(station: "wyoming", offset: 380),
                PatternStop(station: "hunting-park", offset: 486),
                PatternStop(station: "erie", offset: 600),
                PatternStop(station: "allegheny", offset: 705),
                PatternStop(station: "north-philadelphia", offset: 771),
                PatternStop(station: "susquehanna-dauphin", offset: 892),
                PatternStop(station: "cecil-b-moore", offset: 1020),
                PatternStop(station: "girard", offset: 1080),
                PatternStop(station: "fairmount", offset: 1184),
                PatternStop(station: "spring-garden", offset: 1267),
                PatternStop(station: "race-vine", offset: 1359),
                PatternStop(station: "city-hall", offset: 1500, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1860),
                PatternStop(station: "lombard-south", offset: 1948),
                PatternStop(station: "ellsworth-federal", offset: 2100),
                PatternStop(station: "tasker-morris", offset: 2192),
                PatternStop(station: "snyder", offset: 2280),
                PatternStop(station: "oregon", offset: 2399),
                PatternStop(station: "nrg", offset: 2629),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([1800, 2400, 3300, 4200, 5096])],
                .saturday: [.departures([2400, 3300, 4200, 5096])],
                .sunday: [.departures([2400, 3300, 4200, 5096])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 41.82 min, 12 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v3",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 180),
                PatternStop(station: "logan", offset: 299),
                PatternStop(station: "wyoming", offset: 380),
                PatternStop(station: "hunting-park", offset: 486),
                PatternStop(station: "erie", offset: 600),
                PatternStop(station: "allegheny", offset: 705),
                PatternStop(station: "north-philadelphia", offset: 771),
                PatternStop(station: "susquehanna-dauphin", offset: 892),
                PatternStop(station: "cecil-b-moore", offset: 1020),
                PatternStop(station: "girard", offset: 1080),
                PatternStop(station: "fairmount", offset: 1169),
                PatternStop(station: "spring-garden", offset: 1240),
                PatternStop(station: "race-vine", offset: 1318),
                PatternStop(station: "city-hall", offset: 1440, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1800),
                PatternStop(station: "lombard-south", offset: 1866),
                PatternStop(station: "ellsworth-federal", offset: 1980),
                PatternStop(station: "tasker-morris", offset: 2072),
                PatternStop(station: "snyder", offset: 2160),
                PatternStop(station: "oregon", offset: 2279),
                PatternStop(station: "nrg", offset: 2509),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([6060, 6960, 7860, 8760])],
                .saturday: [.departures([6060, 6960, 7860, 8760])],
                .sunday: [.departures([6060, 6960, 7860, 8760])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 41.82 min, 6 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v4",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 120),
                PatternStop(station: "logan", offset: 239),
                PatternStop(station: "wyoming", offset: 320),
                PatternStop(station: "hunting-park", offset: 426),
                PatternStop(station: "erie", offset: 540),
                PatternStop(station: "allegheny", offset: 645),
                PatternStop(station: "north-philadelphia", offset: 711),
                PatternStop(station: "susquehanna-dauphin", offset: 832),
                PatternStop(station: "cecil-b-moore", offset: 960),
                PatternStop(station: "girard", offset: 1020),
                PatternStop(station: "fairmount", offset: 1109),
                PatternStop(station: "spring-garden", offset: 1180),
                PatternStop(station: "race-vine", offset: 1258),
                PatternStop(station: "city-hall", offset: 1380, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1740),
                PatternStop(station: "lombard-south", offset: 1828),
                PatternStop(station: "ellsworth-federal", offset: 1980),
                PatternStop(station: "tasker-morris", offset: 2072),
                PatternStop(station: "snyder", offset: 2160),
                PatternStop(station: "oregon", offset: 2279),
                PatternStop(station: "nrg", offset: 2509),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([16920, 17520])],
                .saturday: [.departures([16920, 17520])],
                .sunday: [.departures([16920, 17520])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 45.80 min, 4 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v5",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 180),
                PatternStop(station: "logan", offset: 299),
                PatternStop(station: "wyoming", offset: 380),
                PatternStop(station: "hunting-park", offset: 486),
                PatternStop(station: "erie", offset: 600),
                PatternStop(station: "allegheny", offset: 705),
                PatternStop(station: "north-philadelphia", offset: 771),
                PatternStop(station: "susquehanna-dauphin", offset: 892),
                PatternStop(station: "cecil-b-moore", offset: 1020),
                PatternStop(station: "girard", offset: 1080),
                PatternStop(station: "fairmount", offset: 1184),
                PatternStop(station: "spring-garden", offset: 1267),
                PatternStop(station: "race-vine", offset: 1359),
                PatternStop(station: "city-hall", offset: 1500, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1920),
                PatternStop(station: "lombard-south", offset: 2008),
                PatternStop(station: "ellsworth-federal", offset: 2160),
                PatternStop(station: "tasker-morris", offset: 2261),
                PatternStop(station: "snyder", offset: 2359),
                PatternStop(station: "oregon", offset: 2492),
                PatternStop(station: "nrg", offset: 2748),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([840, 1200])],
                .saturday: [.departures([840])],
                .sunday: [.departures([840])],
            ])
        ),
        // B1_OWL southbound: City Hall → NRG, 8 stops, 15.80 min, 3 trips
        ServicePattern(
            id: "B1_OWL-southbound-city-hall-nrg-8",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "city-hall", offset: 0),
                PatternStop(station: "walnut-locust", offset: 120),
                PatternStop(station: "lombard-south", offset: 208),
                PatternStop(station: "ellsworth-federal", offset: 360),
                PatternStop(station: "tasker-morris", offset: 461),
                PatternStop(station: "snyder", offset: 559),
                PatternStop(station: "oregon", offset: 692),
                PatternStop(station: "nrg", offset: 948),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([1800])],
                .saturday: [.departures([1800])],
                .sunday: [.departures([1800])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 40.82 min, 3 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v6",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 180),
                PatternStop(station: "logan", offset: 299),
                PatternStop(station: "wyoming", offset: 380),
                PatternStop(station: "hunting-park", offset: 486),
                PatternStop(station: "erie", offset: 600),
                PatternStop(station: "allegheny", offset: 705),
                PatternStop(station: "north-philadelphia", offset: 771),
                PatternStop(station: "susquehanna-dauphin", offset: 892),
                PatternStop(station: "cecil-b-moore", offset: 1020),
                PatternStop(station: "girard", offset: 1080),
                PatternStop(station: "fairmount", offset: 1154),
                PatternStop(station: "spring-garden", offset: 1213),
                PatternStop(station: "race-vine", offset: 1278),
                PatternStop(station: "city-hall", offset: 1380, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1740),
                PatternStop(station: "lombard-south", offset: 1806),
                PatternStop(station: "ellsworth-federal", offset: 1920),
                PatternStop(station: "tasker-morris", offset: 2012),
                PatternStop(station: "snyder", offset: 2100),
                PatternStop(station: "oregon", offset: 2219),
                PatternStop(station: "nrg", offset: 2449),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([9720])],
                .saturday: [.departures([9720])],
                .sunday: [.departures([9720])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 44.82 min, 2 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v7",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 180),
                PatternStop(station: "logan", offset: 299),
                PatternStop(station: "wyoming", offset: 380),
                PatternStop(station: "hunting-park", offset: 486),
                PatternStop(station: "erie", offset: 600),
                PatternStop(station: "allegheny", offset: 705),
                PatternStop(station: "north-philadelphia", offset: 771),
                PatternStop(station: "susquehanna-dauphin", offset: 892),
                PatternStop(station: "cecil-b-moore", offset: 1020),
                PatternStop(station: "girard", offset: 1080),
                PatternStop(station: "fairmount", offset: 1184),
                PatternStop(station: "spring-garden", offset: 1267),
                PatternStop(station: "race-vine", offset: 1359),
                PatternStop(station: "city-hall", offset: 1500, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1920),
                PatternStop(station: "lombard-south", offset: 2008),
                PatternStop(station: "ellsworth-federal", offset: 2160),
                PatternStop(station: "tasker-morris", offset: 2252),
                PatternStop(station: "snyder", offset: 2340),
                PatternStop(station: "oregon", offset: 2459),
                PatternStop(station: "nrg", offset: 2689),
            ],
            schedule: Schedule(blocks: [
                .saturday: [.departures([1500])],
                .sunday: [.departures([1500])],
            ])
        ),
        // B1_OWL southbound: Erie → City Hall, 10 stops, 14.00 min, 1 trips
        ServicePattern(
            id: "B1_OWL-southbound-erie-city-hall-10",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "City Hall Station",
            stops: [
                PatternStop(station: "erie", offset: 0),
                PatternStop(station: "allegheny", offset: 103),
                PatternStop(station: "north-philadelphia", offset: 169),
                PatternStop(station: "susquehanna-dauphin", offset: 290),
                PatternStop(station: "cecil-b-moore", offset: 420),
                PatternStop(station: "girard", offset: 480),
                PatternStop(station: "fairmount", offset: 569),
                PatternStop(station: "spring-garden", offset: 640),
                PatternStop(station: "race-vine", offset: 718),
                PatternStop(station: "city-hall", offset: 840),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([17280])],
            ])
        ),
        // B1_OWL southbound: Fern Rock → NRG, 22 stops, 40.82 min, 1 trips
        ServicePattern(
            id: "B1_OWL-southbound-fern-rock-nrg-22-v8",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .southbound,
            headsign: "NRG Station",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 120),
                PatternStop(station: "logan", offset: 239),
                PatternStop(station: "wyoming", offset: 320),
                PatternStop(station: "hunting-park", offset: 426),
                PatternStop(station: "erie", offset: 540),
                PatternStop(station: "allegheny", offset: 645),
                PatternStop(station: "north-philadelphia", offset: 711),
                PatternStop(station: "susquehanna-dauphin", offset: 832),
                PatternStop(station: "cecil-b-moore", offset: 960),
                PatternStop(station: "girard", offset: 1020),
                PatternStop(station: "fairmount", offset: 1094),
                PatternStop(station: "spring-garden", offset: 1153),
                PatternStop(station: "race-vine", offset: 1218),
                PatternStop(station: "city-hall", offset: 1320, dwell: 300),
                PatternStop(station: "walnut-locust", offset: 1680),
                PatternStop(station: "lombard-south", offset: 1768),
                PatternStop(station: "ellsworth-federal", offset: 1920),
                PatternStop(station: "tasker-morris", offset: 2012),
                PatternStop(station: "snyder", offset: 2100),
                PatternStop(station: "oregon", offset: 2219),
                PatternStop(station: "nrg", offset: 2449),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([16380])],
            ])
        ),
        // B1_OWL northbound: NRG → Fern Rock, 22 stops, 43.00 min, 33 trips
        ServicePattern(
            id: "B1_OWL-northbound-nrg-fern-rock-22",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 120),
                PatternStop(station: "snyder", offset: 258),
                PatternStop(station: "tasker-morris", offset: 345),
                PatternStop(station: "ellsworth-federal", offset: 460),
                PatternStop(station: "lombard-south", offset: 611),
                PatternStop(station: "walnut-locust", offset: 696),
                PatternStop(station: "city-hall", offset: 763),
                PatternStop(station: "race-vine", offset: 1200),
                PatternStop(station: "spring-garden", offset: 1292),
                PatternStop(station: "fairmount", offset: 1359),
                PatternStop(station: "girard", offset: 1440),
                PatternStop(station: "cecil-b-moore", offset: 1560),
                PatternStop(station: "susquehanna-dauphin", offset: 1663),
                PatternStop(station: "north-philadelphia", offset: 1765),
                PatternStop(station: "allegheny", offset: 1869),
                PatternStop(station: "erie", offset: 1980),
                PatternStop(station: "hunting-park", offset: 2121),
                PatternStop(station: "wyoming", offset: 2229),
                PatternStop(station: "logan", offset: 2329),
                PatternStop(station: "olney", offset: 2460),
                PatternStop(station: "fern-rock", offset: 2580),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.frequency(from: 9420, until: 15720, every: 900), .departures([16320, 16920, 17520])],
                .saturday: [.frequency(from: 9420, until: 17520, every: 900), .departures([17880])],
                .sunday: [.frequency(from: 9420, until: 17520, every: 900), .departures([17880])],
            ])
        ),
        // B1_OWL northbound: NRG → Fern Rock, 22 stops, 42.00 min, 24 trips
        ServicePattern(
            id: "B1_OWL-northbound-nrg-fern-rock-22-v2",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 120),
                PatternStop(station: "snyder", offset: 258),
                PatternStop(station: "tasker-morris", offset: 345),
                PatternStop(station: "ellsworth-federal", offset: 460),
                PatternStop(station: "lombard-south", offset: 611),
                PatternStop(station: "walnut-locust", offset: 696),
                PatternStop(station: "city-hall", offset: 763),
                PatternStop(station: "race-vine", offset: 1200),
                PatternStop(station: "spring-garden", offset: 1292),
                PatternStop(station: "fairmount", offset: 1359),
                PatternStop(station: "girard", offset: 1440),
                PatternStop(station: "cecil-b-moore", offset: 1560),
                PatternStop(station: "susquehanna-dauphin", offset: 1663),
                PatternStop(station: "north-philadelphia", offset: 1765),
                PatternStop(station: "allegheny", offset: 1869),
                PatternStop(station: "erie", offset: 1980),
                PatternStop(station: "hunting-park", offset: 2103),
                PatternStop(station: "wyoming", offset: 2198),
                PatternStop(station: "logan", offset: 2286),
                PatternStop(station: "olney", offset: 2400),
                PatternStop(station: "fern-rock", offset: 2520),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([2520]), .frequency(from: 3120, until: 8520, every: 900)],
                .saturday: [.frequency(from: 2220, until: 8520, every: 900)],
                .sunday: [.frequency(from: 2220, until: 8520, every: 900)],
            ])
        ),
        // B1_OWL northbound: City Hall → Fern Rock, 15 stops, 27.00 min, 3 trips
        ServicePattern(
            id: "B1_OWL-northbound-city-hall-fern-rock-15",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "city-hall", offset: 0),
                PatternStop(station: "race-vine", offset: 120),
                PatternStop(station: "spring-garden", offset: 212),
                PatternStop(station: "fairmount", offset: 279),
                PatternStop(station: "girard", offset: 360),
                PatternStop(station: "cecil-b-moore", offset: 480),
                PatternStop(station: "susquehanna-dauphin", offset: 598),
                PatternStop(station: "north-philadelphia", offset: 716),
                PatternStop(station: "allegheny", offset: 835),
                PatternStop(station: "erie", offset: 960),
                PatternStop(station: "hunting-park", offset: 1101),
                PatternStop(station: "wyoming", offset: 1209),
                PatternStop(station: "logan", offset: 1309),
                PatternStop(station: "olney", offset: 1440),
                PatternStop(station: "fern-rock", offset: 1620),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([1800])],
                .saturday: [.departures([1800])],
                .sunday: [.departures([1800])],
            ])
        ),
        // B1_OWL northbound: NRG → Fern Rock, 22 stops, 44.00 min, 3 trips
        ServicePattern(
            id: "B1_OWL-northbound-nrg-fern-rock-22-v3",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 120),
                PatternStop(station: "snyder", offset: 258),
                PatternStop(station: "tasker-morris", offset: 345),
                PatternStop(station: "ellsworth-federal", offset: 460),
                PatternStop(station: "lombard-south", offset: 611),
                PatternStop(station: "walnut-locust", offset: 696),
                PatternStop(station: "city-hall", offset: 763),
                PatternStop(station: "race-vine", offset: 1200),
                PatternStop(station: "spring-garden", offset: 1292),
                PatternStop(station: "fairmount", offset: 1359),
                PatternStop(station: "girard", offset: 1440),
                PatternStop(station: "cecil-b-moore", offset: 1560),
                PatternStop(station: "susquehanna-dauphin", offset: 1678),
                PatternStop(station: "north-philadelphia", offset: 1796),
                PatternStop(station: "allegheny", offset: 1915),
                PatternStop(station: "erie", offset: 2040),
                PatternStop(station: "hunting-park", offset: 2181),
                PatternStop(station: "wyoming", offset: 2289),
                PatternStop(station: "logan", offset: 2389),
                PatternStop(station: "olney", offset: 2520),
                PatternStop(station: "fern-rock", offset: 2640),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([1320])],
                .saturday: [.departures([1320])],
                .sunday: [.departures([1320])],
            ])
        ),
        // B1_OWL northbound: Oregon → Fern Rock, 21 stops, 41.00 min, 2 trips
        ServicePattern(
            id: "B1_OWL-northbound-oregon-fern-rock-21",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "oregon", offset: 0),
                PatternStop(station: "snyder", offset: 138),
                PatternStop(station: "tasker-morris", offset: 225),
                PatternStop(station: "ellsworth-federal", offset: 340),
                PatternStop(station: "lombard-south", offset: 491),
                PatternStop(station: "walnut-locust", offset: 576),
                PatternStop(station: "city-hall", offset: 643),
                PatternStop(station: "race-vine", offset: 1080),
                PatternStop(station: "spring-garden", offset: 1172),
                PatternStop(station: "fairmount", offset: 1239),
                PatternStop(station: "girard", offset: 1320),
                PatternStop(station: "cecil-b-moore", offset: 1440),
                PatternStop(station: "susquehanna-dauphin", offset: 1543),
                PatternStop(station: "north-philadelphia", offset: 1645),
                PatternStop(station: "allegheny", offset: 1749),
                PatternStop(station: "erie", offset: 1860),
                PatternStop(station: "hunting-park", offset: 2001),
                PatternStop(station: "wyoming", offset: 2109),
                PatternStop(station: "logan", offset: 2209),
                PatternStop(station: "olney", offset: 2340),
                PatternStop(station: "fern-rock", offset: 2460),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([11160, 14880])],
            ])
        ),
        // B1_OWL northbound: NRG → Fern Rock, 22 stops, 43.00 min, 1 trips
        ServicePattern(
            id: "B1_OWL-northbound-nrg-fern-rock-22-v4",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "nrg", offset: 0),
                PatternStop(station: "oregon", offset: 120),
                PatternStop(station: "snyder", offset: 258),
                PatternStop(station: "tasker-morris", offset: 345),
                PatternStop(station: "ellsworth-federal", offset: 460),
                PatternStop(station: "lombard-south", offset: 611),
                PatternStop(station: "walnut-locust", offset: 696),
                PatternStop(station: "city-hall", offset: 763),
                PatternStop(station: "race-vine", offset: 1200),
                PatternStop(station: "spring-garden", offset: 1292),
                PatternStop(station: "fairmount", offset: 1359),
                PatternStop(station: "girard", offset: 1440),
                PatternStop(station: "cecil-b-moore", offset: 1560),
                PatternStop(station: "susquehanna-dauphin", offset: 1678),
                PatternStop(station: "north-philadelphia", offset: 1796),
                PatternStop(station: "allegheny", offset: 1915),
                PatternStop(station: "erie", offset: 2040),
                PatternStop(station: "hunting-park", offset: 2163),
                PatternStop(station: "wyoming", offset: 2258),
                PatternStop(station: "logan", offset: 2346),
                PatternStop(station: "olney", offset: 2460),
                PatternStop(station: "fern-rock", offset: 2580),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([1920])],
            ])
        ),
        // B1_OWL northbound: Oregon → Fern Rock, 21 stops, 40.00 min, 1 trips
        ServicePattern(
            id: "B1_OWL-northbound-oregon-fern-rock-21-v2",
            lineID: "B-OWL",
            kind: .nightBus,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "oregon", offset: 0),
                PatternStop(station: "snyder", offset: 138),
                PatternStop(station: "tasker-morris", offset: 225),
                PatternStop(station: "ellsworth-federal", offset: 340),
                PatternStop(station: "lombard-south", offset: 491),
                PatternStop(station: "walnut-locust", offset: 576),
                PatternStop(station: "city-hall", offset: 643),
                PatternStop(station: "race-vine", offset: 1080),
                PatternStop(station: "spring-garden", offset: 1172),
                PatternStop(station: "fairmount", offset: 1239),
                PatternStop(station: "girard", offset: 1320),
                PatternStop(station: "cecil-b-moore", offset: 1440),
                PatternStop(station: "susquehanna-dauphin", offset: 1543),
                PatternStop(station: "north-philadelphia", offset: 1645),
                PatternStop(station: "allegheny", offset: 1749),
                PatternStop(station: "erie", offset: 1860),
                PatternStop(station: "hunting-park", offset: 1983),
                PatternStop(station: "wyoming", offset: 2078),
                PatternStop(station: "logan", offset: 2166),
                PatternStop(station: "olney", offset: 2280),
                PatternStop(station: "fern-rock", offset: 2400),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([7560])],
            ])
        ),
        // B2 southbound: Fern Rock → Walnut-Locust, 8 stops, 19.75 min, 59 trips
        ServicePattern(
            id: "B2-southbound-fern-rock-walnut-locust-8",
            lineID: "B",
            kind: .express,
            direction: .southbound,
            headsign: "Walnut-Locust",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 225),
                PatternStop(station: "erie", offset: 480),
                PatternStop(station: "girard", offset: 765),
                PatternStop(station: "spring-garden", offset: 870),
                PatternStop(station: "race-vine", offset: 960),
                PatternStop(station: "city-hall", offset: 1080),
                PatternStop(station: "walnut-locust", offset: 1185),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([20850, 22050, 23085, 23610, 24030, 24480]), .frequency(from: 24870, until: 32430, every: 420), .departures([33180, 33600, 34470, 35040, 48720, 49320, 50160, 50880, 51660, 52500, 53340, 54180, 55020, 55875, 56700, 57240]), .frequency(from: 57720, until: 64860, every: 420)],
            ])
        ),
        // B2 northbound: Walnut-Locust → Fern Rock, 8 stops, 20.25 min, 59 trips
        ServicePattern(
            id: "B2-northbound-walnut-locust-fern-rock-8",
            lineID: "B",
            kind: .express,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "walnut-locust", offset: 0),
                PatternStop(station: "city-hall", offset: 90),
                PatternStop(station: "race-vine", offset: 210),
                PatternStop(station: "spring-garden", offset: 300),
                PatternStop(station: "girard", offset: 435),
                PatternStop(station: "erie", offset: 675),
                PatternStop(station: "olney", offset: 930),
                PatternStop(station: "fern-rock", offset: 1215),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([22635, 23670, 24750]), .frequency(from: 25185, until: 33585, every: 420), .departures([34065, 34725, 35385, 35985, 36585, 50265, 50865, 51705, 52425]), .frequency(from: 53205, until: 57405, every: 840), .departures([58185]), .frequency(from: 58890, until: 64770, every: 420), .departures([65205, 65610, 66045, 66645])],
            ])
        ),
        // B3 southbound: Olney → 8th & Market, 7 stops, 15.50 min, 75 trips
        ServicePattern(
            id: "B3-southbound-olney-8th-and-market-7",
            lineID: "B",
            kind: .spur,
            direction: .southbound,
            headsign: "8th-Market",
            stops: [
                PatternStop(station: "olney", offset: 0),
                PatternStop(station: "erie", offset: 255),
                PatternStop(station: "north-philadelphia", offset: 375),
                PatternStop(station: "girard", offset: 570),
                PatternStop(station: "fairmount", offset: 690),
                PatternStop(station: "chinatown", offset: 825),
                PatternStop(station: "8th-and-market", offset: 930),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([21795, 23070, 24030]), .frequency(from: 24960, until: 32520, every: 420), .departures([33105, 33945]), .frequency(from: 34845, until: 55005, every: 840), .departures([55785, 56685, 57810]), .frequency(from: 58635, until: 64935, every: 420), .departures([65490, 66090, 66690, 67290, 67890, 68970, 70245])],
            ])
        ),
        // B3 southbound: Fern Rock → 8th & Market, 8 stops, 19.25 min, 54 trips
        ServicePattern(
            id: "B3-southbound-fern-rock-8th-and-market-8",
            lineID: "B",
            kind: .spur,
            direction: .southbound,
            headsign: "8th-Market",
            stops: [
                PatternStop(station: "fern-rock", offset: 0),
                PatternStop(station: "olney", offset: 225),
                PatternStop(station: "erie", offset: 480),
                PatternStop(station: "north-philadelphia", offset: 600),
                PatternStop(station: "girard", offset: 795),
                PatternStop(station: "fairmount", offset: 915),
                PatternStop(station: "chinatown", offset: 1050),
                PatternStop(station: "8th-and-market", offset: 1155),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([19455, 20520, 22230, 23280, 24360, 57120, 58005, 71415, 72615, 74055])],
                .saturday: [.departures([22560, 23640, 24960]), .frequency(from: 26220, until: 74220, every: 1200)],
            ])
        ),
        // B3 northbound: 8th & Market → Olney, 7 stops, 14.00 min, 75 trips
        ServicePattern(
            id: "B3-northbound-8th-and-market-olney-7",
            lineID: "B",
            kind: .spur,
            direction: .northbound,
            headsign: "Olney Transit Center",
            stops: [
                PatternStop(station: "8th-and-market", offset: 0),
                PatternStop(station: "chinatown", offset: 90),
                PatternStop(station: "fairmount", offset: 195),
                PatternStop(station: "girard", offset: 300),
                PatternStop(station: "north-philadelphia", offset: 450),
                PatternStop(station: "erie", offset: 585),
                PatternStop(station: "olney", offset: 840),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([20745, 21975, 22920, 23550, 24195, 24690]), .frequency(from: 25170, until: 31890, every: 420), .departures([32730, 33840]), .frequency(from: 34560, until: 57240, every: 840), .departures([58005]), .frequency(from: 58440, until: 64740, every: 420), .departures([65580, 66000, 66540, 67740, 68475])],
            ])
        ),
        // B3 northbound: 8th & Market → Fern Rock, 8 stops, 18.75 min, 54 trips
        ServicePattern(
            id: "B3-northbound-8th-and-market-fern-rock-8",
            lineID: "B",
            kind: .spur,
            direction: .northbound,
            headsign: "Fern Rock Transit Center",
            stops: [
                PatternStop(station: "8th-and-market", offset: 0),
                PatternStop(station: "chinatown", offset: 90),
                PatternStop(station: "fairmount", offset: 195),
                PatternStop(station: "girard", offset: 300),
                PatternStop(station: "north-philadelphia", offset: 450),
                PatternStop(station: "erie", offset: 585),
                PatternStop(station: "olney", offset: 840),
                PatternStop(station: "fern-rock", offset: 1125),
            ],
            schedule: Schedule(blocks: [
                .weekday: [.departures([32310, 33150, 65160, 67140, 69285, 70155, 71325, 72720, 74085, 75480])],
                .saturday: [.departures([24405, 25755]), .frequency(from: 27105, until: 73905, every: 1200), .departures([75165, 76530])],
            ])
        ),
    ]

    public static let network = Network(
        lines: lines,
        stations: stations,
        patterns: patterns,
        provenance: provenance
    )
}
