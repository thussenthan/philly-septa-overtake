#!/usr/bin/env python3
"""Generate MetroKit's bundled timetable from SEPTA's official GTFS feed.

SEPTA publishes GTFS on GitHub as a zip-of-zips; the Metro lines (B1 local,
B2 express, B3 Broad-Ridge Spur, B1_OWL night bus) live inside
``google_bus.zip`` with ``route_type=1`` for the subway.

The output is a single Swift file of literals — no bundle resources, no JSON
parsing at runtime, and the compiler checks the shape for us.

Usage
-----
    python3 tools/build_schedule.py                 # download, then generate
    python3 tools/build_schedule.py --feed path.zip # use a local feed
    python3 tools/build_schedule.py --report        # print a human summary only

The feed only declares two weeks of validity, so this is re-run whenever the
timetable changes. ``BSLData.feedEndDate`` lets the app warn a rider when the
bundled schedule has aged out.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import os
import statistics
import sys
import urllib.request
import zipfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

GTFS_URL = "https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip"
INNER_ZIP = "google_bus.zip"

# The Broad Street Line and its night-bus replacement.
SUBWAY_ROUTES = ["B1", "B2", "B3"]
NIGHT_ROUTES = ["B1_OWL"]
ROUTES = SUBWAY_ROUTES + NIGHT_ROUTES

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "BroadStreetCommute" / "MetroKit" / "Data" / "GeneratedBSLData.swift"
CACHE_DIR = Path(__file__).resolve().parent / ".cache"

# Rider-facing names. SEPTA's GTFS names are inconsistent ("Broad-Girard" but
# "Race-Vine"); these read the way the station signs and the rest of the city do.
STATION_DISPLAY_NAMES = {
    "Fern Rock Transit Center": ("Fern Rock", "Transit Center"),
    "Olney Transit Center": ("Olney", "Transit Center"),
    "Broad-Allegheny": ("Allegheny", None),
    "Broad-Girard": ("Girard", None),
    "Broad-Spring Garden": ("Spring Garden", None),
    "Cecil B. Moore": ("Cecil B. Moore", "Temple University"),
    "15th St/City Hall": ("City Hall", "15th St"),
    "North Philadelphia": ("North Philadelphia", None),
    "NRG Station": ("NRG", "Sports Complex"),
    "8th-Market": ("8th & Market", None),
}

# The cross street a rider actually navigates to. Broad St is 14th St.
STATION_INTERSECTIONS = {
    "Fern Rock Transit Center": "10th St & Nedro Ave",
    "Olney Transit Center": "Broad St & Olney Ave",
    "Logan": "Broad St & Rockland St",
    "Wyoming": "Broad St & Wyoming Ave",
    "Hunting Park": "Broad St & Hunting Park Ave",
    "Erie": "Broad St & Erie Ave",
    "Broad-Allegheny": "Broad St & Allegheny Ave",
    "North Philadelphia": "Broad St & Glenwood Ave",
    "Susquehanna-Dauphin": "Broad St & Susquehanna Ave",
    "Cecil B. Moore": "Broad St & Cecil B. Moore Ave",
    "Broad-Girard": "Broad St & Girard Ave",
    "Fairmount": "Broad St & Fairmount Ave",
    "Broad-Spring Garden": "Broad St & Spring Garden St",
    "Race-Vine": "Broad St & Race St",
    "15th St/City Hall": "Broad St & Market St",
    "Walnut-Locust": "Broad St & Locust St",
    "Lombard-South": "Broad St & South St",
    "Ellsworth-Federal": "Broad St & Federal St",
    "Tasker-Morris": "Broad St & Morris St",
    "Snyder": "Broad St & Snyder Ave",
    "Oregon": "Broad St & Oregon Ave",
    "NRG": "Broad St & Pattison Ave",
    "Chinatown": "8th St & Vine St",
    "8th-Market": "8th St & Market St",
}


# --------------------------------------------------------------------------
# Feed loading
# --------------------------------------------------------------------------

def download_feed(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {GTFS_URL}", file=sys.stderr)
    with urllib.request.urlopen(GTFS_URL) as response, open(destination, "wb") as handle:
        handle.write(response.read())
    print(f"  wrote {destination} ({destination.stat().st_size:,} bytes)", file=sys.stderr)
    return destination


class Feed:
    """Lazy reader for the ``google_bus.zip`` nested inside SEPTA's release."""

    def __init__(self, path: Path):
        outer = zipfile.ZipFile(path)
        names = outer.namelist()
        if INNER_ZIP not in names:
            raise SystemExit(f"{path} does not contain {INNER_ZIP} (found {names})")
        self.zip = zipfile.ZipFile(io.BytesIO(outer.read(INNER_ZIP)))

    def rows(self, name: str):
        with self.zip.open(name) as raw:
            reader = csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig"))
            for row in reader:
                yield row

    def table(self, name: str) -> list[dict]:
        return list(self.rows(name))


