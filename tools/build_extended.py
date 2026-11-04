#!/usr/bin/env python3
"""Generate the bundled all-of-SEPTA timetable: buses, trolleys, Metro and Regional Rail.

This is the supplemental planner's data, separate from ``build_schedule.py``'s
Metro-only Swift literals. The whole network is far too big for Swift literals
(the compiler would take minutes), so it is written as a compact text resource,
``SEPTACommute/Resources/SEPTAExtended.txt``, which ``ExtendedNetwork.decode`` reads
at runtime. The service-calendar logic — one representative date per weekday,
special-event services dropped, times past 24:00 — is imported from
``build_schedule.py`` so both generators agree on what "a Tuesday" means.

Usage
-----
    python3 tools/build_extended.py                  # download (cached), then generate
    python3 tools/build_extended.py --feed path.zip  # use a local gtfs_public.zip
    python3 tools/build_extended.py --refresh        # download again

File format (UTF-8, one record per line, fields separated by TAB)
-----------------------------------------------------------------
    SEPTAEXT 1
    M  bus_version  rail_version  valid_from  valid_until  bus_until  rail_until
    B  amount  transfer_window_s  free_transfers         bus/trolley/Metro fare, SEPTA Key
    R  short  long  mode  color                          mode: bus|trolley|metro|rail
    S  name  lat  lon  [fare_class]                      index = order; fare_class on rail stops only
    C  label  is_center_city                             Regional Rail fare class (order = index)
    X  weekday_cents,...  weekend_cents,...              one row per *from* class, one value per *to* class
    P  route  headsign  direction  stops  offsets  flags
         stops:   stop indices, first absolute, then deltas from the previous one
         offsets: arrival seconds from trip start, as deltas from the previous stop (first is 0)
         flags:   "" or "pos:bits,..." with bit 1 = no pickup, bit 2 = no drop-off
    T  days  starts                                      belongs to the preceding P
         days:   digits 1..7 = Monday..Sunday that run exactly these trips
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
from collections import defaultdict
from pathlib import Path

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

    all_dates, rare = bs.recurring_services(feed)
    rep = bs.representative_dates(feed, all_dates)
    services_by_day = {
        label: {sid for sid, days in all_dates.items() if day in days and sid not in rare}
        for label, day in rep.items()
    }
    trip_days: dict[str, tuple[int, ...]] = {}
    trips: dict[str, dict] = {}
    for t in feed.table("trips.txt"):
        days = tuple(i for i, label in enumerate(bs.DAY_TYPES) if t["service_id"] in services_by_day[label])
        if days and t["route_id"] in routes:
            trips[t["trip_id"]] = t
            trip_days[t["trip_id"]] = days
    stats[prefix + "trips"] = len(trips)
    stats[prefix + "dates"] = {k: v.isoformat() for k, v in rep.items()}

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
        groups[key].append((start, offsets, trip_days[tid], (t.get("trip_headsign") or "").strip()))

    patterns = []
    for (route_id, direction_id, stops, flags, _), members in groups.items():
        columns = zip(*[m[1] for m in members])
        offsets = [int(statistics.median(c)) for c in columns]
        # Medians of each column can break monotonicity by a second or two.
        for i in range(1, len(offsets)):
            offsets[i] = max(offsets[i], offsets[i - 1])
        starts = defaultdict(set)
        for start, _, days, _ in members:
            for d in days:
                starts[d].add(start)
        headsigns = defaultdict(int)
        for m in members:
            headsigns[m[3]] += 1
        headsign = max(headsigns.items(), key=lambda kv: (kv[1], kv[0]))[0]
        patterns.append({
            "route": prefix + route_id,
            "headsign": headsign,
            "direction": direction_words.get((route_id, direction_id), ""),
            "stops": stops,
            "offsets": offsets,
            "flags": flags,
            "starts": {d: sorted(v) for d, v in starts.items()},
        })

    stops = {}
    for s in feed.table("stops.txt"):
        stops[prefix + s["stop_id"]] = s
    return {
        "routes": {prefix + k: v for k, v in routes.items()},
        "stops": stops,
        "patterns": patterns,
        "feed_info": feed.table("feed_info.txt")[0],
    }


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

    def sort_key(rid):
        r = routes[rid]
        order = r.get("route_sort_order") or ""
        mode_rank = {"metro": 0, "trolley": 1, "rail": 2, "bus": 3}[MODES.get(r["route_type"], "bus")]
        return (mode_rank, int(order) if order.isdigit() else bs.SORT_UNKNOWN, r["route_short_name"] or rid)

    used_routes = sorted({p["route"] for p in patterns}, key=sort_key)
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
    lines = ["SEPTAEXT\t1"]
    lines.append("\t".join([
        "M", fi_bus.get("feed_version", ""), fi_rail.get("feed_version", ""),
        max(fi_bus["feed_start_date"], fi_rail["feed_start_date"]),
        min(fi_bus["feed_end_date"], fi_rail["feed_end_date"]),
        fi_bus["feed_end_date"], fi_rail["feed_end_date"],
    ]))
    lines.append(f"B\t{amount:.2f}\t{window}\t{free}")
    for rid in used_routes:
        r = routes[rid]
        lines.append("\t".join([
            "R", clean(r["route_short_name"] or rid), clean(r["route_long_name"]),
            MODES.get(r["route_type"], "bus"), (r.get("route_color") or "").upper(),
        ]))
    missing_stops = 0
    for sid, _ in sorted(stop_index.items(), key=lambda kv: kv[1]):
        s = stops.get(sid)
        if s is None:
            missing_stops += 1
            lines.append("S\t?\t0\t0")
            continue
        fields = ["S", clean(s["stop_name"]), f"{float(s['stop_lat']):.5f}", f"{float(s['stop_lon']):.5f}"]
        if sid in stop_class:
            fields.append(str(stop_class[sid]))
        lines.append("\t".join(fields))
    for c in fare_classes:
        lines.append(f"C\t{c['label']}\t{1 if c['cc'] else 0}")
    for c in fare_classes:
        lines.append("X\t" + ",".join(map(str, c["weekday"])) + "\t" + ",".join(map(str, c["weekend"])))

    trip_count = 0
    for p in patterns:
        idx = [stop_index[s] for s in p["stops"]]
        flag_text = ",".join(f"{i}:{f}" for i, f in enumerate(p["flags"]) if f)
        lines.append("\t".join([
            "P", str(route_index[p["route"]]), clean(p["headsign"]), clean(p["direction"]),
            deltas(idx), deltas(p["offsets"]), flag_text,
        ]))
        by_list: dict[tuple, list[int]] = defaultdict(list)
        for d, starts in p["starts"].items():
            by_list[tuple(starts)].append(d)
            trip_count += len(starts)
        for starts, days in sorted(by_list.items(), key=lambda kv: min(kv[1])):
            lines.append("T\t" + "".join(str(d + 1) for d in sorted(days)) + "\t" + deltas(starts))

    stats.update({
        "routes": len(used_routes),
        "stops": len(stop_index),
        "patterns": len(patterns),
        "trip_departures_per_week": trip_count,
        "fare_classes": len(fare_classes),
        "missing_stops": missing_stops,
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
