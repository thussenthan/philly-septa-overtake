#!/usr/bin/env python3
"""Generate the bundled all-of-SEPTA timetable: buses, trolleys, Metro and Regional Rail.

This is the supplemental planner's data, separate from ``build_schedule.py``'s
Metro-only Swift literals. The whole network is far too big for Swift literals
(the compiler would take minutes), so it is written as a compact text resource,
``SEPTACommute/Resources/SEPTAExtended.txt``, which ``ExtendedNetwork.decode`` reads
at runtime. The service-calendar logic — the date → day-key table, times past
24:00 — is imported from ``build_schedule.py`` so both generators agree on what
runs on a given date.

Usage
-----
    python3 tools/build_extended.py                  # download (cached), then generate
    python3 tools/build_extended.py --feed path.zip  # use a local gtfs_public.zip
    python3 tools/build_extended.py --refresh        # download again

File format (UTF-8, one record per line, fields separated by TAB)
-----------------------------------------------------------------
    SEPTAEXT 2
    M  bus_version  rail_version  valid_from  valid_until  bus_until  rail_until
         bus_until / rail_until: the last date each feed has service for;
         valid_from / valid_until: the dates both feeds cover
    K  feed  first_date  keys  weekday_keys              feed: bus|rail; one per feed, before any P
         keys:         the day key of each date from first_date (yyyymmdd) on, comma-separated;
                       a day key is one distinct set of the feed's service IDs
         weekday_keys: seven keys, Monday first, standing in for dates outside the table
    B  amount  transfer_window_s  free_transfers         bus/trolley/Metro fare, SEPTA Key
    R  short  long  mode  color                          mode: bus|trolley|metro|rail
    S  name  lat  lon  [fare_class]                      index = order; fare_class on rail stops only
    C  label  is_center_city                             Regional Rail fare class (order = index)
    X  weekday_cents,...  weekend_cents,...              one row per *from* class, one value per *to* class
    H  points                                            route geometry (order = index)
         points:  lat,lon pairs in 1e-5 degrees, the first pair absolute, then each
                  pair as deltas from the previous one; simplified to ~8 m
    P  route  headsign  direction  stops  offsets  flags  [shape  segments  [early]]
         stops:    stop indices, first absolute, then deltas from the previous one
         offsets:  arrival seconds from trip start, as deltas from the previous stop (first is 0)
         flags:    "" or "pos:bits,..." with bit 1 = no pickup, bit 2 = no drop-off
         shape:    index of the H record the pattern runs along; empty when none fits
         segments: per stop, the shape segment it lies on (segment i runs from point i
                   to point i + 1), first absolute, then deltas; never decreasing, so a
                   ride from stop a to stop b is drawn through points seg[a]+1 ... seg[b]
         early:    "" or "pos:seconds,..." — how much sooner than ``offsets`` the fastest
                   trip of the pattern reaches that stop (only where >= EARLY_MIN_S);
                   the planner boards at offset − early. Shape and segments are
                   written empty when there is no shape but there is an early list.
    G  keys                                              a set of day keys, comma-separated (order = index)
    T  group  starts                                     belongs to the preceding P
         group:  index of the G record listing the day keys (of the pattern's feed: rail
                 routes use the rail feed's) that run exactly these trips. Sets repeat
                 across thousands of patterns ("every ordinary weekday"), so they are
                 written once.
         starts: trip start times (seconds after service-day midnight, may exceed 86400),
                 first absolute, then deltas
"""

from __future__ import annotations

import argparse
import csv
import io
import math
import statistics
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_schedule as bs  # noqa: E402  (shared calendar logic)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "SEPTACommute" / "Resources" / "SEPTAExtended.txt"
CACHE_DIR = Path(__file__).resolve().parent / ".cache"

MODES = {"0": "trolley", "1": "metro", "2": "rail", "3": "bus", "11": "trolley"}

# Trips over the same stops are one pattern when their running times fall in the
# same bin. Bins are logarithmic: 6 % wide, so a 10-minute shuttle splits at about
# 36 s and an 80-minute suburban route at about 5 minutes. Buses run noticeably
# slower at rush hour, and timing every trip of a route by one median would be
# wrong by a quarter of an hour on a long route; exact keys, on the other hand,
# multiply the patterns tenfold for jitter of a few seconds.
RUNTIME_BIN = 1.06