# --------------------------------------------------------------------------
# Service calendar
# --------------------------------------------------------------------------

DAY_FIELDS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def parse_date(value: str) -> dt.date:
    return dt.date(int(value[0:4]), int(value[4:6]), int(value[6:8]))


def service_dates(feed: Feed) -> dict[str, set[dt.date]]:
    """Every date each service ID runs on, over the whole span the feed describes.

    SEPTA attaches calendar_dates rows to essentially every date, so "this date
    has an exception" says nothing about whether the day is ordinary. What does
    distinguish an ordinary service from a special-event one is how many dates it
    covers — see ``recurring_services``.
    """
    calendar = feed.table("calendar.txt")
    exceptions = feed.table("calendar_dates.txt")

    span_start = min(parse_date(r["start_date"]) for r in calendar)
    span_end = max(parse_date(r["end_date"]) for r in calendar)
    for row in exceptions:
        span_start = min(span_start, parse_date(row["date"]))
        span_end = max(span_end, parse_date(row["date"]))

    dates: dict[str, set[dt.date]] = defaultdict(set)
    for row in calendar:
        start, end = parse_date(row["start_date"]), parse_date(row["end_date"])
        day = max(start, span_start)
        while day <= min(end, span_end):
            if row[DAY_FIELDS[day.weekday()]] == "1":
                dates[row["service_id"]].add(day)
            day += dt.timedelta(days=1)
    for row in exceptions:
        day = parse_date(row["date"])
        if row["exception_type"] == "1":
            dates[row["service_id"]].add(day)
        elif row["exception_type"] == "2":
            dates[row["service_id"]].discard(day)
    return dates


# A service running on this many dates or fewer is a special-event or
# single-date addition, not part of the ordinary weekly timetable. SEPTA's
# feed carried three FIFA World Cup express trips on one Sunday; treating them
# as regular service would have told riders an express train existed on
# Sundays, which it does not.
RECURRING_DATE_THRESHOLD = 3


def recurring_services(feed: Feed) -> tuple[dict[str, set[dt.date]], set[str]]:
    dates = service_dates(feed)
    rare = {sid for sid, days in dates.items() if len(days) < RECURRING_DATE_THRESHOLD}
    return dates, rare


def representative_dates(feed: Feed, dates: dict[str, set[dt.date]]) -> dict[str, dt.date]:
    """Pick one ordinary date per day type from inside the feed's validity window.

    Sampling a single real date — rather than unioning every weekday service ID
    across the feed — avoids stitching together timetable revisions that are
    never in effect on the same day.
    """
    info = feed.table("feed_info.txt")[0]
    start, end = parse_date(info["feed_start_date"]), parse_date(info["feed_end_date"])

    # Midweek, so a Monday/Friday variant does not become "the" weekday.
    wanted = {"weekday": (1, 2, 3), "saturday": (5,), "sunday": (6,)}
    chosen: dict[str, dt.date] = {}
    for label, weekdays in wanted.items():
        day = start
        while day <= end:
            if day.weekday() in weekdays:
                chosen[label] = day
                break
            day += dt.timedelta(days=1)
        if label not in chosen:
            raise SystemExit(f"no {label} inside {start}..{end}")
    return chosen


# --------------------------------------------------------------------------
# Pattern extraction
# --------------------------------------------------------------------------

