# SEPTA Commute

An iOS app that answers one question about SEPTA: **do I board the train that's
about to leave, or wait for the faster one?**

SEPTA runs several services over the same tracks. The Broad Street Line alone has
the B1 local, the B2 express that skips fourteen of its twenty-two stations, and
the B3 Broad-Ridge Spur that also runs fast on Broad St before branching to
Chinatown. Which one gets you to your door soonest depends on where you're
standing, where you're going, what time it is, and how far you're willing to walk
at the far end. That answer changes minute by minute, and it is not what the
platform sign tells you.

Set it up once, and after that opening the app *is* the interaction — it guesses
where you're going from where you're standing (within a mile of home means you're
heading out; anywhere else means you're heading home) and the answer is already on
screen. You can override it whenever you like.

Coverage is the whole SEPTA Metro rail map: the **B** Broad Street Line, **L**
Market-Frankford, **M** Norristown High Speed, **T1–T5** subway-surface trolleys,
**G** Girard, **D** Media-Sharon Hill, the trackless trolleys, and the B1 Owl
night bus — 585 stations, 309 stopping patterns.

So the app works it out door-to-door, and shows you the tradeoff instead of just a
single answer:

- **Every option you can still catch.** If the walk to the station is longer than
  the time until the train leaves, it isn't listed.
- **How long you have.** A live countdown to the last moment you can set off and
  still make it — including the walk and a safety margin you can adjust.
- **What waiting costs you.** "Local now, or express in 9 minutes and arrive 4
  minutes sooner."
- **The half-and-half trick.** Board the local, hop off where the express stops,
  and let it overtake you. Often the fastest way out of a station the express skips.
- **Riding past your stop.** The express doesn't stop at Fairmount. Getting off at
  Girard and walking two blocks sometimes still wins — the app compares that
  against staying on the local.
- **Both ends on foot.** Walking time is part of the trip, not an afterthought, so
  "faster train" never silently means "longer journey".

<!-- Add a screenshot here once you've run it on a device. -->

## What's on screen

The home screen is deliberately the smallest thing that answers the question:

```
 Erie  →  Home
 ┌──────────────────────────────────┐
 │ (B)                              │
 │ Local now, switch to the express │
 │ at Girard                        │
 │ Leave in 4:12          5:42      │
 │                        arrive    │
 │ Go now — miss this and you       │
 │ lose 11 min                      │
 └──────────────────────────────────┘
 (B)  Straight through on the B
      +6 min arrival · leave in 12 min
 (B)(L) B to City Hall, change to the L
      +9 min arrival · leave in 15 min
 All 5 options                        ›
 Delays on the B · 1 note             ›
```

Everything on it is a tap: the two ends open their pickers, the card and the rows
open the step-by-step itinerary, and the bottom row opens SEPTA's alert text, the
planner's caveats and where the timetable came from. Stop counts, walking
distances, skipped stations and total trip time are all real information and all
reasons to read instead of decide, so none of them are on the first screen.

## Getting started

Requires **Xcode 16 or newer** and **iOS 17+**. There are no third-party
dependencies and nothing to install.

```sh
open SEPTACommute.xcodeproj
```

Pick a simulator and run. On first launch the app asks for a **Home** and a
**Work / School** address — it ships with no addresses in it, and they're stored
only in this device's `UserDefaults`.

To run the engine's tests without a simulator:

```sh
swift test
```

## What it knows, and what it doesn't

The bundled timetable is generated from **SEPTA's official GTFS feed**, so
departure times are the real published ones rather than estimates:

| | |
|---|---|
| Source | `github.com/septadev/GTFS` → `gtfs_public.zip` → `google_bus.zip` |
| Feed version | `v202607261` (valid 2026-07-26 → 2026-08-08) |
| Coverage | 16 rail routes across 9 Metro lines, plus the B1 Owl night bus |
| Stations | 585 |
| Stopping patterns | 309 |

**These are scheduled times, not live train positions.** SEPTA publishes
GTFS-Realtime feeds, but at the time of writing there is no confirmed real-time feed
covering the subway specifically — see [Wiring up real-time](#wiring-up-real-time)
below.

What the app *does* read is SEPTA's [service alerts
API](https://www3.septa.org/api/Alerts/index.php) — plain JSON, no key, no
dependency. An option whose lines have a notice on them is flagged by name
("Delays on the B") and SEPTA's own words appear on its detail screen. Alerts are
shown, never interpreted: alert text is prose, and a planner that acted on
"expect residual delays" would be inventing a timetable. The last good response is
cached for a day, so opening the app underground still shows this morning's
notices.

SEPTA's feed only declares about two weeks of validity, so the bundled data ages
out. `DataProvenance.validUntil` carries the expiry date and the app tells you when
it has passed. To refresh:

```sh
python3 tools/build_schedule.py     # downloads the current feed and regenerates
```

That rewrites `SEPTACommute/MetroKit/Data/GeneratedSEPTAData.swift`, a
generated file of Swift literals — no bundle resources, no runtime parsing, and the
compiler checks the shape. Use `--report` to see what changed without writing
anything.

A few things the generator gets right that are easy to get wrong, and which the
tests now lock in:

- **The express terminates at Walnut-Locust and never enters South Philadelphia.**
  The feed's `route_stops.txt` lists NRG for the B2, but no regular trip serves it.
  Patterns are derived from `trips.txt` + `stop_times.txt` instead.
- **Special-event trips are excluded.** SEPTA adds express trips to NRG whenever
  there's a game at the sports complex. They're real, but they run on a handful of
  named dates, and taken at face value they'd tell a rider on an ordinary Sunday
  that Sunday express service exists. Services covering fewer than three dates are
  dropped, which catches them all without needing to know what the event was.
- **Platform suffixes are merged.** Express and local use separate tracks at Olney
  and City Hall, and the feed names them `Olney Transit Center - B1` and
  `... - B2 & B3`. Left alone, the express platform would be a different *station*
  from the local one and the planner would never find the cross-platform change
  that most of this app is about.
- **Owl bus stops are snapped onto stations.** Overnight the trains stop and SEPTA
  runs a surface bus along Broad St with its own curbside stop IDs. Each is matched
  to the station it sits outside, so a 3 AM trip routes onto the bus instead of
  reporting no service.
- **Station IDs are derived from names, not feed IDs.** SEPTA renumbers `stop_id`s
  between releases; `erie` stays `erie`.

## How it's put together

```
SEPTACommute/
├── MetroKit/          the routing engine — pure Foundation, no UIKit, no CoreLocation
│   ├── Model/         stations, patterns, the network graph
│   ├── Schedule/      service calendar, timetable, trip generation
│   ├── Routing/       the planner, journeys, walking model, prose
│   ├── Alerts/        SEPTA's alert feed: model and decoding, no networking
│   └── Data/          GeneratedSEPTAData.swift  ← regenerate, don't edit
└── App/               SwiftUI, CoreLocation, MapKit
    ├── Model/         saved places, preferences, the view model
    ├── Services/      location, walking directions, address search, alert fetching
    └── Views/
Tests/MetroKitTests/   run with `swift test`
tools/build_schedule.py
```

`MetroKit` is deliberately free of Apple-framework dependencies so the planner can
be tested from the command line, and `Package.swift` exposes it as a library target
for exactly that. **The app target does not `import MetroKit`** — Xcode's
synchronized group compiles those sources straight into the app module, so they're
already in scope. If you ever split them into separate modules, that's when the
imports need adding.

### The routing algorithm

The search is exhaustive rather than heuristic. A door-to-door plan over the Broad
Street Line measures at about 13 ms (`testPlanningIsFastEnoughToRunOnEveryLocationUpdate`),
and in exchange the interesting strategies fall out on their own instead of being
special-cased. Nothing tells the planner to look for an overtake — it enumerates walk → ride → (change → ride)* →
walk and scores each by when the rider reaches the door.

*Describing* those routes is a different job, and it does need an explicit check.
An itinerary is only called an overtake when the timetable says one happened: the
train the rider steps **off** must also serve their destination, and must get there
**later** than the train they step **onto**. Both conditions matter. Without the
first, every branch connection looks like an overtake; without the second, so does
every change onto a slower train. Inferring it from shape instead — same line, same
direction, one change — mislabels three of the five multi-train itineraries on this
line, because "express to Girard, then the local" is structurally identical to a
real overtake and overtakes nothing. The check also can't be "did the faster train
leave your boarding station later", because the express usually doesn't stop there
at all — which is precisely why the rider is on the local.

1. **Access and egress candidates.** The nearest few stations to each end, not just
   the closest one. This is what makes "walk three extra minutes to a station the
   express actually serves" and "ride past your stop and walk back" possible at all.
2. **Depth-first enumeration** over concrete scheduled trips, up to two changes,
   pruned against the best arrival found so far.
3. **Feasibility.** A journey is only produced if the rider can physically reach the
   platform before the train leaves. `leaveBy` — the number the countdown shows — is
   the boarding time minus the walk minus the safety margin.
4. **Collapse.** Riding the same two trains between the same two places is one
   option, not one per station where the change happens to be possible. Changes are
   only considered at stations served by more than one route; anywhere else, every
   train goes the same way and getting off can only lose time.
5. **Pareto filter** on arrival time, number of changes, walking time, and how late
   you can leave. An option is hidden only when another is at least as good on all
   four. That fourth axis is why a slower train sometimes still appears — it may let
   you leave ten minutes later.

That last axis needs a wide indifference band, and finding out why was worth the
trouble: at 30 seconds, "ride two stops the wrong way and double back" survived the
filter purely because it bought 90 seconds of extra slack while arriving seven
minutes later. It's two minutes now, and there's a regression test named after the
behaviour.

### Walking times

Walks are estimated from straight-line distance × 1.25 for the street grid, plus
fixed overheads for getting out of a building and down to a platform. Those
overheads are the difference between "the station is 300 m away" and "you missed
the train."

When there's a connection, the app measures the handful of walks that matter with
MapKit walking directions and hands the real numbers back to the planner, which
reorders the options if they disagree. The estimate is the offline fallback, not a
stub — turn measured walks off in Settings and everything still works with no signal.

## Tests

`swift test` covers the engine and the shipped data:

- The **express-versus-local decision** in both directions: the local is dropped
  when the express both leaves later and arrives sooner (no tradeoff to present),
  and both are shown when catching the express means leaving *sooner*.
- The **half-and-half case**, asserting the planner finds it and describes it as
  "Local now, switch to the express at C".
- **Overtake verification**, both ways round: local-to-express at Olney is a real
  overtake with a measured saving, while every change onto a train that simply goes
  further is not one and must not be described as one.
- **Feasibility**: no offered train has already left, and no plan asks for a walk
  that finishes after its train departs.
- **Contiguity**: every journey's legs form one unbroken chain in time.
- **The real timetable**: 24 stations ordered north to south, the express weekday-only
  and terminating at Walnut-Locust, the Spur serving Fairmount but not City Hall,
  Saturday having no express, 2:30 AM routing onto the Owl bus.
- **Regressions**: no pointless backtracking, no duplicate itineraries.
- **Alert decoding**, against a fixture copied from a live response with its
  inconsistencies intact — `isadvisory` really is `"Yes"`/`"No"` while every
  neighbouring flag is `"Y"`/`"N"`, and the subway lines really are filed under
  `rr_route_*` next to Regional Rail. Covered: routes the app can't plan over are
  dropped, every mapped line exists in the bundled data, HTML and entities are
  decoded rather than merely stripped, a suspension with no message still produces
  one, a renamed or retyped key costs that one field instead of the whole feed, and
  the card's single alert is the worst one on the journey.
- **Edge cases in time**: after-midnight trips belonging to the previous service
  day, and scheduled times holding steady across a daylight-saving transition.

The planner fixtures use a synthetic six-station line with times chosen by hand, so
those assertions don't move when SEPTA changes its timetable. The data assertions
deliberately do — that's the point of them.

## The whole Metro map

The Metro rail map is the default scope, and the planner routes across it with **no
changes to the routing code**. Regenerating narrower coverage is a flag:

```sh
python3 tools/build_schedule.py --scope broad    # Broad Street Line only
```

The reason cross-line routing needed no new code is a happy accident of the feed:
the lines meet at stations that *already share a name*. `15th St/City Hall` is
served by B1, B2, L1 and all five trolleys; `69th St Transit Center` by L1, M1, D1
and D2; `13th St` and `30th St` by L1 and the trolleys. Because station identity is
derived from the name, those merge into single stations and the interchanges exist
for free. Stations that sit on top of each other under *different* names are merged
by proximity instead — that is what makes `40th St` on the L and `40th-Market` on
the trolleys, 13 m apart, one station rather than a missing interchange.

Making it the default was a performance problem, not a correctness one. The search
leaned on two linear scans, both inside the innermost loop:

- `Schedule.startTimes(on:)` expanded every `.frequency` band into a freshly
  allocated, freshly sorted array **on every lookup** — thousands of times per
  plan. Schedules now resolve once at init and departures are found by binary
  search.
- `ServicePattern.stopIndex(of:)` walked up to 62 stops. It is a dictionary built
  at init.

Service days are resolved once per plan rather than per lookup (`Calendar`
arithmetic is far too slow for that loop), and changes of train are only considered
at the 69 stations served by more than one route — at a mid-line stop every train
goes the same way and the next one is later than the one you are on, so getting off
can only lose time. Measured in the cross-check harness (Python, so read these as
ratios rather than absolutes):

| Query | Before | After |
|---|---|---|
| Erie → near Fairmount | 2,300 ms | 233 ms |
| Erie → 69th St | 3,500 ms | 285 ms |
| Erie → 34th & Spruce | 4,400 ms | 366 ms |
| Penn Med → Erie | 41,000 ms | 4,400 ms |
| Temple → 40th St | 1,400 ms | 92 ms |

Every routing stayed identical. The binary search was checked against the linear
scan over 12,000 random (pattern, station, instant) samples on both scopes — that
turned up a real trap: **loop routes visit the same station twice** (28 such stops
on the Metro map), so the index has to resolve to the *first* visit or every
departure computed for those stations is wrong by the length of the loop. There is
a test for it.

Planning also runs off the main actor, with a newer request superseding an
in-flight one, so a slow plan can't stutter the UI or land stale after a fresh one.

What `--report` still shows as imperfect, at the current feed:

- **234 of 7,163 trips are dropped** because their service isn't in effect on any of
  the seven sampled dates, and 83 more are special-event trips excluded on purpose.
  The sampled dates are the *last* occurrence of each weekday in the feed window,
  because the feed carries more than one timetable revision and sampling the first
  week generates a superseded schedule.
- **One surface stop doesn't snap to a station.** 131 Owl-bus stop-times are dropped
  for having no station within 350 m; all of them are `Broad St & Spring Garden St`,
  which has no rail station outside it.

Buses (131 routes) and Regional Rail (a separate feed) are out of scope. Buses in
particular would need a different search strategy, not just a faster one.

## Wiring up real-time

The pieces are in place if you want to add it. `Timetable` is the only thing that
turns patterns into concrete departures, so a real-time source slots in behind it
without touching the planner. Two things to establish first:

1. Whether SEPTA's GTFS-Realtime `TripUpdates` feed carries `route_id` values `B1`,
   `B2`, `B3`. Static GTFS bundles the Metro lines inside the *bus* feed, so the bus
   RT feed plausibly includes them — but the published resource names only mention
   bus and Regional Rail, and this hasn't been confirmed.
2. Whether subway vehicles report position at all. `TransitView` is documented as
   bus and trolley only, which suggests you'd get arrival predictions but no vehicle
   coordinates.

The documented `www3.septa.org/api/` endpoints (`Arrivals`, `TrainView`,
`NextToArrive`, `RRSchedules`) are **Regional Rail only** and will not help here.

## Privacy

There is no account, no analytics, and no server. Addresses and preferences live in
`UserDefaults` on the device. The only network calls the app makes are Apple's own
address search and walking directions, and only when you're typing an address or
have measured walk times switched on.

## Data licence

Schedule data is SEPTA's, used under their
[developer licence](https://www.septa.org/license-agreement/). Regenerating it is
a download away; it isn't committed as a feed, only as derived Swift.