# Route geometry. Shapes are simplified with Douglas-Peucker to this tolerance:
# invisible at street zoom and about a fifth of the points SEPTA publishes.
SHAPE_TOLERANCE_M = 8.0
# A shape is only used for a pattern when every stop lies this close to it (in
# order). Regional Rail stations sit beside the tracks, bus stops at the kerb.
SHAPE_MAX_STOP_M = 200.0
# Local equirectangular projection for distances (metres), as ExtendedNetwork uses.
REF_LAT, REF_LON = 39.5, -75.5
M_PER_DEG_LAT = 110_574.0
M_PER_DEG_LON = 111_320.0 * math.cos(math.radians(40.0))


class InnerFeed:
    """A GTFS feed nested inside SEPTA's release zip, duck-typed for build_schedule."""

    def __init__(self, data: bytes):
        self.zip = zipfile.ZipFile(io.BytesIO(data))
        self._cache: dict[str, list[dict]] = {}

    def has(self, name: str) -> bool:
        return name in self.zip.namelist()

    def rows(self, name: str):
        with self.zip.open(name) as raw:
            yield from csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig"))

    def raw_rows(self, name: str):
        with self.zip.open(name) as raw:
            reader = csv.reader(io.TextIOWrapper(raw, encoding="utf-8-sig"))
            header = next(reader)
            yield {h: i for i, h in enumerate(header)}
            yield from reader

    def table(self, name: str) -> list[dict]:
        if name not in self._cache:
            self._cache[name] = list(self.rows(name)) if self.has(name) else []
        return self._cache[name]


def open_feeds(path: Path) -> tuple[InnerFeed, InnerFeed]:
    outer = zipfile.ZipFile(path)
    names = outer.namelist()
    for inner in ("google_bus.zip", "google_rail.zip"):
        if inner not in names:
            raise SystemExit(f"{path} does not contain {inner} (found {names})")
    return InnerFeed(outer.read("google_bus.zip")), InnerFeed(outer.read("google_rail.zip"))


# --------------------------------------------------------------------------
# Trips → patterns
# --------------------------------------------------------------------------