def parse_gtfs_time(value: str) -> int:
    """GTFS ``HH:MM:SS`` to seconds after midnight. Hours may exceed 24."""
    hours, minutes, seconds = (int(part) for part in value.strip().split(":"))
    return hours * 3600 + minutes * 60 + seconds


@dataclass
class PatternKey:
    route_id: str
    direction_id: str
    stops: tuple[str, ...]
    offsets: tuple[int, ...]
    dwells: tuple[int, ...]

    def as_tuple(self):
        return (self.route_id, self.direction_id, self.stops, self.offsets, self.dwells)


@dataclass
class Pattern:
    key: PatternKey
    headsign: str
    # day type -> sorted trip start times, seconds after midnight
    starts: dict[str, list[int]] = field(default_factory=lambda: defaultdict(list))
    trip_count: int = 0


def extract(feed: Feed) -> dict:
    routes = {r["route_id"]: r for r in feed.table("routes.txt") if r["route_id"] in ROUTES}
    missing = set(ROUTES) - set(routes)
    if missing:
        raise SystemExit(f"feed is missing routes {sorted(missing)}")

    directions: dict[tuple[str, str], str] = {}
    for row in feed.table("directions.txt"):
        if row["route_id"] in ROUTES:
            directions[(row["route_id"], row["direction_id"])] = row.get("direction_destination", "")

    stops_by_id = {r["stop_id"]: r for r in feed.table("stops.txt")}

    trips = [t for t in feed.table("trips.txt") if t["route_id"] in ROUTES]
    trip_index = {t["trip_id"]: t for t in trips}

    # One pass over stop_times.txt: it holds millions of rows for the whole system.
    sequences: dict[str, list[tuple[int, str, int, int]]] = defaultdict(list)
    for row in feed.rows("stop_times.txt"):
        trip_id = row["trip_id"]
        if trip_id not in trip_index:
            continue
        sequences[trip_id].append((
            int(row["stop_sequence"]),
            row["stop_id"],
            parse_gtfs_time(row["arrival_time"]),
            parse_gtfs_time(row["departure_time"]),
        ))

    all_service_dates, rare_services = recurring_services(feed)
    dates = representative_dates(feed, all_service_dates)
    services_by_day = {
        label: {sid for sid, days in all_service_dates.items()
                if day in days and sid not in rare_services}
        for label, day in dates.items()
    }

    # Build the station map before keying patterns, so a pattern's stops are
    # station ids rather than feed-specific platform ids.
    rail_stop_ids: set[str] = set()
    surface_stop_ids: set[str] = set()
    for trip_id, rows in sequences.items():
        bucket = surface_stop_ids if trip_index[trip_id]["route_id"] in NIGHT_ROUTES else rail_stop_ids
        bucket.update(r[1] for r in rows)
    surface_stop_ids -= rail_stop_ids

    stations, stop_to_station, unsnapped, snap_report = build_stations(
        {sid: stops_by_id[sid] for sid in rail_stop_ids if sid in stops_by_id},
        {sid: stops_by_id[sid] for sid in surface_stop_ids if sid in stops_by_id},
    )

    patterns: dict[tuple, Pattern] = {}
    skipped_no_service = 0
    skipped_rare = 0
    dropped_stops = 0

    for trip_id, rows in sequences.items():
        rows.sort(key=lambda r: r[0])
        trip = trip_index[trip_id]
        service_id = trip["service_id"]
        if service_id in rare_services:
            skipped_rare += 1
            continue
        day_types = [label for label, ids in services_by_day.items() if service_id in ids]
        if not day_types:
            # A service not in effect on any sampled date — a future timetable
            # revision, or a day type we do not model.
            skipped_no_service += 1
            continue

        origin_departure = rows[0][3]
        station_ids: list[str] = []
        arrivals: list[int] = []
        dwells: list[int] = []
        for _, stop_id, arrival, departure in rows:
            station_id = stop_to_station.get(stop_id)
            if station_id is None:
                dropped_stops += 1
                continue
            if station_ids and station_ids[-1] == station_id:
                # Two curbside stops snapped to the same station; keep the first.
                continue
            station_ids.append(station_id)
            arrivals.append(arrival - origin_departure)
            dwells.append(departure - arrival)
        if len(station_ids) < 2:
            continue

        key = PatternKey(
            trip["route_id"], trip["direction_id"],
            tuple(station_ids), tuple(arrivals), tuple(dwells),
        )
        pattern = patterns.get(key.as_tuple())
        if pattern is None:
            pattern = Pattern(key=key, headsign=trip.get("trip_headsign", "").strip())
            patterns[key.as_tuple()] = pattern
        for label in day_types:
            pattern.starts[label].append(origin_departure)
        pattern.trip_count += 1

    for pattern in patterns.values():
        for label in list(pattern.starts):
            pattern.starts[label] = sorted(set(pattern.starts[label]))

    return {
        "routes": routes,
        "directions": directions,
        "patterns": list(patterns.values()),
        "stations": stations,
        "unsnapped_surface_stops": unsnapped,
        "surface_snaps": snap_report,
        "dropped_stop_times": dropped_stops,
        "feed_info": feed.table("feed_info.txt")[0],
        "representative_dates": {k: v.isoformat() for k, v in dates.items()},
        "skipped_no_service": skipped_no_service,
        "skipped_rare": skipped_rare,
    }


