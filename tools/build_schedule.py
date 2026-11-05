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

The feed declares a limited validity window (two weeks to four months), so this is
re-run whenever the timetable changes. ``SEPTAData.feedEndDate`` lets the app warn a rider when the
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
    "Broad-Spring Garden": ("Spring Garden", "Broad St"),
    "Spring Garden": ("Spring Garden", "Front St"),
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
    "Spring Garden": "Front St & Spring Garden St",
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

# Two stations on this network genuinely share a name, and deriving ids from names
# collapsed them into one.
#
# The Broad Street Line's Spring Garden is at Broad & Spring Garden; the
# Market-Frankford Line's is at Front & Spring Garden, 1.8 km east. Merged, they
# became a single station at the midpoint — a place that does not exist, roughly
# 900 m from either real platform, advertising a B-to-L interchange that does not
# exist either. Since the names cannot tell them apart, the ids are stated.
STATION_ID_OVERRIDES = {
    "Broad-Spring Garden": "spring-garden-broad",
    "Spring Garden": "spring-garden-front",
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
    """Fetch the feed to a temporary file and rename it into place only when whole.

    Writing straight to the cache path meant an interrupted download left a truncated
    zip there, which every later run then reused as "cached".
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    print(f"downloading {GTFS_URL}", file=sys.stderr)
    with urllib.request.urlopen(GTFS_URL, timeout=120) as response:
        if response.status != 200:
            raise SystemExit(f"download failed: HTTP {response.status}")
        partial.write_bytes(response.read())
    if not zipfile.is_zipfile(partial):
        partial.unlink(missing_ok=True)
        raise SystemExit("download failed: the response was not a zip file")
    partial.replace(destination)
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


def read_fares(feed: Feed) -> dict:
    """The adult pay-per-ride fare, and what a transfer costs.

    GTFS-Fares v2, and SEPTA fills it in properly: one $2.90 product per payment
    medium, and `fare_transfer_rules` rows that carry **no** fare_product_id, which
    under transfer type 0 means the transfer adds nothing — free, within
    `duration_limit`, up to `transfer_count` of them. Cash and Quick Trip have no
    such rule, so with those every boarding is a new fare. That difference is worth
    surfacing: it is $2.90 against $5.80 for the same two-train trip.
    """
    media = {m["fare_media_id"]: m["fare_media_name"] for m in feed.table("fare_media.txt")}
    default_categories = {
        r["rider_category_id"]
        for r in feed.table("rider_categories.txt")
        if r.get("is_default_fare_category") == "1"
    } or {"adult_full_fare"}

    products = {}
    for row in feed.table("fare_products.txt"):
        category = row.get("rider_category_id")
        if category and category not in default_categories:
            continue
        products[row["fare_product_id"]] = row

    group_media: dict[str, str] = {}
    amounts: list[float] = []
    for row in feed.table("fare_leg_rules.txt"):
        product = products.get(row.get("fare_product_id", ""))
        if not product:
            continue
        group_media[row["leg_group_id"]] = media.get(product.get("fare_media_id", ""), "")
        amounts.append(float(product["amount"]))

    window = allowed = 0
    free_media: list[str] = []
    for row in feed.table("fare_transfer_rules.txt"):
        if row["from_leg_group_id"] != row["to_leg_group_id"]:
            continue
        if row.get("fare_product_id"):
            continue  # the transfer costs something of its own; not a free one
        window = max(window, int(row.get("duration_limit") or 0))
        allowed = max(allowed, int(row.get("transfer_count") or 0))
        name = group_media.get(row["from_leg_group_id"])
        if name and name not in free_media:
            free_media.append(name)

    paid = {
        media.get(row.get("fare_media_id", ""), "")
        for row in products.values()
    } - set(free_media) - {""}
    return {
        "amount": min(amounts) if amounts else 0.0,
        "currency": next((p["currency"] for p in products.values()), "USD"),
        "transfer_window": window,
        "included_transfers": allowed,
        "free_transfer_media": sorted(free_media),
        "per_boarding_media": sorted(paid),
    }


def service_dates(feed: Feed) -> dict[str, set[dt.date]]:
    """Every date each service ID runs on, over the whole span the feed describes.

    calendar.txt's weekly ranges, then calendar_dates.txt's additions (type 1) and
    removals (type 2) — SEPTA leans on the latter heavily, attaching rows to nearly
    every date, so neither file alone says what runs on a given day.
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


# Every service the feed defines is kept, however few dates it runs on.
#
# Earlier versions dropped any service on three dates or fewer as a "special event",
# because with one timetable per weekday there was nowhere to put it: a B2 express
# for an Eagles game would otherwise have been promised on every Sunday. With a
# timetable per *date* that reason is gone — a one-date service lands on exactly
# its one date — and the filter was doing real harm: on v202611010 it threw away
# Regional Rail's whole Christmas Day timetable (SID1897939, 249 trips), the
# Thanksgiving / New Year's Day B1 and L1 service (439 trips), the Norristown bus
# substitution and the regular Fox Chase / Paoli weekend trips of early November.


# SEPTA's own ordering of the lines, for feeds that don't publish route_sort_order:
# the subway and trolleys, then the buses, then the Owl.
# Larger than any value a feed publishes: the sort key is a minimum, and this was
# 9999 until SEPTA started numbering its routes 10011, 10021, … and every line
# clamped to the same value.
SORT_UNKNOWN = 10**9
SORT_FALLBACK = {
    "L": 1001, "B": 1011, "T": 1021, "G": 1031, "D": 1041, "M": 1051,
    "59": 2054, "66": 2061, "75": 2067, "B-OWL": 3002,
}

# Matches MetroKit's DayType cases.
DAY_TYPES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


@dataclass
class DayKeys:
    """The feed's service calendar, date by date.

    A *day key* is one distinct set of active service IDs. Every date in the window
    maps to exactly one, so two dates share a key only when SEPTA runs exactly the
    same trips on both — ordinary Tuesdays collapse into one key, while Christmas,
    Thanksgiving, a timetable change or a game day at the stadiums each get their own.
    A pattern then carries one list of start times per key, which is the published
    timetable for every date that key covers, exactly.

    ``keys[i]`` is the key of ``start + i days``. ``weekday_default[d]`` (Monday = 0)
    is the key that covers the most dates of that weekday (the latest on a tie): what
    a reader of the data uses for a date outside the window, as a projection.
    """
    start: dt.date
    keys: list[int]
    sets: list[frozenset]
    weekday_default: list[int]

    @property
    def end(self) -> dt.date:
        return self.start + dt.timedelta(days=len(self.keys) - 1)

    def key(self, day: dt.date) -> int | None:
        index = (day - self.start).days
        return self.keys[index] if 0 <= index < len(self.keys) else None

    def keys_of_service(self, service_id: str) -> list[int]:
        return [k for k, ids in enumerate(self.sets) if service_id in ids]

    def dates_of_key(self, key: int) -> list[dt.date]:
        return [self.start + dt.timedelta(days=i) for i, k in enumerate(self.keys) if k == key]


def day_keys(dates: dict[str, set[dt.date]], services: set[str]) -> DayKeys:
    """Day keys over every date on which any of ``services`` runs.

    Only ``services`` count — the ones with trips in what is being generated — so an
    exception on some bus route the output does not include cannot split a key.
    """
    relevant = {sid: days for sid, days in dates.items() if sid in services and days}
    if not relevant:
        raise SystemExit("no service dates for the selected trips")
    first = min(min(days) for days in relevant.values())
    last = max(max(days) for days in relevant.values())
    active: dict[dt.date, set[str]] = defaultdict(set)
    for sid, days in relevant.items():
        for day in days:
            active[day].add(sid)

    sets: list[frozenset] = []
    index: dict[frozenset, int] = {}
    keys: list[int] = []
    day = first
    while day <= last:
        ids = frozenset(active.get(day, ()))
        if ids not in index:
            index[ids] = len(sets)
            sets.append(ids)
        keys.append(index[ids])
        day += dt.timedelta(days=1)

    weekday_default: list[int] = []
    for weekday in range(7):
        counts: dict[int, list[dt.date]] = defaultdict(list)
        for i, key in enumerate(keys):
            when = first + dt.timedelta(days=i)
            if when.weekday() == weekday and sets[key]:
                counts[key].append(when)
        if not counts:
            raise SystemExit(f"feed {first}..{last} has no service on {DAY_TYPES[weekday]}")
        weekday_default.append(max(counts, key=lambda k: (len(counts[k]), max(counts[k]))))
    return DayKeys(first, keys, sets, weekday_default)


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
    # day key -> sorted trip start times, seconds after midnight
    starts: dict[int, list[int]] = field(default_factory=lambda: defaultdict(list))
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

    fare = read_fares(feed)

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

    all_service_dates = service_dates(feed)
    used_services = {trip_index[t]["service_id"] for t in sequences}
    keys = day_keys(all_service_dates, used_services)
    service_keys = {sid: keys.keys_of_service(sid) for sid in used_services}

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
    dropped_stops = 0
    dropped_trips = 0
    checked_trips: list[tuple[str, str, str, int]] = []

    for trip_id, rows in sequences.items():
        rows.sort(key=lambda r: r[0])
        trip = trip_index[trip_id]
        service_id = trip["service_id"]
        trip_keys = service_keys.get(service_id) or []
        if not trip_keys:
            # The service has no date at all once calendar_dates removals apply.
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
            dropped_trips += 1
            continue
        checked_trips.append((trip["route_id"], trip["direction_id"], service_id, origin_departure))

        # Bucket by end-to-end running time so genuinely different speeds stay
        # separate (a peak express run vs. a slow one) while jitter collapses.
        bucket = arrivals[-1] // RUNTIME_VARIANT_TOLERANCE
        group = (trip["route_id"], trip["direction_id"], tuple(station_ids), bucket, tuple(flags))
        raw_groups[group].append((tuple(arrivals), tuple(dwells), exact, len(station_ids)))
        group_trips[group].append((origin_departure, trip_keys, trip.get("trip_headsign", "").strip()))

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
        for origin_departure, trip_keys, _ in group_trips[group]:
            for day_key in trip_keys:
                pattern.starts[day_key].append(origin_departure)
        pattern.trip_count = len(group_trips[group])
        patterns[key.as_tuple()] = pattern

    for pattern in patterns.values():
        for label in list(pattern.starts):
            pattern.starts[label] = sorted(set(pattern.starts[label]))

    # Check the emitted timetable against the feed for every date in the window:
    # for each date, each route and direction's trip starts as the day keys say,
    # against the trips whose service the raw calendar puts on that date. Built from
    # the patterns on one side and straight from trips.txt on the other, so a slip in
    # the key bookkeeping (or in the pattern grouping) shows up here.
    calendar_mismatches, calendar_checked = verify_against_calendar(
        keys, all_service_dates, list(patterns.values()), checked_trips)
    runtime_spread.sort(reverse=True)

    return {
        "routes": routes,
        "directions": directions,
        "fare": fare,
        "direction_words": direction_words,
        "patterns": list(patterns.values()),
        "stations": stations,
        "unsnapped_surface_stops": unsnapped,
        "surface_snaps": snap_report,
        "dropped_stop_times": dropped_stops,
        "route_ids": route_ids,
        "runtime_spread": runtime_spread[:6],
        "feed_info": feed.table("feed_info.txt")[0],
        "advisory_end": keys.end.strftime("%Y%m%d"),
        "day_keys": keys,
        "calendar_mismatches": calendar_mismatches,
        "skipped_no_service": skipped_no_service,
        "dropped_trips": dropped_trips,
        "calendar_checked": calendar_checked,
    }


def verify_against_calendar(
    keys: DayKeys,
    dates: dict[str, set[dt.date]],
    patterns: list["Pattern"],
    trips: list[tuple[str, str, str, int]],
) -> tuple[list[tuple[str, str, int]], dict[str, list[int]]]:
    """Compare, for every date in the window, what the output says runs with the feed.

    Returns the mismatches as (date, "route direction", departures differing), and
    per weekday [dates checked, departures compared]. The expected side is built
    from ``trips`` (route, direction, service, start) and the raw service dates; the
    actual side from the patterns' per-key start lists and the date → key table.
    """
    from collections import Counter
    expected_by_date: dict[dt.date, Counter] = defaultdict(Counter)
    for route_id, direction_id, service_id, start in trips:
        for day in dates.get(service_id, ()):
            expected_by_date[day][(route_id, direction_id, start)] += 1
    # The output keeps each pattern's starts as a set, so compare sets of
    # (route, direction, start) plus how many distinct patterns carry each.
    by_key: dict[int, Counter] = defaultdict(Counter)
    for pattern in patterns:
        for key, starts in pattern.starts.items():
            for start in starts:
                by_key[key][(pattern.key.route_id, pattern.key.direction_id, start)] += 1
    mismatches: list[tuple[str, str, int]] = []
    checked: dict[str, list[int]] = {label: [0, 0] for label in DAY_TYPES}
    day = keys.start
    while day <= keys.end:
        expected = set(expected_by_date.get(day, Counter()))
        actual = set(by_key.get(keys.key(day), Counter()))
        stats = checked[DAY_TYPES[day.weekday()]]
        stats[0] += 1
        stats[1] += len(expected)
        differing: Counter = Counter()
        for route_id, direction_id, _ in expected ^ actual:
            differing[f"{route_id} {direction_id}"] += 1
        for route, count in differing.items():
            mismatches.append((day.isoformat(), route, count))
        day += dt.timedelta(days=1)
    mismatches.sort(key=lambda m: -m[2])
    return mismatches, checked


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
    normalized = normalized_stop_name(stop_name)
    if normalized in STATION_ID_OVERRIDES:
        return STATION_ID_OVERRIDES[normalized]
    display = STATION_DISPLAY_NAMES.get(normalized, (normalized, None))[0]
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
        # members[0] decides the name, subtitle and intersection, so it must not
        # depend on the order the feed happened to yield stops in — otherwise two
        # runs over the same feed produce different output, and a regeneration
        # cannot be checked for being the no-op it should be.
        members.sort(key=lambda m: m["stop_id"])
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
                "sort": SORT_UNKNOWN,
            }
            # Newer feeds leave route_sort_order empty, which would sort every line
            # 9999 and scramble the pickers, so fall back to SEPTA's own order.
            order = int(route.get("route_sort_order") or 0) or SORT_FALLBACK.get(line_id, SORT_UNKNOWN)
            line_rows[line_id]["sort"] = min(line_rows[line_id]["sort"], order)

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
        encode_field(data["advisory_end"]),
    ]))
    # The service calendar: which day key each date of the window runs, then the
    # key standing in for each weekday outside it. Before any pattern, so the
    # decoder knows the keys when it meets them.
    keys: DayKeys = data["day_keys"]
    records.append("|".join(["C", keys.start.strftime("%Y%m%d"), ",".join(map(str, keys.keys))]))
    records.append("|".join(["W", ",".join(map(str, keys.weekday_default))]))
    for line in sorted(line_rows.values(), key=lambda l: (l["sort"], l["badge"])):
        records.append("|".join(["L", encode_field(line["id"]), encode_field(line["badge"]),
                                 encode_field(line["name"]), encode_field(line["color"]),
                                 str(line["sort"])]))
    fare = data["fare"]
    if fare["amount"]:
        records.append("|".join([
            "F", f"{fare['amount']:.2f}", encode_field(fare["currency"]),
            str(fare["transfer_window"]), str(fare["included_transfers"]),
            encode_field(",".join(fare["free_transfer_media"])),
            encode_field(",".join(fare["per_boarding_media"])),
        ]))

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

        # One D record per distinct timetable, listing every day key that runs it.
        by_timetable: dict[tuple[int, ...], list[int]] = {}
        for key in sorted(pattern.starts):
            starts = pattern.starts[key]
            if starts:
                by_timetable.setdefault(tuple(starts), []).append(key)
        for starts, key_list in by_timetable.items():
            records.append(f"D|{','.join(map(str, key_list))}|{encode_blocks(list(starts))}")
        # What the tests count: the week a reader sees through the weekday keys.
        for key in keys.weekday_default:
            total_departures += len(pattern.starts.get(key) or [])

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
    add("// Timetables are date-exact: every date from "
        f"{keys.start.isoformat()} to {keys.end.isoformat()} maps to a day key (a")
    add(f"// distinct set of SEPTA service IDs; {len(keys.sets)} in this feed), and each pattern")
    add("// lists its start times per day key. Outside that window a date falls back to")
    add("// the key that covers the most dates of its weekday:")
    for weekday, key in enumerate(keys.weekday_default):
        add(f"//   {DAY_TYPES[weekday]}: key {key} ({len(keys.dates_of_key(key))} dates)")
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
    print(f"feed {info['feed_version']}  valid {info['feed_start_date']}–{info['feed_end_date']}"
          f"  (advisory service data through {data['advisory_end']})")
    keys: DayKeys = data["day_keys"]
    print(f"service dates {keys.start}..{keys.end}: {len(keys.keys)} dates, {len(keys.sets)} day keys")
    print("weekday fallback keys (outside the window): "
          + ", ".join(f"{DAY_TYPES[d][:3]} {k}" for d, k in enumerate(keys.weekday_default)))
    print(f"stations: {len(stations)}   patterns: {len(data['patterns'])}")
    print(f"trips skipped: {data['skipped_no_service']} with no service date, "
          f"{data['dropped_trips']} with fewer than two stations")
    mismatches = data["calendar_mismatches"]
    print("calendar check, every date against the feed:")
    print(f"  {'weekday':<10} {'dates':>5} {'departures':>11} {'mismatches':>10}")
    for label in DAY_TYPES:
        dates_checked, departures = data["calendar_checked"][label]
        bad = sum(m[2] for m in mismatches
                  if DAY_TYPES[dt.date.fromisoformat(m[0]).weekday()] == label)
        print(f"  {label:<10} {dates_checked:>5} {departures:>11} {bad:>10}")
    if mismatches:
        print(f"calendar: {len(mismatches)} route-days across {len({m[0] for m in mismatches})} dates DIFFER from the feed")
        for date, route, count in mismatches[:10]:
            print(f"     {date}  {route}  {count} departures differ")
    else:
        print("calendar: every date in the window matches the feed exactly")
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
            counts = {DAY_TYPES[d][:3]: len(pattern.starts.get(k) or [])
                      for d, k in enumerate(keys.weekday_default)}
            print(f"  {direction} {len(ids):2d} stops  {pattern.key.offsets[-1] / 60:6.2f} min  {counts}")
            print(f"     {ids[0]} → {ids[-1]}")
            if len(ids) <= 12:
                print(f"     {' · '.join(ids)}")
        print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path, help="local gtfs_public.zip instead of downloading")
    parser.add_argument("--refresh", action="store_true",
                        help="download the feed again even if a cached copy exists")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", action="store_true", help="print a summary and do not write Swift")
    parser.add_argument("--json", type=Path, help="also dump the extracted data as JSON")
    parser.add_argument("--scope", choices=sorted(SCOPES), default="metro",
                        help="which routes to include (default: the whole Metro rail map)")
    args = parser.parse_args()

    feed_path = args.feed
    if feed_path is None:
        feed_path = CACHE_DIR / "gtfs_public.zip"
        # A cached copy is reused forever otherwise, which is exactly how a stale
        # timetable gets regenerated without anyone noticing it is stale.
        if args.refresh or not feed_path.exists() or not zipfile.is_zipfile(feed_path):
            download_feed(feed_path)
        else:
            print(f"using cached {feed_path}", file=sys.stderr)

    feed = Feed(feed_path)
    data = extract(feed, args.scope)

    if args.json:
        args.json.write_text(json.dumps({
            "feed_info": data["feed_info"],
            "day_keys": {"start": data["day_keys"].start.isoformat(), "keys": data["day_keys"].keys},
            "stations": data["stations"],
        }, indent=2))

    report(data)

    if args.report:
        return 1 if data["calendar_mismatches"] else 0
    if data["calendar_mismatches"]:
        raise SystemExit("refusing to write a timetable that disagrees with the feed's calendar")

    source = emit_swift(data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)
    print(f"wrote {args.output} ({len(source):,} bytes, {source.count(chr(10)):,} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