def extract_feed(feed: InnerFeed, prefix: str, stats: dict) -> dict:
    """Routes, stops and timed patterns of one feed, keyed by prefixed stop id."""
    routes = {r["route_id"]: r for r in feed.table("routes.txt")}

    direction_words: dict[tuple[str, str], str] = {}
    for row in feed.table("directions.txt"):
        word = (row.get("direction") or "").strip()
        direction_words[(row["route_id"], row["direction_id"])] = word

    all_dates = bs.service_dates(feed)
    candidates = [t for t in feed.table("trips.txt") if t["route_id"] in routes and all_dates.get(t["service_id"])]
    keys = bs.day_keys(all_dates, {t["service_id"] for t in candidates})
    service_keys = {sid: tuple(keys.keys_of_service(sid)) for sid in {t["service_id"] for t in candidates}}
    trip_days: dict[str, tuple[int, ...]] = {}
    trips: dict[str, dict] = {}
    for t in candidates:
        trips[t["trip_id"]] = t
        trip_days[t["trip_id"]] = service_keys[t["service_id"]]
    stats[prefix + "trips"] = len(trips)
    stats[prefix + "service_dates"] = f"{keys.start}..{keys.end}, {len(keys.sets)} day keys"

    rows = feed.raw_rows("stop_times.txt")
    col = next(rows)
    i_trip, i_arr, i_dep = col["trip_id"], col["arrival_time"], col["departure_time"]
    i_stop, i_seq = col["stop_id"], col["stop_sequence"]
    i_pu, i_do = col.get("pickup_type"), col.get("drop_off_type")
    sequences: dict[str, list] = defaultdict(list)
    for r in rows:
        tid = r[i_trip]
        if tid not in trips:
            continue
        flags = 0
        if i_pu is not None and r[i_pu] == "1":
            flags |= 1
        if i_do is not None and r[i_do] == "1":
            flags |= 2
        arr = r[i_arr] or r[i_dep]
        dep = r[i_dep] or r[i_arr]
        sequences[tid].append((int(r[i_seq]), prefix + r[i_stop], bs.parse_gtfs_time(arr),
                               bs.parse_gtfs_time(dep), flags))

    groups: dict[tuple, list] = defaultdict(list)
    for tid, seq in sequences.items():
        seq.sort()
        if len(seq) < 2:
            continue
        t = trips[tid]
        start = seq[0][3]
        stops = tuple(s[1] for s in seq)
        offsets = [s[2] - start for s in seq]
        offsets[0] = 0
        # Trip ends: boarding at the last stop and alighting at the first make no
        # sense whatever the feed says; clear them so they don't split patterns.
        flags = [s[4] for s in seq]
        flags[0] &= ~2
        flags[-1] &= ~1
        runtime = max(offsets[-1], 1)
        bin_ = int(math.log(runtime) / math.log(RUNTIME_BIN))
        key = (t["route_id"], t.get("direction_id", ""), stops, tuple(flags), bin_)
        groups[key].append((start, offsets, trip_days[tid], (t.get("trip_headsign") or "").strip(),
                            t.get("shape_id") or ""))

    patterns = []
    for (route_id, direction_id, stops, flags, _), members in groups.items():
        columns = list(zip(*[m[1] for m in members]))
        offsets = [int(statistics.median(c)) for c in columns]
        # Medians of each column can break monotonicity by a second or two.
        for i in range(1, len(offsets)):
            offsets[i] = max(offsets[i], offsets[i - 1])
        # How much earlier than the median the fastest trip of the group reaches each
        # stop. Boarding uses median − early, so a rider is never told to turn up
        # after a fast trip has already gone.
        early = [max(0, offsets[i] - min(c)) for i, c in enumerate(columns)]
        starts = defaultdict(set)
        for start, _, days, _, _ in members:
            for d in days:
                starts[d].add(start)
        headsigns = defaultdict(int)
        for m in members:
            headsigns[m[3]] += 1
        headsign = max(headsigns.items(), key=lambda kv: (kv[1], kv[0]))[0]
        patterns.append({
            "route": prefix + route_id,
            "rail_feed": prefix == "R",
            "headsign": headsign,
            "direction": direction_words.get((route_id, direction_id), ""),
            "stops": stops,
            "offsets": offsets,
            "early": early,
            "flags": flags,
            "starts": {d: sorted(v) for d, v in starts.items()},
            # Candidate shapes, most used first.
            "shapes": [prefix + sid for sid, _ in Counter(m[4] for m in members if m[4]).most_common()],
        })

    stops = {}
    for s in feed.table("stops.txt"):
        stops[prefix + s["stop_id"]] = s
    return {
        "routes": {prefix + k: v for k, v in routes.items()},
        "stops": stops,
        "patterns": patterns,
        "feed_info": feed.table("feed_info.txt")[0],
        "day_keys": keys,
        "shapes": read_shapes(feed, prefix, {sid for p in patterns for sid in p["shapes"]}),
    }


# --------------------------------------------------------------------------
# Shapes
# --------------------------------------------------------------------------

def read_shapes(feed: InnerFeed, prefix: str, wanted: set[str]) -> dict[str, list[tuple[int, int]]]:
    """Wanted shapes as simplified point lists in integer 1e-5 degrees."""
    if not feed.has("shapes.txt"):
        return {}
    rows = feed.raw_rows("shapes.txt")
    col = next(rows)
    i_id, i_lat, i_lon, i_seq = col["shape_id"], col["shape_pt_lat"], col["shape_pt_lon"], col["shape_pt_sequence"]
    raw: dict[str, list] = defaultdict(list)
    for r in rows:
        sid = prefix + r[i_id]
        if sid in wanted:
            raw[sid].append((int(r[i_seq]), float(r[i_lat]), float(r[i_lon])))
    shapes = {}
    for sid, pts in raw.items():
        pts.sort()
        points: list[tuple[int, int]] = []
        for _, lat, lon in pts:
            q = (round(lat * 1e5), round(lon * 1e5))
            if not points or points[-1] != q:
                points.append(q)
        if len(points) >= 2:
            shapes[sid] = simplify(points, SHAPE_TOLERANCE_M)
    return shapes


def project(points) -> np.ndarray:
    """(n, 2) metres on the local projection; points in 1e-5 degrees (lat, lon)."""
    a = np.asarray(points, dtype=np.float64) * 1e-5
    return np.column_stack(((a[:, 1] - REF_LON) * M_PER_DEG_LON, (a[:, 0] - REF_LAT) * M_PER_DEG_LAT))