# --------------------------------------------------------------------------
# Station identity
# --------------------------------------------------------------------------

PLATFORM_SUFFIXES = (" - B1", " - B2", " - B3", " - B2 & B3", " - BSL", " - MFL")


def normalized_stop_name(name: str) -> str:
    """Strip the platform qualifier SEPTA appends to split-platform stations.

    Express and local trains stop on different tracks at Olney and City Hall, so
    the feed names them "Olney Transit Center - B1" and "... - B2 & B3". Left
    alone, that would make the express platform a different *station* from the
    local one, and the planner would never find the cross-platform transfer that
    is the whole point of this app.
    """
    cleaned = name.strip()
    changed = True
    while changed:
        changed = False
        for suffix in PLATFORM_SUFFIXES:
            if cleaned.endswith(suffix):
                cleaned = cleaned[: -len(suffix)].strip()
                changed = True
    return cleaned


def slugify(value: str) -> str:
    slug = value.lower()
    for old, new in [("&", "and"), ("/", " "), (".", ""), ("'", ""), ("-", " ")]:
        slug = slug.replace(old, new)
    return "-".join(part for part in slug.split() if part)


def canonical_station_id(stop_name: str) -> str:
    """A stable, direction- and platform-independent station identifier.

    GTFS gives each platform its own ``stop_id`` and SEPTA renumbers them between
    feed releases, so ids are derived from the name instead. That keeps saved
    places, tests, and shared links valid across regenerations.
    """
    display = STATION_DISPLAY_NAMES.get(normalized_stop_name(stop_name), (normalized_stop_name(stop_name), None))[0]
    return slugify(display)


def haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    import math
    radius = 6_371_008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1 - a)))


# How close an Owl-bus curbside stop has to be to a subway station before we
# treat them as the same place. The Owl runs on the surface directly above the
# line, so its stops sit at the same intersections — but a station node can sit
# mid-block from its curb stops (North Philadelphia's is 331 m from the Broad &
# Glenwood curb). 350 m catches those without reaching the next station, which
# is never closer than ~460 m on this line.
OWL_SNAP_METERS = 350.0


