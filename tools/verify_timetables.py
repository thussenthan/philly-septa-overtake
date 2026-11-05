#!/usr/bin/env python3
"""Check the bundled timetables against SEPTA's GTFS, date by date.

Reads the two generated files the way the app does — ``GeneratedSEPTAData.swift``
(Metro planner) and ``SEPTAExtended.txt`` (all of SEPTA) — and, for every date in
each feed's service window, compares the departures they give with the trips the
raw GTFS calendar (calendar.txt + calendar_dates.txt) runs on that date. It shares
no code with the generators, so a slip in their bookkeeping cannot hide here.

Compared per date, as multisets:
  Metro:          (route, direction, trip start)
  bus / rail:     (route, trip start, number of stops)

Usage
-----
    python3 tools/verify_timetables.py --feed gtfs_public.zip
    python3 tools/verify_timetables.py --feed gtfs_public.zip --metro OLD.swift --extended OLD.txt

Exits non-zero on any mismatch. Files in the older weekday-sampled formats are
understood too (weekday timetables, federal holidays → Sunday, and for the
extended file each mode cut off after its feed's end date, as the app did), so
the same check measures how far the old approach was off.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import re
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
METRO = REPO / "SEPTACommute" / "MetroKit" / "Data" / "GeneratedSEPTAData.swift"
EXTENDED = REPO / "SEPTACommute" / "Resources" / "SEPTAExtended.txt"
DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


# --------------------------------------------------------------------------
# GTFS, read independently of the generators
# --------------------------------------------------------------------------

def ymd(value: str) -> dt.date:
    return dt.date(int(value[:4]), int(value[4:6]), int(value[6:8]))


def seconds(value: str) -> int:
    h, m, s = value.strip().split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


class Gtfs:
    def __init__(self, data: bytes):
        self.zip = zipfile.ZipFile(io.BytesIO(data))

    def rows(self, name: str):
        with self.zip.open(name) as raw:
            yield from csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig"))

    def dates(self) -> dict[str, set[dt.date]]:
        out: dict[str, set[dt.date]] = defaultdict(set)
        for r in self.rows("calendar.txt"):
            day, end = ymd(r["start_date"]), ymd(r["end_date"])
            while day <= end:
                if r[DAYS[day.weekday()]] == "1":
                    out[r["service_id"]].add(day)
                day += dt.timedelta(days=1)
        for r in self.rows("calendar_dates.txt"):
            if r["exception_type"] == "1":
                out[r["service_id"]].add(ymd(r["date"]))
            else:
                out[r["service_id"]].discard(ymd(r["date"]))
        return out

    def trips(self, routes: set[str] | None):
        """(route_id, short name, direction_id, service_id, start, stop count, signature) per trip.

        The signature is the trip's whole stop list with times: two trips with the
        same one are the same departure for a rider (SEPTA schedules a few doubled
        buses — route 478 runs two vehicles at 15:24), and a timetable lists it once.
        """
        route_rows = {r["route_id"]: r for r in self.rows("routes.txt")}
        trips = {t["trip_id"]: t for t in self.rows("trips.txt")
                 if routes is None or t["route_id"] in routes}
        first: dict[str, tuple[int, int]] = {}
        count: Counter = Counter()
        stops: dict[str, list] = defaultdict(list)
        with self.zip.open("stop_times.txt") as raw:
            reader = csv.reader(io.TextIOWrapper(raw, encoding="utf-8-sig"))
            header = next(reader)
            i_trip, i_seq = header.index("trip_id"), header.index("stop_sequence")
            i_dep, i_arr = header.index("departure_time"), header.index("arrival_time")
            i_stop = header.index("stop_id")
            for row in reader:
                tid = row[i_trip]
                if tid not in trips:
                    continue
                count[tid] += 1
                seq = int(row[i_seq])
                stops[tid].append((seq, row[i_stop], row[i_arr], row[i_dep]))
                if tid not in first or seq < first[tid][0]:
                    first[tid] = (seq, seconds(row[i_dep] or row[i_arr]))
        for tid, t in trips.items():
            if count[tid] < 2:
                continue
            r = route_rows[t["route_id"]]
            short = " ".join((r.get("route_short_name") or t["route_id"]).replace("\t", " ").split())
            signature = (t["route_id"], tuple(sorted(stops[tid])))
            yield (t["route_id"], short, t.get("direction_id", ""), t["service_id"], first[tid][1], count[tid],
                   hash(signature))


# --------------------------------------------------------------------------
# The bundled files
# --------------------------------------------------------------------------

def expand(blocks: str) -> list[int]:
    out: list[int] = []
    for spec in blocks.split(";"):
        kind, _, rest = spec.partition(":")
        if kind == "f":
            a, b, step = map(int, rest.split(":"))
            out.extend(range(a, b + 1, step))
        elif kind == "t":
            out.extend(int(v) for v in rest.split(","))
    return sorted(set(out))


def undelta(text: str) -> list[int]:
    out, prev = [], 0
    for i, v in enumerate(text.split(",")):
        prev = int(v) if i == 0 else prev + int(v)
        out.append(prev)
    return out


HOLIDAY_SUNDAY = {(1, 1), (6, 19), (7, 4), (12, 25)}


def is_federal_holiday(d: dt.date) -> bool:
    """The rule the app used before its timetables were dated (HolidayCalendar)."""
    if (d.month, d.day) in HOLIDAY_SUNDAY:
        return True
    if d.month == 5 and d.weekday() == 0 and (d + dt.timedelta(days=7)).month != 5:
        return True
    if d.month == 9 and d.weekday() == 0 and d.day <= 7:
        return True
    return d.month == 11 and d.weekday() == 3 and 22 <= d.day <= 28


class Calendar:
    """date → key, either from a dated table or by weekday (old formats)."""

    def __init__(self, start: dt.date | None, keys: list[int], weekday: list[int]):
        self.start, self.keys, self.weekday = start, keys, weekday

    def key(self, d: dt.date):
        if self.start is not None:
            i = (d - self.start).days
            if 0 <= i < len(self.keys):
                return self.keys[i]
            return self.weekday[d.weekday()]
        return DAYS[6] if is_federal_holiday(d) else DAYS[d.weekday()]


def read_metro(path: Path):
    text = path.read_text()
    records = [line for chunk in re.findall(r'"""\n(.*?)\n"""', text, re.S) for line in chunk.split("\n")]
    calendar = Calendar(None, [], [])
    start, keys = None, []
    by_key: dict = defaultdict(Counter)
    route = direction = None
    for rec in records:
        f = rec.split("|")
        if f[0] == "C":
            start, keys = ymd(f[1]), [int(k) for k in f[2].split(",")]
        elif f[0] == "W":
            calendar = Calendar(start, keys, [int(k) for k in f[1].split(",")])
        elif f[0] == "P":
            route, direction = f[3], ("0" if f[5] == "southbound" else "1")
        elif f[0] == "D":
            for start_s in expand(f[2]):
                for k in f[1].split(","):
                    by_key[int(k) if k.isdigit() else k][(route, direction, start_s)] += 1
    return calendar, by_key


def read_extended(path: Path):
    lines = path.read_text().split("\n")
    version = int(lines[0].split("\t")[1])
    routes: list[tuple[str, str]] = []
    calendars: dict[str, Calendar] = {}
    groups: list[list[int]] = []
    by_key = {"bus": defaultdict(Counter), "rail": defaultdict(Counter)}
    meta = []
    feed = short = None
    stops = 0
    for line in lines[1:]:
        f = line.split("\t")
        tag = f[0]
        if tag == "M":
            meta = f
        elif tag == "R":
            routes.append((f[1], f[3]))
        elif tag == "K":
            calendars[f[1]] = Calendar(ymd(f[2]), [int(k) for k in f[3].split(",")],
                                       [int(k) for k in f[4].split(",")])
        elif tag == "G":
            groups.append([int(k) for k in f[1].split(",")])
        elif tag == "P":
            short, mode = routes[int(f[1])]
            feed = "rail" if mode == "rail" else "bus"
            stops = len(f[4].split(","))
        elif tag == "T":
            keys = groups[int(f[1])] if version >= 2 else [DAYS[int(c) - 1] for c in f[1]]
            for s in undelta(f[2]):
                for k in keys:
                    by_key[feed][k][(short, s, stops)] += 1
    if version < 2:
        calendars = {"bus": Calendar(None, [], []), "rail": Calendar(None, [], [])}
    ends = {"bus": ymd(meta[5]), "rail": ymd(meta[6])} if len(meta) > 6 else {}
    return calendars, by_key, ends


# --------------------------------------------------------------------------
# Comparison
# --------------------------------------------------------------------------

def compare(name: str, expected_by_date: dict[dt.date, Counter], calendar: Calendar, by_key,
            window: tuple[dt.date, dt.date], cutoff: dt.date | None = None) -> int:
    table = {d: [0, 0, 0] for d in DAYS}
    examples: list[str] = []
    day = window[0]
    while day <= window[1]:
        expected = expected_by_date.get(day, Counter())
        actual = Counter() if cutoff and day > cutoff else by_key.get(calendar.key(day), Counter())
        diff = (expected - actual) + (actual - expected)
        row = table[DAYS[day.weekday()]]
        row[0] += 1
        row[1] += sum(expected.values())
        row[2] += sum(diff.values())
        if diff and len(examples) < 6:
            missing, extra = expected - actual, actual - expected
            examples.append(f"    {day} ({DAYS[day.weekday()][:3]}): {sum(missing.values())} missing, "
                            f"{sum(extra.values())} extra, e.g. {sorted(missing or extra)[:2]}")
        day += dt.timedelta(days=1)
    print(f"\n{name}: {window[0]} .. {window[1]}")
    print(f"  {'day':<10} {'dates':>5} {'departures':>11} {'mismatched':>11}")
    total = [0, 0, 0]
    for d in DAYS:
        print(f"  {d:<10} {table[d][0]:>5} {table[d][1]:>11} {table[d][2]:>11}")
        total = [a + b for a, b in zip(total, table[d])]
    print(f"  {'all':<10} {total[0]:>5} {total[1]:>11} {total[2]:>11}")
    if expected_by_date.get("doubled"):
        print(f"  ({expected_by_date['doubled']} trip-dates duplicate another trip exactly — same stops, same "
              f"times — and count once)")
    for e in examples:
        print(e)
    return total[2]


def by_date(dates: dict[str, set[dt.date]], items) -> dict[dt.date, Counter]:
    """Expected departures per date; identical trips (same signature) on a date count once."""
    out: dict[dt.date, Counter] = defaultdict(Counter)
    seen: set[tuple[dt.date, int]] = set()
    doubled = 0
    for service_id, key, signature in items:
        for d in dates.get(service_id, ()):
            if (d, signature) in seen:
                doubled += 1
                continue
            seen.add((d, signature))
            out[d][key] += 1
    out["doubled"] = doubled  # type: ignore[index]
    return out


def window_of(dates: dict[str, set[dt.date]], services: set[str]) -> tuple[dt.date, dt.date]:
    days = [d for s in services for d in dates.get(s, ())]
    return min(days), max(days)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--feed", type=Path, required=True, help="SEPTA's gtfs_public.zip")
    parser.add_argument("--metro", type=Path, default=METRO)
    parser.add_argument("--extended", type=Path, default=EXTENDED)
    args = parser.parse_args()

    outer = zipfile.ZipFile(args.feed)
    bus, rail = Gtfs(outer.read("google_bus.zip")), Gtfs(outer.read("google_rail.zip"))
    bus_dates, rail_dates = bus.dates(), rail.dates()
    bad = 0

    calendar, metro = read_metro(args.metro)
    metro_routes = {route for counter in metro.values() for route, _, _ in counter}
    trips = list(bus.trips(None))
    picked = [(sid, (rid, d, s), sig) for rid, _, d, sid, s, _, sig in trips if rid in metro_routes]
    bad += compare("Metro planner (GeneratedSEPTAData.swift)", by_date(bus_dates, picked), calendar, metro,
                   window_of(bus_dates, {p[0] for p in picked}))

    calendars, extended, ends = read_extended(args.extended)
    picked = [(sid, (short, s, n), sig) for _, short, _, sid, s, n, sig in trips]
    bad += compare("Bus feed — bus, trolley, Metro (SEPTAExtended.txt)", by_date(bus_dates, picked),
                   calendars["bus"], extended["bus"], window_of(bus_dates, {p[0] for p in picked}),
                   ends.get("bus") if calendars["bus"].start is None else None)
    picked = [(sid, (short, s, n), sig) for _, short, _, sid, s, n, sig in rail.trips(None)]
    bad += compare("Regional Rail (SEPTAExtended.txt)", by_date(rail_dates, picked),
                   calendars["rail"], extended["rail"], window_of(rail_dates, {p[0] for p in picked}),
                   ends.get("rail") if calendars["rail"].start is None else None)

    print("\nOK: every date matches the feed" if bad == 0 else f"\nFAIL: {bad} departures differ")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