def simplify(points: list[tuple[int, int]], tolerance: float) -> list[tuple[int, int]]:
    """Douglas-Peucker, iterative; keeps the first and last point."""
    n = len(points)
    if n <= 2:
        return points
    xy = project(points)
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        seg = xy[b] - xy[a]
        rel = xy[a + 1:b] - xy[a]
        length2 = float(seg @ seg)
        if length2 == 0:
            d = np.hypot(rel[:, 0], rel[:, 1])
        else:
            t = np.clip((rel @ seg) / length2, 0, 1)
            d = np.hypot(rel[:, 0] - t * seg[0], rel[:, 1] - t * seg[1])
        k = int(np.argmax(d))
        if d[k] > tolerance:
            m = a + 1 + k
            keep[m] = True
            stack.append((a, m))
            stack.append((m, b))
    return [p for p, k in zip(points, keep) if k]


def stop_segments(shape_xy: np.ndarray, stop_xy: np.ndarray) -> tuple[list[int], float]:
    """Monotone projection of stops onto a shape's segments.

    Chooses for each stop a segment index, never decreasing along the pattern,
    minimising the summed stop-to-segment distance (a small dynamic programme, so
    a route that loops back past an earlier stop doesn't pull it out of order).
    Returns the indices and the worst stop-to-segment distance in metres.
    """
    a = shape_xy[:-1]
    seg = shape_xy[1:] - a
    length2 = np.maximum((seg * seg).sum(axis=1), 1e-9)
    # (stops, segments) distances.
    rel = stop_xy[:, None, :] - a[None, :, :]
    t = np.clip((rel * seg[None, :, :]).sum(axis=2) / length2[None, :], 0, 1)
    dx = rel[:, :, 0] - t * seg[None, :, 0]
    dy = rel[:, :, 1] - t * seg[None, :, 1]
    dist = np.hypot(dx, dy)
    s_count, m = dist.shape
    positions = np.arange(m)
    cost = dist[0].copy()
    back = np.zeros((s_count, m), dtype=np.int64)
    for k in range(1, s_count):
        running = np.minimum.accumulate(cost)
        # back[k, j] = argmin of cost[0..j]: the last prefix-minimum at or before j.
        back[k] = np.maximum.accumulate(np.where(cost <= running, positions, 0))
        cost = dist[k] + running
    j = int(np.argmin(cost))
    worst = 0.0
    chosen = [0] * s_count
    for k in range(s_count - 1, -1, -1):
        chosen[k] = j
        worst = max(worst, float(dist[k, j]))
        if k:
            j = int(back[k, j])
    return chosen, worst


def attach_shapes(patterns: list[dict], shapes: dict[str, list], stop_points: dict[str, tuple[float, float]],
                  stats: dict) -> None:
    """Sets each pattern's "shape" (shape id or None) and "segments"."""
    projected = {sid: project(pts) for sid, pts in shapes.items()}
    cache: dict[tuple, tuple] = {}
    fitted = unfitted = 0
    for p in patterns:
        p["shape"], p["segments"] = None, None
        stop_xy = project([stop_points[s] for s in p["stops"]])
        best = None
        for sid in p["shapes"][:3]:
            if sid not in projected:
                continue
            key = (sid, p["stops"])
            if key not in cache:
                cache[key] = stop_segments(projected[sid], stop_xy)
            segments, worst = cache[key]
            if worst <= SHAPE_MAX_STOP_M and (best is None or worst < best[2]):
                best = (sid, segments, worst)
        if best:
            p["shape"], p["segments"] = best[0], best[1]
            fitted += 1
        else:
            unfitted += 1
    stats["patterns_with_shape"] = fitted
    stats["patterns_without_shape"] = unfitted


# --------------------------------------------------------------------------
# Regional Rail fares
# --------------------------------------------------------------------------