def build_stations(
    rail_stops: dict[str, dict],
    surface_stops: dict[str, dict],
) -> tuple[dict[str, dict], dict[str, str], list[str], list[tuple[float, str, str]]]:
    """Merge platforms into stations, then snap surface stops onto them.

    Returns the stations, a stop-id → station-id map, the names of surface stops
    that had no station nearby (dropped from routing), and every snap that was
    made with its distance, so the radius can be eyeballed rather than trusted.
    """
    grouped: dict[str, list[dict]] = defaultdict(list)
    for stop in rail_stops.values():
        grouped[canonical_station_id(stop["stop_name"])].append(stop)

    stations: dict[str, dict] = {}
    stop_to_station: dict[str, str] = {}
    for station_id, members in sorted(grouped.items()):
        gtfs_name = normalized_stop_name(members[0]["stop_name"])
        display, subtitle = STATION_DISPLAY_NAMES.get(gtfs_name, (gtfs_name, None))
        latitude = statistics.fmean(float(m["stop_lat"]) for m in members)
        longitude = statistics.fmean(float(m["stop_lon"]) for m in members)
        wheelchair = {m.get("wheelchair_boarding", "0") for m in members}
        accessible = None
        if wheelchair == {"1"}:
            accessible = True
        elif wheelchair == {"2"}:
            accessible = False
        stations[station_id] = {
            "id": station_id,
            "name": display,
            "subtitle": subtitle,
            "intersection": STATION_INTERSECTIONS.get(gtfs_name) or STATION_INTERSECTIONS.get(display),
            "latitude": round(latitude, 6),
            "longitude": round(longitude, 6),
            "accessible": accessible,
            "gtfs_name": gtfs_name,
            "gtfs_stop_ids": sorted(m["stop_id"] for m in members),
        }
        for m in members:
            stop_to_station[m["stop_id"]] = station_id

    unsnapped: list[str] = []
    snap_report: list[tuple[float, str, str]] = []
    for stop_id, stop in surface_stops.items():
        if stop_id in stop_to_station:
            continue
        lat, lon = float(stop["stop_lat"]), float(stop["stop_lon"])
        best_id, best_distance = None, OWL_SNAP_METERS
        for station in stations.values():
            distance = haversine_meters(lat, lon, station["latitude"], station["longitude"])
            if distance < best_distance:
                best_id, best_distance = station["id"], distance
        if best_id is None:
            unsnapped.append(stop["stop_name"])
        else:
            stop_to_station[stop_id] = best_id
            snap_report.append((best_distance, stop["stop_name"], best_id))
    snap_report.sort(reverse=True)
    return stations, stop_to_station, sorted(set(unsnapped)), snap_report


# --------------------------------------------------------------------------
# Swift emission
# --------------------------------------------------------------------------

def swift_string(value: str | None) -> str:
    if value is None:
        return "nil"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def swift_optional_string(value: str | None) -> str:
    return swift_string(value)


def swift_bool(value: bool | None) -> str:
    if value is None:
        return "nil"
    return "true" if value else "false"


def pattern_kind(route_id: str) -> str:
    if route_id in NIGHT_ROUTES:
        return "nightBus"
    if route_id == "B3":
        return "spur"
    if route_id == "B2":
        return "express"
    return "local"


def compress_starts(starts: list[int]) -> str:
    """Emit a run of evenly spaced departures as ``.frequency`` when it pays.

    A flat seven-minute peak collapses from dozens of integers to one line, and
    the emitted Swift stays legible when someone reads the generated file.
    """
    if not starts:
        return ""
    blocks: list[str] = []
    index = 0
    literal: list[int] = []

    def flush_literal():
        if literal:
            joined = ", ".join(str(v) for v in literal)
            blocks.append(f".departures([{joined}])")
            literal.clear()

    while index < len(starts):
        # Look for the longest evenly spaced run starting here.
        best_length, best_step = 1, 0
        if index + 2 < len(starts):
            step = starts[index + 1] - starts[index]
            if step > 0:
                length = 2
                while index + length < len(starts) and starts[index + length] - starts[index + length - 1] == step:
                    length += 1
                best_length, best_step = length, step
        # Six or more identical gaps is where a frequency band beats a list.
        if best_length >= 6 and best_step > 0:
            flush_literal()
            first = starts[index]
            last = starts[index + best_length - 1]
            blocks.append(f".frequency(from: {first}, until: {last}, every: {best_step})")
            index += best_length
        else:
            literal.append(starts[index])
            index += 1
    flush_literal()
    return ", ".join(blocks)


