#!/usr/bin/env python3
"""Generate MetroKit's bundled timetable from SEPTA's official GTFS feed.

SEPTA publishes GTFS on GitHub as a zip-of-zips; the Metro lines (B1 local,
B2 express, B3 Broad-Ridge Spur, B1_OWL night bus) live inside
``google_bus.zip`` with ``route_type=1`` for the subway.

The output is a single Swift file of literals — no bundle resources, no JSON
parsing at runtime, and the compiler checks the shape for us.

Usage
-----
    python3 tools/build_schedule.py                  # download, then generate
    python3 tools/build_schedule.py --feed path.zip  # use a local feed
    python3 tools/build_schedule.py --report         # print a human summary only
    python3 tools/build_schedule.py --scope metro    # the whole Metro rail map

The feed only declares two weeks of validity, so this is re-run whenever the
timetable changes. ``SEPTAData.feedEndDate`` lets the app warn a rider when the
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

# GTFS route_types that count as rail rapid transit / trolley for our purposes.
#   0 = tram/streetcar (T1-T5 subway-surface, G1 Girard, D1/D2 Media-Sharon Hill)
#   1 = metro/subway   (B1/B2/B3 Broad St, L1 Market-Frankford, M1 Norristown)
#  11 = trolleybus     (the trackless trolleys, routes 59/66/75)
RAIL_ROUTE_TYPES = {"0", "1", "11"}

# Night service that replaces a rail line at street level.
NIGHT_ROUTES = ["B1_OWL"]

# Scope presets, selected with --scope.
#   metro  — everything on the SEPTA Metro rail map (the default)
#   broad  — the Broad Street Line alone, useful for a smaller test fixture
SCOPES = {
    "broad": {"B1", "B2", "B3"},
    "metro": None,  # resolved from RAIL_ROUTE_TYPES against the feed
}

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "SEPTACommute" / "MetroKit" / "Data" / "GeneratedSEPTAData.swift"
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

def resolve_routes(feed: "Feed", scope: str) -> list[str]:
    """The route IDs to include, for a named scope."""
    rows = feed.table("routes.txt")
    if SCOPES.get(scope) is not None:
        wanted = SCOPES[scope]
        found = {r["route_id"] for r in rows} & wanted
        missing = wanted - found
        if missing:
            raise SystemExit(f"feed is missing routes {sorted(missing)}")
        rail = sorted(found)
    else:
        rail = sorted(r["route_id"] for r in rows if r["route_type"] in RAIL_ROUTE_TYPES)
    return rail + [r for r in NIGHT_ROUTES if any(x["route_id"] == r for x in rows)]


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
# single-date addition, not part of the ordinary weekly timetable.
#
# SEPTA adds B2 express trips to NRG whenever there is a game at the sports
# complex — Eagles, Phillies, and one-off events like the 2026 World Cup. Those
# trips are real, but they run on a handful of named dates, and treating them as
# regular service would tell a rider on an ordinary Sunday that an express train
# exists when it does not. Filtering by how many dates a service covers catches
# all of them without needing to know what the event was.
RECURRING_DATE_THRESHOLD = 3


def recurring_services(feed: Feed) -> tuple[dict[str, set[dt.date]], set[str]]:
    dates = service_dates(feed)
    rare = {sid for sid, days in dates.items() if len(days) < RECURRING_DATE_THRESHOLD}
    return dates, rare


# Matches MetroKit's DayType cases.
DAY_TYPES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def representative_dates(feed: Feed, dates: dict[str, set[dt.date]]) -> dict[str, dt.date]:
    """Pick one real date per day of the week from inside the feed's validity window.

    One date per *weekday*, not one per weekday/Saturday/Sunday. Sampling a
    single midweek date and calling it "the weekday timetable" silently discarded
    every service scoped to a particular day — 435 trips on the full rail map.
    Unioning the week instead would have been worse than dropping them: it would
    promise a rider on a Monday a trip that only runs on Fridays.

    Sampling real dates (rather than unioning service IDs) still avoids stitching
    together timetable revisions never in effect on the same day.
    """
    info = feed.table("feed_info.txt")[0]
    start, end = parse_date(info["feed_start_date"]), parse_date(info["feed_end_date"])

    # The *latest* occurrence of each weekday, not the earliest. SEPTA ships more
    # than one timetable revision inside a single feed — this one carries services
    # that only begin part-way through its validity window — so sampling the first
    # week can generate a timetable that is already superseded.
    chosen: dict[str, dt.date] = {}
    day = start
    while day <= end:
        chosen[DAY_TYPES[day.weekday()]] = day
        day += dt.timedelta(days=1)

    missing = [d for d in DAY_TYPES if d not in chosen]
    if missing:
        raise SystemExit(f"feed window {start}..{end} does not cover {missing}")
    return chosen


# --------------------------------------------------------------------------
# Pattern extraction
# --------------------------------------------------------------------------

def parse_gtfs_time(value: str) -> int:
    """GTFS ``HH:MM:SS`` to seconds after midnight. Hours may exceed 24."""
    hours, minutes, seconds = (int(part) for part in value.strip().split(":"))
    return hours * 3600 + minutes * 60 + seconds


# Two trips over the same stops whose end-to-end running times differ by less
# than this are treated as one pattern, timed by the median of the group.
#
# Rail running times in this feed are identical to the second on every trip, so
# for the subway this changes nothing. Street-running trolleys are different:
# their scheduled times flex with traffic, and keying patterns on exact offsets
# turned 81 real stopping patterns into 829 near-duplicates — which is both
# meaningless to a rider and a needless multiplier on the planner's search.
RUNTIME_VARIANT_TOLERANCE = 120


@dataclass
class PatternKey:
    route_id: str
    direction_id: str
    stops: tuple[str, ...]
    offsets: tuple[int, ...]
    dwells: tuple[int, ...]
    # Per stop: bit 0 set when boarding is prohibited, bit 1 when alighting is.
    flags: tuple[int, ...] = ()

    def as_tuple(self):
        return (self.route_id, self.direction_id, self.stops, self.offsets, self.dwells, self.flags)


@dataclass
class Pattern:
    key: PatternKey
    headsign: str
    # day type -> sorted trip start times, seconds after midnight
    starts: dict[str, list[int]] = field(default_factory=lambda: defaultdict(list))
    trip_count: int = 0
    # Share of this pattern's stop times SEPTA actually publishes, rather than
    # interpolating between timing points. 100 on the subway, ~15 on the trolleys.
    published_time_percent: int = 100


def extract(feed: Feed, scope: str = "broad") -> dict:
    route_ids = resolve_routes(feed, scope)
    ROUTES = set(route_ids)
    routes = {r["route_id"]: r for r in feed.table("routes.txt") if r["route_id"] in ROUTES}

    # directions.txt is a SEPTA extension, and it is the authority on which words
    # each route uses for its two ends. Worth taking literally rather than deriving
    # from geometry: it calls D1/D2 northbound and southbound even though Media is
    # mostly *west* of 69th St, and direction_id 0 is southbound on route 59 but
    # northbound on route 66. No amount of measuring gets to that.
    directions: dict[tuple[str, str], str] = {}
    direction_words: dict[tuple[str, str], str] = {}
    for row in feed.table("directions.txt"):
        if row["route_id"] in ROUTES:
            key = (row["route_id"], row["direction_id"])
            directions[key] = row.get("direction_destination", "")
            word = (row.get("direction") or "").strip().lower()
            if word.endswith("bound"):
                direction_words[key] = word[: -len("bound")]

    stops_by_id = {r["stop_id"]: r for r in feed.table("stops.txt")}

    trips = [t for t in feed.table("trips.txt") if t["route_id"] in ROUTES]
    trip_index = {t["trip_id"]: t for t in trips}

    # One pass over stop_times.txt: it holds millions of rows for the whole system.
    sequences: dict[str, list[tuple[int, str, int, int, bool, bool, bool]]] = defaultdict(list)
    for row in feed.rows("stop_times.txt"):
        trip_id = row["trip_id"]
        if trip_id not in trip_index:
            continue
        # pickup_type / drop_off_type of 1 means the door does not open for that
        # purpose here — all 1,082 such stop-times on the Metro map are at *middle*
        # stops, not trip ends, so ignoring them lets the planner tell a rider to
        # get off somewhere they cannot.
        # timepoint 0 means SEPTA interpolated the time rather than publishing it.
        sequences[trip_id].append((
            int(row["stop_sequence"]),
            row["stop_id"],
            parse_gtfs_time(row["arrival_time"]),
            parse_gtfs_time(row["departure_time"]),
            row.get("pickup_type", "0") == "1",
            row.get("drop_off_type", "0") == "1",
            (row.get("timepoint") or "1") == "1",
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

    routes_by_stop: dict[str, set[str]] = defaultdict(set)
    for trip_id, rows in sequences.items():
        route_id = trip_index[trip_id]["route_id"]
        for row in rows:
            routes_by_stop[row[1]].add(route_id)

    stations, stop_to_station, unsnapped, snap_report = build_stations(
        {sid: stops_by_id[sid] for sid in rail_stop_ids if sid in stops_by_id},
        {sid: stops_by_id[sid] for sid in surface_stop_ids if sid in stops_by_id},
        routes_by_stop,
    )

    patterns: dict[tuple, Pattern] = {}
    raw_groups: dict[tuple, list] = defaultdict(list)
    group_trips: dict[tuple, list] = defaultdict(list)
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
        flags: list[int] = []
        exact = 0
        for _, stop_id, arrival, departure, no_pickup, no_dropoff, timepoint in rows:
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
            flags.append((1 if no_pickup else 0) | (2 if no_dropoff else 0))
            exact += 1 if timepoint else 0
        if len(station_ids) < 2:
            continue

        # Bucket by end-to-end running time so genuinely different speeds stay
        # separate (a peak express run vs. a slow one) while jitter collapses.
        bucket = arrivals[-1] // RUNTIME_VARIANT_TOLERANCE
        group = (trip["route_id"], trip["direction_id"], tuple(station_ids), bucket, tuple(flags))
        raw_groups[group].append((tuple(arrivals), tuple(dwells), exact, len(station_ids)))
        group_trips[group].append((origin_departure, day_types, trip.get("trip_headsign", "").strip()))

    # Collapse each group into one pattern timed by the median of its trips.
    runtime_spread: list[tuple[int, str]] = []
    for group, timings in raw_groups.items():
        route_id, direction_id, station_ids, _bucket, flags = group
        columns = list(zip(*[t[0] for t in timings]))
        offsets = tuple(int(statistics.median(col)) for col in columns)
        dwell_columns = list(zip(*[t[1] for t in timings]))
        dwells = tuple(int(statistics.median(col)) for col in dwell_columns)
        spread = max(t[0][-1] for t in timings) - min(t[0][-1] for t in timings)
        runtime_spread.append((spread, f"{route_id} {direction_id} {len(station_ids)} stops"))

        published = sum(t[2] for t in timings)
        total_stops = sum(t[3] for t in timings)
        key = PatternKey(route_id, direction_id, station_ids, offsets, dwells, flags)
        headsign = next((t[2] for t in group_trips[group] if t[2]), "")
        pattern = Pattern(key=key, headsign=headsign)
        pattern.published_time_percent = round(100 * published / total_stops) if total_stops else 100
        for origin_departure, day_types, _ in group_trips[group]:
            for label in day_types:
                pattern.starts[label].append(origin_departure)
        pattern.trip_count = len(group_trips[group])
        patterns[key.as_tuple()] = pattern

    for pattern in patterns.values():
        for label in list(pattern.starts):
            pattern.starts[label] = sorted(set(pattern.starts[label]))
    runtime_spread.sort(reverse=True)

    return {
        "routes": routes,
        "directions": directions,
        "direction_words": direction_words,
        "patterns": list(patterns.values()),
        "stations": stations,
        "unsnapped_surface_stops": unsnapped,
        "surface_snaps": snap_report,
        "dropped_stop_times": dropped_stops,
        "route_ids": route_ids,
        "runtime_spread": runtime_spread[:6],
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

# Two differently-named stops this close together, with no route in common, are
# one place. SEPTA names the L platform at 40th & Market "40th St" and the trolley
# platform 13 m away "40th-Market"; without merging them the planner cannot find a
# change between the L and the trolleys there at all. Requiring no shared route
# keeps consecutive stops of a single surface route from collapsing into each other.
STATION_MERGE_METERS = 75.0


def build_stations(
    rail_stops: dict[str, dict],
    surface_stops: dict[str, dict],
    routes_by_stop: dict[str, set[str]] | None = None,
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

    # Merge differently-named stops that sit on top of each other.
    routes_by_stop = routes_by_stop or {}
    merges: list[tuple[float, str, str]] = []
    ids = sorted(stations)
    for index, left in enumerate(ids):
        if left not in stations:
            continue
        for right in ids[index + 1:]:
            if right not in stations or left not in stations:
                continue
            a, b = stations[left], stations[right]
            distance = haversine_meters(a["latitude"], a["longitude"], b["latitude"], b["longitude"])
            if distance > STATION_MERGE_METERS:
                continue
            a_routes = {r for sid in a["gtfs_stop_ids"] for r in routes_by_stop.get(sid, ())}
            b_routes = {r for sid in b["gtfs_stop_ids"] for r in routes_by_stop.get(sid, ())}
            if a_routes & b_routes:
                continue
            merges.append((distance, right, left))
            # Keep the station with more platforms; it is the better-known name.
            keep, drop = (left, right) if len(a["gtfs_stop_ids"]) >= len(b["gtfs_stop_ids"]) else (right, left)
            kept, gone = stations[keep], stations.pop(drop)
            kept["gtfs_stop_ids"] = sorted(set(kept["gtfs_stop_ids"]) | set(gone["gtfs_stop_ids"]))
            for stop_id in gone["gtfs_stop_ids"]:
                stop_to_station[stop_id] = keep
            for stop_id, mapped in list(stop_to_station.items()):
                if mapped == drop:
                    stop_to_station[stop_id] = keep

    unsnapped: list[str] = []
    snap_report: list[tuple[float, str, str]] = []
    snap_report.extend((d, f"MERGED {a}", b) for d, a, b in merges)
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


# SEPTA Metro map letters. A line can carry several routes: the Broad Street Line
# is one orange "B" on the map but three routes in the feed, and it is the route
# identity the planner needs to know where a change of train is possible.
def line_id_for(route_id: str) -> str:
    if route_id in NIGHT_ROUTES:
        return "B-OWL"
    letter = route_id.rstrip("0123456789")
    return letter if letter else route_id


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


def encode_field(value) -> str:
    """One field of the text format. `|` is the field separator, so it cannot appear."""
    if value is None:
        return ""
    return str(value).replace("|", "/").replace("\n", " ")


def encode_stop(station_id: str, offset: int, dwell: int, flags: int) -> str:
    """One stop of a pattern: `station:offset[:dwell[:flags]]`.

    Trailing zero fields are dropped — 309 patterns' worth of `:0:0` is 40 KB of
    generated source that says nothing.
    """
    parts = [station_id, str(offset)]
    if dwell or flags:
        parts.append(str(dwell))
    if flags:
        parts.append(str(flags))
    return ":".join(parts)


def encode_blocks(starts: list[int]) -> str:
    """Departure times as `f:from:until:every` and `t:a,b,c` blocks joined by `;`."""
    pieces: list[str] = []
    index = 0
    literal: list[int] = []

    def flush():
        if literal:
            pieces.append("t:" + ",".join(str(v) for v in literal))
            literal.clear()

    while index < len(starts):
        best_length, best_step = 1, 0
        if index + 2 < len(starts):
            step = starts[index + 1] - starts[index]
            if step > 0:
                length = 2
                while index + length < len(starts) and starts[index + length] - starts[index + length - 1] == step:
                    length += 1
                best_length, best_step = length, step
        if best_length >= 6 and best_step > 0:
            flush()
            pieces.append(f"f:{starts[index]}:{starts[index + best_length - 1]}:{best_step}")
            index += best_length
        else:
            literal.append(starts[index])
            index += 1
    flush()
    return ";".join(pieces)


def emit_swift(data: dict) -> str:
    stations = data["stations"]
    info = data["feed_info"]
    patterns = sorted(
        data["patterns"],
        key=lambda p: (p.key.route_id, p.key.direction_id, -p.trip_count, p.key.stops),
    )

    # One Line per map letter, coloured and named from the feed itself.
    line_rows: dict[str, dict] = {}
    for route_id in data["route_ids"]:
        line_id = line_id_for(route_id)
        route = data["routes"][route_id]
        name = route["route_long_name"] or route["route_short_name"]
        if route_id in NIGHT_ROUTES:
            name = "Broad Street Owl Bus"
        elif line_id == "B":
            name = "Broad Street Line"
        elif line_id == "L":
            name = "Market-Frankford Line"
        elif line_id == "M":
            name = "Norristown High Speed Line"
        elif line_id == "T":
            name = "Subway-Surface Trolleys"
        elif line_id == "G":
            name = "Girard Ave Trolley"
        elif line_id == "D":
            name = "Media-Sharon Hill Trolleys"
        elif line_id.isdigit():
            name = f"Route {line_id}"
        colour = (route["route_color"] or "").upper()
        if colour in ("", "FFFFFF", "FFF", "000000", "000"):
            colour = "6B7280"
        if line_id not in line_rows:
            line_rows[line_id] = {
                "id": line_id,
                "badge": line_id.split("-")[0],
                "name": name,
                "color": colour,
                # SEPTA's own ordering: L1 first, then B, T, G, D, M, then buses.
                # Alphabetical by badge put the trackless trolleys ahead of the
                # subway, which is nobody's mental model of this network.
                "sort": 9999,
            }
            line_rows[line_id]["sort"] = min(
                line_rows[line_id]["sort"],
                int(route.get("route_sort_order") or 9999),
            )

    station_lines: dict[str, set[str]] = defaultdict(set)
    for pattern in patterns:
        line_id = line_id_for(pattern.key.route_id)
        for station_id in pattern.key.stops:
            station_lines[station_id].add(line_id)

    # ---- the data itself, as text records ----
    records: list[str] = []
    records.append("|".join([
        "M", encode_field(info["feed_version"]), encode_field(info["feed_start_date"]),
        encode_field(info["feed_end_date"]),
        encode_field(dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")),
        encode_field("SEPTA GTFS " + info["feed_version"]),
    ]))
    for line in sorted(line_rows.values(), key=lambda l: (l["sort"], l["badge"])):
        records.append("|".join(["L", encode_field(line["id"]), encode_field(line["badge"]),
                                 encode_field(line["name"]), encode_field(line["color"]),
                                 str(line["sort"])]))
    for station in stations.values():
        accessible = "-" if station["accessible"] is None else ("1" if station["accessible"] else "0")
        records.append("|".join([
            "S", encode_field(station["id"]), encode_field(station["name"]),
            encode_field(station["subtitle"]), encode_field(station["intersection"]),
            f"{station['latitude']:.6f}", f"{station['longitude']:.6f}",
            ",".join(sorted(station_lines.get(station["id"], set()))),
            accessible,
        ]))

    seen_ids: set[str] = set()
    total_departures = 0
    for pattern in patterns:
        route_id = pattern.key.route_id
        station_ids = list(pattern.key.stops)
        direction = "southbound" if pattern.key.direction_id == "0" else "northbound"
        kind = pattern_kind(route_id)
        line_id = line_id_for(route_id)

        base = f"{route_id}-{direction}-{station_ids[0]}-{station_ids[-1]}-{len(station_ids)}"
        pattern_id, suffix = base, 2
        while pattern_id in seen_ids:
            pattern_id = f"{base}-v{suffix}"
            suffix += 1
        seen_ids.add(pattern_id)

        headsign = pattern.headsign or data["directions"].get((route_id, pattern.key.direction_id), "")
        if not headsign:
            headsign = stations[station_ids[-1]]["name"]

        compass = data["direction_words"].get((route_id, pattern.key.direction_id), "")
        records.append("|".join(["P", encode_field(pattern_id), encode_field(line_id),
                                 encode_field(route_id), kind, direction, encode_field(headsign),
                                 compass, str(pattern.published_time_percent)]))
        stop_flags = pattern.key.flags or (0,) * len(station_ids)
        records.append("O|" + ",".join(
            encode_stop(sid, offset, dwell, flag)
            for sid, offset, dwell, flag
            in zip(station_ids, pattern.key.offsets, pattern.key.dwells, stop_flags)
        ))

        by_timetable: dict[tuple[int, ...], list[str]] = {}
        for label in DAY_TYPES:
            starts = pattern.starts.get(label) or []
            if not starts:
                continue
            by_timetable.setdefault(tuple(starts), []).append(label)
        for starts, labels in by_timetable.items():
            total_departures += len(starts) * len(labels)
            records.append(f"D|{','.join(labels)}|{encode_blocks(list(starts))}")

    # ---- wrap it in Swift ----
    # Chunked so no single string literal is enormous, and so the array literal
    # holding them stays small and homogeneous. Both keep the type checker cheap:
    # emitting this data as nested Swift literals needed more memory to compile
    # than a laptop has.
    CHUNK = 400
    chunks = ["\n".join(records[i:i + CHUNK]) for i in range(0, len(records), CHUNK)]

    out: list[str] = []
    add = out.append
    add("// swiftlint:disable all")
    add("// -----------------------------------------------------------------------------")
    add("// GENERATED FILE — do not edit by hand.")
    add("//")
    add("// Produced by tools/build_schedule.py from SEPTA's official GTFS feed:")
    add(f"//   {GTFS_URL}")
    add(f"//   feed_version {info['feed_version']}  valid {info['feed_start_date']}–{info['feed_end_date']}")
    add("//")
    add("// Timetables are sampled from one real date per day of the week, taking the")
    add("// latest occurrence of each inside the feed's validity window so a superseded")
    add("// revision is not what gets baked in:")
    for label in DAY_TYPES:
        if label in data["representative_dates"]:
            add(f"//   {label}: {data['representative_dates'][label]}")
    add("//")
    add("// Stored as text and parsed by NetworkDecoder rather than as Swift literals —")
    add("// see that file for why.")
    add("//")
    add("// Re-run `python3 tools/build_schedule.py` when SEPTA publishes a new feed.")
    add("// -----------------------------------------------------------------------------")
    add("")
    add("import Foundation")
    add("")
    add("public enum SEPTAData {")
    add("")
    add(f"    public static let feedVersion = {swift_string(info['feed_version'])}")
    add(f"    public static let feedStartDate = {swift_string(info['feed_start_date'])}")
    add(f"    public static let feedEndDate = {swift_string(info['feed_end_date'])}")
    add("")
    add("    /// Counts asserted by the test suite, so a truncated or half-parsed")
    add("    /// blob fails loudly instead of quietly routing over less of the city.")
    add(f"    public static let expectedStationCount = {len(stations)}")
    add(f"    public static let expectedPatternCount = {len(patterns)}")
    add(f"    public static let expectedDepartureCount = {total_departures}")
    add("")
    add("    /// Decoded once, on first use.")
    add("    public static let network: Network = NetworkDecoder.decode(parts)")
    add("")
    add("    static let parts: [String] = [")
    for chunk in chunks:
        # Delimiters sit at column 0 so the data lines need no indentation. Swift
        # requires every line of a multi-line literal to be indented at least as
        # far as its *closing* delimiter, and indenting 1,800 data lines to match
        # an indented delimiter would just pad the file for nothing.
        add('"""')
        add(chunk)
        add('""",')
    add("    ]")
    add("}")
    add("")
    return "\n".join(out)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def report(data: dict) -> None:
    stations = data["stations"]
    info = data["feed_info"]
    print(f"feed {info['feed_version']}  valid {info['feed_start_date']}–{info['feed_end_date']}")
    print("representative dates: "
          + ", ".join(f"{k} {v}" for k, v in sorted(data["representative_dates"].items(),
                                                    key=lambda kv: DAY_TYPES.index(kv[0]))))
    print(f"stations: {len(stations)}   patterns: {len(data['patterns'])}")
    print(f"trips skipped: {data['skipped_rare']} special-event, "
          f"{data['skipped_no_service']} not in effect on a sampled date")
    print(f"widest running-time spread collapsed into one pattern: "
          f"{[(f'{s}s', label) for s, label in data['runtime_spread']]}")
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
    for route_id in data["route_ids"]:
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
    parser.add_argument("--scope", choices=sorted(SCOPES), default="metro",
                        help="which routes to include (default: the whole Metro rail map)")
    args = parser.parse_args()

    feed_path = args.feed
    if feed_path is None:
        feed_path = CACHE_DIR / "gtfs_public.zip"
        if not feed_path.exists():
            download_feed(feed_path)
        else:
            print(f"using cached {feed_path}", file=sys.stderr)

    feed = Feed(feed_path)
    data = extract(feed, args.scope)

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