def rail_fares(feed: InnerFeed, prefix: str):
    """Fare in cents between every pair of rail stops, weekday and weekend, SEPTA Key.

    Evaluated the way GTFS-Fares v2 says: the matching fare_leg_rule with the
    highest rule_priority wins. A trip between two lines (no single rule matches)
    is priced as two legs through Center City joined by the fare_transfer_rule
    that replaces them with one product (the "extended trip"). Then stops with
    the same set of areas are folded into one class, which is what is written.
    """
    areas = defaultdict(set)
    for row in feed.table("stop_areas.txt"):
        areas[row["stop_id"]].add(row["area_id"])
    media_ok = ("septa_key", "contactless")
    price = {}
    for row in feed.table("fare_products.txt"):
        if row["fare_media_id"] in media_ok:
            cents = round(float(row["amount"]) * 100)
            pid = row["fare_product_id"]
            price[pid] = min(price.get(pid, cents), cents)
    rules = feed.table("fare_leg_rules.txt")
    transfers = {
        (r["from_leg_group_id"], r["to_leg_group_id"]): r.get("fare_product_id", "")
        for r in feed.table("fare_transfer_rules.txt")
    }
    local = price.get("product_local_trip") or min(price.values())

    def match(a_areas, b_areas, tf):
        best = None
        for r in rules:
            if r["from_area_id"] and r["from_area_id"] not in a_areas:
                continue
            if r["to_area_id"] and r["to_area_id"] not in b_areas:
                continue
            ft = r.get("from_timeframe_group_id") or ""
            if ft and ft != tf:
                continue
            if r["fare_product_id"] not in price:
                continue
            prio = int(r.get("rule_priority") or 0)
            if best is None or prio > best[0]:
                best = (prio, r)
        return best[1] if best else None

    def fare(A, B, tf):
        r = match(A, B, tf)
        if r:
            return price[r["fare_product_id"]]
        cc = {"area_CC"}
        if "area_CC" in A and "area_CC" in B:
            return local  # within Center City: no rule; the cheapest trip
        r1, r2 = match(A, cc, tf), match(cc, B, tf)
        if r1 and r2:
            pid = transfers.get((r1["leg_group_id"], r2["leg_group_id"]))
            if pid and pid in price:
                return price[pid]
            return price[r1["fare_product_id"]] + price[r2["fare_product_id"]]
        return local

    # Rules only ever name areas, so stops in the same set of areas are priced alike.
    zones = ("area_CC", "area_Z1", "area_Z2", "area_Z3", "area_Z4", "area_NJ", "area_airport_terminals")
    class_keys: list[frozenset] = []
    stop_class = {}
    for s in sorted(feed.table("stops.txt"), key=lambda s: s["stop_id"]):
        key = frozenset(areas[s["stop_id"]])
        if key not in class_keys:
            class_keys.append(key)
        stop_class[prefix + s["stop_id"]] = class_keys.index(key)
    class_rows = []
    for A in class_keys:
        label = "/".join(sorted(z.replace("area_", "") for z in A if z in zones)) or "?"
        lines_ = "+".join(sorted(z.replace("area_", "") for z in A if z not in zones))
        class_rows.append({
            "label": label + (" " + lines_ if lines_ else ""),
            "cc": "area_CC" in A,
            "weekday": [fare(A, B, "weekday") for B in class_keys],
            "weekend": [fare(A, B, "weekend") for B in class_keys],
        })
    return stop_class, class_rows


def bus_fare(feed: InnerFeed):
    f = bs.read_fares(feed)
    return f["amount"], f["transfer_window"], f["included_transfers"]


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def clean(text: str) -> str:
    return " ".join((text or "").replace("\t", " ").split())


def deltas(values) -> str:
    out, prev = [], 0
    for i, v in enumerate(values):
        out.append(str(v if i == 0 else v - prev))
        prev = v
    return ",".join(out)


# Stops must lie in this box (SEPTA's five counties with a wide margin). The app's
# decoder rejects anything outside it, so the generator refuses to write it.
LAT_RANGE = (38.5, 41.0)
LON_RANGE = (-76.5, -74.0)

# Early-boarding corrections under a minute are left out: the boarding margin and
# transfer slack absorb most of that, and the file stays smaller (+0.45 MB in all).
EARLY_MIN_S = 60