def emit_swift(data: dict) -> str:
    stations = data["stations"]
    info = data["feed_info"]
    patterns = sorted(
        data["patterns"],
        key=lambda p: (p.key.route_id, p.key.direction_id, -p.trip_count, p.key.stops),
    )

    lines: list[str] = []
    add = lines.append

    add("// swiftlint:disable all")
    add("// -----------------------------------------------------------------------------")
    add("// GENERATED FILE — do not edit by hand.")
    add("//")
    add("// Produced by tools/build_schedule.py from SEPTA's official GTFS feed:")
    add(f"//   {GTFS_URL}")
    add(f"//   feed_version {info['feed_version']}  "
        f"valid {info['feed_start_date']}–{info['feed_end_date']}")
    add("//")
    add("// Timetables are sampled from one ordinary date per day type so that")
    add("// single-date extras (special-event trips) do not leak into the schedule:")
    for label, date in sorted(data["representative_dates"].items()):
        add(f"//   {label}: {date}")
    add("//")
    add("// Re-run `python3 tools/build_schedule.py` when SEPTA publishes a new feed.")
    add("// -----------------------------------------------------------------------------")
    add("")
    add("import Foundation")
    add("")
    add("public enum BSLData {")
    add("")
    add(f"    /// GTFS `feed_version` this file was generated from.")
    add(f"    public static let feedVersion = {swift_string(info['feed_version'])}")
    add("    /// Last date SEPTA declares this timetable valid, `yyyyMMdd`.")
    add(f"    public static let feedEndDate = {swift_string(info['feed_end_date'])}")
    add(f"    public static let feedStartDate = {swift_string(info['feed_start_date'])}")
    add("")
    add("    public static let provenance = DataProvenance(")
    add("        fidelity: .official,")
    add(f"        source: {swift_string('SEPTA GTFS ' + info['feed_version'])},")
    add(f"        generated: {swift_string(dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d'))},")
    add(f"        validUntil: {swift_string(info['feed_end_date'])},")
    add(f"        notes: {swift_string('Sampled from SEPTA GTFS; regenerate with tools/build_schedule.py')}")
    add("    )")
    add("")

    # Lines
    add("    public static let lines: [Line] = [")
    add('        Line(id: "B", badge: "B", name: "Broad Street Line", colorHex: "F26100"),')
    add('        Line(id: "B-OWL", badge: "B", name: "Broad Street Owl Bus", colorHex: "F26100"),')
    add("    ]")
    add("")

    # Which lines serve each station.
    station_lines: dict[str, set[str]] = defaultdict(set)
    for pattern in patterns:
        line_id = "B-OWL" if pattern.key.route_id in NIGHT_ROUTES else "B"
        for station_id in pattern.key.stops:
            station_lines[station_id].add(line_id)

    add("    public static let stations: [Station] = [")
    for station in stations.values():
        line_list = ", ".join(f'"{l}"' for l in sorted(station_lines.get(station["id"], {"B"})))
        add("        Station(")
        add(f'            id: "{station["id"]}",')
        add(f"            name: {swift_string(station['name'])},")
        add(f"            subtitle: {swift_optional_string(station['subtitle'])},")
        add(f"            intersection: {swift_optional_string(station['intersection'])},")
        add(f"            coordinate: Coordinate(latitude: {station['latitude']}, longitude: {station['longitude']}),")
        add(f"            lines: [{line_list}],")
        add(f"            isAccessible: {swift_bool(station['accessible'])}")
        add("        ),")
    add("    ]")
    add("")

    add("    public static let patterns: [ServicePattern] = [")
    seen_ids: set[str] = set()
    for pattern in patterns:
        route_id = pattern.key.route_id
        station_ids = list(pattern.key.stops)
        direction = "southbound" if pattern.key.direction_id == "0" else "northbound"
        kind = pattern_kind(route_id)
        line_id = "B-OWL" if route_id in NIGHT_ROUTES else "B"

        base = f"{route_id}-{direction}-{station_ids[0]}-{station_ids[-1]}-{len(station_ids)}"
        pattern_id = base
        suffix = 2
        while pattern_id in seen_ids:
            pattern_id = f"{base}-v{suffix}"
            suffix += 1
        seen_ids.add(pattern_id)

        headsign = pattern.headsign or data["directions"].get((route_id, pattern.key.direction_id), "")
        if not headsign:
            headsign = stations[station_ids[-1]]["name"]

        total_trips = sum(len(v) for v in pattern.starts.values())
        add(f"        // {route_id} {direction}: {stations[station_ids[0]]['name']} → "
            f"{stations[station_ids[-1]]['name']}, {len(station_ids)} stops, "
            f"{pattern.key.offsets[-1] / 60:.2f} min, {total_trips} trips")
        add("        ServicePattern(")
        add(f"            id: {swift_string(pattern_id)},")
        add(f'            lineID: "{line_id}",')
        add(f"            kind: .{kind},")
        add(f"            direction: .{direction},")
        add(f"            headsign: {swift_string(headsign)},")
        add("            stops: [")
        for station_id, offset, dwell in zip(station_ids, pattern.key.offsets, pattern.key.dwells):
            if dwell:
                add(f'                PatternStop(station: "{station_id}", offset: {offset}, dwell: {dwell}),')
            else:
                add(f'                PatternStop(station: "{station_id}", offset: {offset}),')
        add("            ],")
        add("            schedule: Schedule(blocks: [")
        for label in ("weekday", "saturday", "sunday"):
            starts = pattern.starts.get(label) or []
            if not starts:
                continue
            add(f"                .{label}: [{compress_starts(starts)}],")
        add("            ])")
        add("        ),")
    add("    ]")
    add("")
    add("    public static let network = Network(")
    add("        lines: lines,")
    add("        stations: stations,")
    add("        patterns: patterns,")
    add("        provenance: provenance")
    add("    )")
    add("}")
    add("")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def report(data: dict) -> None:
    stations = data["stations"]
    info = data["feed_info"]
    print(f"feed {info['feed_version']}  valid {info['feed_start_date']}–{info['feed_end_date']}")
    print(f"representative dates: {data['representative_dates']}")
    print(f"stations: {len(stations)}   patterns: {len(data['patterns'])}")
    print(f"trips skipped: {data['skipped_rare']} special-event, "
          f"{data['skipped_no_service']} not in effect on a sampled date")
    print(f"surface stop-times dropped (no station within "
          f"{OWL_SNAP_METERS:.0f} m): {data['dropped_stop_times']}")
    if data["surface_snaps"]:
        print("  furthest surface-stop snaps:")
        for distance, name, station_id in data["surface_snaps"][:5]:
            print(f"    {distance:6.1f} m  {name}  →  {station_id}")
    if data["unsnapped_surface_stops"]:
        print("  unsnapped surface stops:")
        for name in data["unsnapped_surface_stops"]:
            print(f"    {name}")
    print()
    print("stations north → south:")
    for station in sorted(data["stations"].values(), key=lambda s: -s["latitude"]):
        flag = "" if station["accessible"] is None else ("  ♿" if station["accessible"] else "  (no elevator)")
        print(f"  {station['id']:<24} {station['name']:<22} "
              f"{station['latitude']:.5f},{station['longitude']:.5f}{flag}")
    print()
    by_route: dict[str, list[Pattern]] = defaultdict(list)
    for pattern in data["patterns"]:
        by_route[pattern.key.route_id].append(pattern)
    for route_id in ROUTES:
        print(f"=== {route_id} ===")
        for pattern in sorted(by_route[route_id], key=lambda p: (p.key.direction_id, -p.trip_count)):
            ids = list(pattern.key.stops)
            direction = "SB" if pattern.key.direction_id == "0" else "NB"
            counts = {k: len(v) for k, v in sorted(pattern.starts.items())}
            print(f"  {direction} {len(ids):2d} stops  {pattern.key.offsets[-1] / 60:6.2f} min  {counts}")
            print(f"     {ids[0]} → {ids[-1]}")
            if len(ids) <= 12:
                print(f"     {' · '.join(ids)}")
        print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path, help="local gtfs_public.zip instead of downloading")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", action="store_true", help="print a summary and do not write Swift")
    parser.add_argument("--json", type=Path, help="also dump the extracted data as JSON")
    args = parser.parse_args()

    feed_path = args.feed
    if feed_path is None:
        feed_path = CACHE_DIR / "gtfs_public.zip"
        if not feed_path.exists():
            download_feed(feed_path)
        else:
            print(f"using cached {feed_path}", file=sys.stderr)

    feed = Feed(feed_path)
    data = extract(feed)

    if args.json:
        args.json.write_text(json.dumps({
            "feed_info": data["feed_info"],
            "representative_dates": data["representative_dates"],
            "stations": data["stations"],
        }, indent=2))

    report(data)

    if args.report:
        return 0

    source = emit_swift(data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)
    print(f"wrote {args.output} ({len(source):,} bytes, {source.count(chr(10)):,} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