def build(feed_path: Path) -> tuple[str, dict]:
    bus_feed, rail_feed = open_feeds(feed_path)
    stats: dict = {}
    bus = extract_feed(bus_feed, "", stats)
    rail = extract_feed(rail_feed, "R", stats)
    stop_class, fare_classes = rail_fares(rail_feed, "R")
    amount, window, free = bus_fare(bus_feed)

    routes = {**bus["routes"], **rail["routes"]}
    stops = {**bus["stops"], **rail["stops"]}
    patterns = bus["patterns"] + rail["patterns"]
    stop_points = {
        sid: (round(float(s["stop_lat"]) * 1e5), round(float(s["stop_lon"]) * 1e5))
        for sid, s in stops.items() if s.get("stop_lat") and s.get("stop_lon")
    }
    attach_shapes(patterns, {**bus["shapes"], **rail["shapes"]}, stop_points, stats)

    def sort_key(rid):
        r = routes[rid]
        order = r.get("route_sort_order") or ""
        mode_rank = {"metro": 0, "trolley": 1, "rail": 2, "bus": 3}[MODES.get(r["route_type"], "bus")]
        return (mode_rank, int(order) if order.isdigit() else bs.SORT_UNKNOWN, r["route_short_name"] or rid)

    used_routes = sorted({p["route"] for p in patterns}, key=sort_key)
    # The decoder tells a pattern's feed — so which day keys apply — by its mode:
    # Regional Rail is the rail feed, everything else the bus feed.
    for p in patterns:
        is_rail = MODES.get(routes[p["route"]]["route_type"], "bus") == "rail"
        if is_rail != p["rail_feed"]:
            raise SystemExit(f"route {p['route']} is mode {'rail' if is_rail else 'non-rail'} "
                             f"but comes from the {'rail' if p['rail_feed'] else 'bus'} feed")
    route_index = {rid: i for i, rid in enumerate(used_routes)}
    # Longest patterns first within a route, so the first appearance order of stops
    # follows the line and stop deltas come out as 1 most of the time.
    patterns.sort(key=lambda p: (route_index[p["route"]], -len(p["stops"]), p["direction"], p["headsign"]))

    stop_index: dict[str, int] = {}
    for p in patterns:
        for s in p["stops"]:
            if s not in stop_index:
                stop_index[s] = len(stop_index)

    fi_bus, fi_rail = bus["feed_info"], rail["feed_info"]
    # The windows are the dates each feed actually has service for — calendar.txt
    # and calendar_dates.txt — not feed_info's: SEPTA's rail feed_info stops at the
    # end of its "authoritative" fortnight while its calendar runs three months on,
    # and taking feed_info at its word dropped rail from every plan after it.
    bus_keys, rail_keys = bus["day_keys"], rail["day_keys"]
    ymd = lambda d: d.strftime("%Y%m%d")
    lines = ["SEPTAEXT\t2"]
    lines.append("\t".join([
        "M", fi_bus.get("feed_version", ""), fi_rail.get("feed_version", ""),
        ymd(max(bus_keys.start, rail_keys.start)), ymd(min(bus_keys.end, rail_keys.end)),
        ymd(bus_keys.end), ymd(rail_keys.end),
    ]))
    for name, keys in (("bus", bus_keys), ("rail", rail_keys)):
        lines.append("\t".join(["K", name, ymd(keys.start), ",".join(map(str, keys.keys)),
                                 ",".join(map(str, keys.weekday_default))]))
    lines.append(f"B\t{amount:.2f}\t{window}\t{free}")
    for rid in used_routes:
        r = routes[rid]
        lines.append("\t".join([
            "R", clean(r["route_short_name"] or rid), clean(r["route_long_name"]),
            MODES.get(r["route_type"], "bus"), (r.get("route_color") or "").upper(),
        ]))
    missing = [sid for sid in stop_index if stops.get(sid) is None]
    if missing:
        raise SystemExit(f"{len(missing)} stops used by trips are missing from stops.txt: {missing[:10]}")
    for sid, _ in sorted(stop_index.items(), key=lambda kv: kv[1]):
        s = stops[sid]
        try:
            lat, lon = float(s["stop_lat"]), float(s["stop_lon"])
        except (KeyError, TypeError, ValueError):
            raise SystemExit(f"stop {sid} ({s.get('stop_name')!r}) has no usable coordinates")
        if not (LAT_RANGE[0] <= lat <= LAT_RANGE[1] and LON_RANGE[0] <= lon <= LON_RANGE[1]):
            raise SystemExit(f"stop {sid} ({s.get('stop_name')!r}) at {lat}, {lon} is outside the SEPTA region")
        fields = ["S", clean(s["stop_name"]), f"{lat:.5f}", f"{lon:.5f}"]
        if sid in stop_class:
            fields.append(str(stop_class[sid]))
        lines.append("\t".join(fields))
    for c in fare_classes:
        lines.append(f"C\t{c['label']}\t{1 if c['cc'] else 0}")
    for c in fare_classes:
        lines.append("X\t" + ",".join(map(str, c["weekday"])) + "\t" + ",".join(map(str, c["weekend"])))

    # Shapes, deduplicated by their simplified points, in first-use order.
    all_shapes = {**bus["shapes"], **rail["shapes"]}
    shape_index: dict[tuple, int] = {}
    shape_of_id: dict[str, int] = {}
    shape_points = 0
    for p in patterns:
        sid = p["shape"]
        if sid is None or sid in shape_of_id:
            continue
        pts = tuple(all_shapes[sid])
        if pts not in shape_index:
            shape_index[pts] = len(shape_index)
            flat = []
            prev = (0, 0)
            for q in pts:
                flat.append(f"{q[0] - prev[0]},{q[1] - prev[1]}")
                prev = q
            lines.append("H\t" + ",".join(flat))
            shape_points += len(pts)
        shape_of_id[sid] = shape_index[pts]

    # Day-key sets, written once and referred to by index from the T records.
    timetables: list[list[tuple[tuple, tuple[int, ...]]]] = []
    group_index: dict[tuple[int, ...], int] = {}
    for p in patterns:
        by_list: dict[tuple, list[int]] = defaultdict(list)
        for key, starts in p["starts"].items():
            by_list[tuple(starts)].append(key)
        rows = sorted(((starts, tuple(sorted(keys))) for starts, keys in by_list.items()), key=lambda r: r[1][0])
        timetables.append(rows)
        for _, keys in rows:
            group_index.setdefault(keys, len(group_index))
    for keys in group_index:
        lines.append("G\t" + ",".join(map(str, keys)))

    trip_count = 0
    for p, rows in zip(patterns, timetables):
        idx = [stop_index[s] for s in p["stops"]]
        flag_text = ",".join(f"{i}:{f}" for i, f in enumerate(p["flags"]) if f)
        fields = [
            "P", str(route_index[p["route"]]), clean(p["headsign"]), clean(p["direction"]),
            deltas(idx), deltas(p["offsets"]), flag_text,
        ]
        early_text = ",".join(f"{i}:{e}" for i, e in enumerate(p["early"]) if e >= EARLY_MIN_S)
        if p["shape"] is not None:
            fields += [str(shape_of_id[p["shape"]]), deltas(p["segments"])]
        elif early_text:
            fields += ["", ""]
        if early_text:
            fields.append(early_text)
        lines.append("\t".join(fields))
        for starts, keys in rows:
            lines.append(f"T\t{group_index[keys]}\t{deltas(starts)}")
        week = (rail_keys if p["rail_feed"] else bus_keys).weekday_default
        trip_count += sum(len(p["starts"].get(key, ())) for key in week)

    stats.update({
        "routes": len(used_routes),
        "stops": len(stop_index),
        "patterns": len(patterns),
        "trip_departures_per_week": trip_count,
        "fare_classes": len(fare_classes),
        "early_boarding_corrections": sum(1 for p in patterns for e in p["early"] if e >= EARLY_MIN_S),
        "shapes": len(shape_index),
        "shape_points": shape_points,
    })
    return "\n".join(lines) + "\n", stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--feed", type=Path, help="local gtfs_public.zip instead of downloading")
    parser.add_argument("--refresh", action="store_true", help="download the feed again")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    feed_path = args.feed
    if feed_path is None:
        feed_path = CACHE_DIR / "gtfs_public.zip"
        if args.refresh or not feed_path.exists() or not zipfile.is_zipfile(feed_path):
            bs.download_feed(feed_path)
        else:
            print(f"using cached {feed_path}", file=sys.stderr)

    text, stats = build(feed_path)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    for k, v in stats.items():
        print(f"  {k}: {v}", file=sys.stderr)
    print(f"wrote {args.output} ({len(text.encode()):,} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
