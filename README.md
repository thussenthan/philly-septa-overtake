# Overtake

An iOS app that answers one question about SEPTA: **do I board the train that's
about to leave, or wait for the faster one?**

It's named after the manoeuvre that makes the question interesting — get on the
local now, ride a few stops, and let the express catch you up.

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
 ┌────────────────────────────────────────┐
 │ Leave in 4:12                   5:42   │
 │                                 arrive │
 │ ────────────────────────────────────── │
 │ (B1) Southbound                  8:21  │
 │      toward NRG · off at Girard        │
 │      ● Erie                      8:21  │
 │      │ North Philadelphia        8:23  │
 │      ● Girard        get off     8:27  │
 │ (B2) Southbound · Express        8:29  │
 │      off at Walnut-Locust              │
 │      ● Girard                    8:29  │
 │      │ 4 more stops                    │
 │      ● Walnut-Locust get off     8:38  │
 │ ────────────────────────────────────── │
 │ Go now — miss this and you lose 11 min │
 └────────────────────────────────────────┘
 (B1) Straight through on the B
      +6 min arrival · leave in 12 min
 (B1)(L1) B to City Hall, change to the L
      +9 min arrival · leave in 15 min
 All 5 options                          ›
 LEAVING ERIE                    arrive
 (B2) Southbound · Express  4:07  8:29  │ ← the one recommended
      Walnut-Locust         8:04        │
 (B1) Southbound            9:12  8:41
      Walnut-Locust         8:09
 (B3) Southbound · Spur    14:40  8:52
      8th-Market            8:14
 Delays on the B · 1 note               ›
```

The recommendation gets the full width, and it carries the things you then have to
match against the station: **the route as the map writes it, not the line letter.**
At Erie the B1 and the B2 use different tracks and only one of them stops where
you're going, so a card saying "B" hands the last and most error-prone step back to
the rider. With it, the direction the signs use, the stopping pattern when that's the
point, the terminus painted on the train, and where to get off.

Under each leg is the stop strip: the stations between boarding and getting off,
drawn the way the map draws them. That is what a rider looks at once they're aboard —
how many more, and is the next one mine — and it's the honest way to use a card that
stretches to fill the screen. Rides longer than six stops are compressed in the
middle, because twenty station names is a wall of text and the two at either end are
the ones you watch for.

Each row carries only what the row above doesn't. The boarding station is the "from"
already at the top of the screen, or the station the previous row just put you off
at; the headsign is dropped when it repeats; and there are no stop counts, because
you get off at a named station rather than by counting.

**Directions come from SEPTA, not from arithmetic.** The feed ships a
`directions.txt` naming the two ends of every route, and it is the only thing that
agrees with the signs. Deriving the direction from coordinates was tried first and is
wrong twice over: it calls the Media-Sharon Hill routes east–west when SEPTA calls
them northbound and southbound, and `direction_id` 0 means southbound on route 59 but
northbound on route 66. There is a test asserting the published words for all sixteen
routes, and another asserting that D1's own geometry contradicts them.

Below it is the platform sign: every train leaving that station soon that can
actually get you where you're going, in departure order, with a live countdown and the
time it lands. It answers the question a rider asks *after* the recommendation —
what else is coming, and what does waiting cost me — and it is deliberately
**unfiltered**. The planner hides an option another beats outright, which is right for
a recommendation and wrong for a board: the slow train you're going to take anyway
because it's pulling in belongs on it. There's a test asserting the board keeps a train
the planner correctly drops.

It's also the honest way to use a screen with room to spare, which stretching the
recommendation into a taller box was not.

Everything else is a tap: the two ends open their pickers, the card and the rows
open the full itinerary with clock times and skipped stations, and the bottom row
opens SEPTA's alert text, the planner's caveats and where the timetable came from.

The name is drawn rather than typeset — each letter is a set of coloured lines with
white stops, in SEPTA's own palette, so the wordmark reads as a piece of the network
diagram. `Wordmark.swift` carries a complete A–Z, so renaming the app is a one-line
change to `AppIdentity.name`.

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
| Stopping patterns | 321 |

**These are scheduled times, not live train positions** — a limitation of this app,
not of SEPTA's data. Live positions for the whole Metro map do exist, including the
subways; see [Wiring up real-time](#wiring-up-real-time) below for what was measured
and what it would take.

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

### What of the feed is used

The feed is two zips, 39 files. What earns its place, and what doesn't:

| File | Used for |
|---|---|
| `trips.txt`, `stop_times.txt` | the patterns and every departure time |
| `stops.txt` | names, coordinates, `wheelchair_boarding` for step-free routing |
| `routes.txt` | line colours, and `route_sort_order` so lists read in SEPTA's own order |
| `calendar.txt` | which days each service runs |
| `directions.txt` | northbound/southbound/eastbound/westbound, per route |
| `feed_info.txt` | version and the validity window the app warns you about |
| `calendar_dates.txt` | service exceptions, which SEPTA hangs on nearly every date |
| `fare_*.txt`, `rider_categories.txt` | the fare, and whether a change of train is included |

Three columns are load-bearing and easy to miss:

- **`pickup_type` / `drop_off_type`.** 1,082 stop-times on the Metro map forbid
  boarding or alighting, and **every one of them is at a middle stop** — the
  convenient assumption that they only mark trip ends is false here. Without them the
  planner will tell you to get off at Baltimore Av & 49th St on a T2, where the doors
  don't open for that.
- **`timepoint`.** Every Broad Street Line stop time is a published timing point.
  On the trolleys it's about one in six; the rest are SEPTA interpolating between
  them. An app selling a countdown should know which it's holding, so each pattern
  carries the share and the Service & data screen says so when it's under half.
- **`route_sort_order`.** L, B, trolleys, Girard, Media-Sharon Hill, Norristown, then
  the trackless trolleys. Sorting by badge put route 59 at the top of the network.

**Fares.** SEPTA fills in GTFS-Fares v2 properly, so the app reads rather than
hardcodes: $2.90 adult full fare, and `fare_transfer_rules` rows carrying *no*
`fare_product_id` — which under transfer type 0 means the transfer adds nothing.
Free, within two hours, up to two of them, on SEPTA Key and contactless. Cash and
Quick Trip have no such rule, so with those every boarding is a new fare. That's the
one fare fact on this network that can change which option a rider picks, so it
appears on the card *only* on itineraries with a change — "$2.90 — the change is free
with SEPTA Key, $5.80 paying twice" — and the full rules are on the Service & data
screen. Single-ride trips don't mention money at all.

**Is the seven-day-type timetable exact?** SEPTA hangs a `calendar_dates` row on
nearly every date, so two Wednesdays can run different service IDs, and the generator
samples one date per weekday. That's an assumption worth checking rather than
believing, so `--report` now compares the emitted timetable against **every date in
the feed window**, per pattern. On the current feed it holds exactly:

```
calendar: the day-type timetable holds on every date in the feed window
```

The two revisions this feed carries differ only in service IDs, apart from three
Sunday B2 trips that the special-event filter already removes. A holiday, or a
timetable change mid-window, would not hold — and the check says so instead of
silently averaging one away. (The app's holiday fallback to a Sunday schedule stays,
because a two-week window contains no holiday to learn from.)

Deliberately unused, with the reason:

- **`pathways.txt` / `levels.txt`** would give real in-station walking times and stair
  counts — but only **2 of 846** pathways touch a Metro stop, and 6 of 964 stops have
  a level. It's a Regional Rail feature.
- **`parent_station`** is set on **31 of 964** Metro stops, so it can't replace the
  name-and-proximity station merging described below.
- **`stop_headsign`** is empty on every Metro stop time.
- **`route_stops.txt`** disagrees with the trips (see below).
- **`shapes.txt`** is 452,000 points of route geometry, for a map this app doesn't
  draw yet.

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
│   ├── Widget/        the shared snapshot and the widget's timeline logic
│   └── Data/          GeneratedSEPTAData.swift  ← regenerate, don't edit
└── App/               SwiftUI, CoreLocation, MapKit
    ├── Model/         saved places, preferences, the view model
    ├── Services/      location, walking directions, address search, alert fetching
    └── Views/
SEPTACommuteWidget/    WidgetKit extension — views only, no logic
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

The search is exhaustive rather than heuristic. A door-to-door plan across the whole
Metro map measures at about 31 ms on an Apple silicon Mac
(`testPlanningIsFastEnoughToRunOnEveryLocationUpdate`), and in exchange the
interesting strategies fall out on their own instead of being special-cased. Nothing tells the planner to look for an overtake — it enumerates walk → ride → (change → ride)* →
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
- **What the rider is told to look for**: every route in the bundled data produces
  a badge that appears somewhere in a station (`B2`, and `OWL` rather than the feed's
  `B1_OWL`); Broad St trips read southbound and northbound while Market-Frankford
  trips read eastbound and westbound, including the City Hall → Frankford ride that
  is literally more north than east; and a ride with no net movement is given no
  direction rather than a fabricated one.
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

## The widget

Small, medium, and a lock-screen rectangle: the line badges, a live countdown to the
last moment you can leave, and when you'd arrive.

It doesn't ask the app what the answer is. Widget extensions have no reliable
location fix, get throttled on the network, and are killed if they take too long —
but they have the same bundled timetable, which is enough to compute exact
departures for any moment. So the app writes only *which trip* to answer
(`CommuteSnapshot`: two endpoints and a name for each) into a shared App Group, and
the extension re-plans it for the moment it is being looked at.

The timeline is built from the answers rather than from a guessed refresh interval:
each entry begins at the exact instant the option the previous one recommended stops
being catchable. Between those instants nothing the widget could say changes, which
is why the countdown is a self-updating `Text(_:style:.timer)` instead of an entry
per minute. The widget states what missing the train *costs* ("Miss it: +12m") and
never tells you to run — whether to run depends on how much time is left, and an
entry rendered ten minutes after it was computed can't know that.

Both halves of the plumbing are in the project file rather than in a setup checklist,
because both are things Xcode's dialogs merely write and neither survives being
forgotten:

- **Sharing the code.** A second synchronized group points at `SEPTACommute/MetroKit`
  and is listed on the widget target. The extension needs the timetable, the planner
  and `CommuteSnapshot` — and ticking Target Membership on a *subfolder* of an existing
  synchronized group is the one case Xcode's UI handles badly.
- **Sharing the container.** `SEPTACommute.entitlements` and
  `SEPTACommuteWidget.entitlements` both declare `group.com.example.SEPTACommute`, and
  `CODE_SIGN_ENTITLEMENTS` names them in all four build configurations. They sit at the
  repository root rather than inside either target's folder, since both folders are
  synchronized groups and a stray `.entitlements` in one gets picked up as a resource
  to copy. Renaming means changing those two files and `SharedStore.appGroupID`.

A mismatch between the three names is silent: the app carries on against its own
defaults, the widget reads an empty store, and the only symptom is a widget insisting
your addresses aren't set when they are. So `SharedStore.isSharedContainerAvailable`
is checked, and the Service & data screen states the reason when the container is
missing.

On a **free Apple account** the App Groups entitlement isn't provisioned, so a device
build may fail to sign. The Simulator doesn't validate entitlements against a profile
and works regardless. Backing it out is deleting the two `CODE_SIGN_ENTITLEMENTS`
lines.

The template files Xcode generates for a Live Activity, a Control widget and a
configuration intent aren't used — delete `SEPTACommuteWidgetLiveActivity.swift`,
`SEPTACommuteWidgetControl.swift` and `AppIntent.swift` if your template created
them.

## Wiring up real-time

This section used to say there was no confirmed real-time feed for the subway, on the
strength of SEPTA's published resource names mentioning only bus and Regional Rail.
That was wrong, and one request settled it. `TransitViewAll` returns live vehicles for
**every Metro line**, subways included:

```
B1 11   B2 2   B3 2   L1 14   M1 4   T1 10   T2 8   T3 16   T4 9   T5 24
G1 21   D1 5   D2 4   59 4   66 9   75 2      (vehicles in motion, one sample)
```

Both GTFS-Realtime feeds respond too — `Trip/rtTripUpdates.pb` (540 KB) and
`Vehicle/rtVehiclePosition.pb` (48 KB).

But positions are not predictions, and the two are split by mode:

| | live position | delay / prediction |
|---|---|---|
| G Girard, T trolleys, D, M Norristown | yes | **yes** — `late` populated, −6 to +6 min |
| **B Broad St, L Market-Frankford** | yes | **no** — `late` is 998 on every vehicle, and `TripUpdates` omits them |

That second row was measured twice, with a control. Of 32 subway trips running live,
**0** appear in `TripUpdates`; of 819 bus and trolley trips running at the same moment,
**770** do. A 94% hit rate against 0% is not a sampling artifact.

So for the two subway lines SEPTA publishes where the trains are and nothing about
whether they are late — which means no app has live predictions for the B or the L,
and the schedule is the state of the art rather than a compromise. Where this app
genuinely loses is the trolleys, Girard and Norristown, where `late` is populated and
it ignores it.

The pieces are in place to close it. `Timetable` is the only thing that turns patterns
into concrete departures, so a real-time source slots in behind it without touching
the planner. Two routes in, with different costs:

- **`TransitViewAll`** is plain JSON, no key, no dependency — the same shape as the
  alerts feed this app already reads, and it carries a `trip` id that joins to a
  scheduled trip. For the T, G, D and M its `late` field is real, so this is the whole
  feature for those four lines. For the B and L it offers position only.
- **`TripUpdates`** carries predicted times per stop and would be the better source —
  except it excludes the subways, so it buys nothing on the lines this app is mostly
  used for. It is also protobuf, in a project with no dependencies by design.

The join has a prerequisite either way: **the bundled data discards `trip_id`.** The
generator collapses trips into 321 patterns and compresses departures into frequency
bands, so there is nothing for a live `trip` to attach to. Emitting ids per departure
breaks that compression and adds roughly 130 KB — affordable, but a change to the data
format rather than a bolt-on.

**Whatever is added, the schedule stays the base.** There is no signal on a Broad
Street platform, so live data has to be a correction applied to an answer that already
works offline, never a dependency the answer waits on.

A live map is now possible too — `VehiclePositions` for the trains and the
`shapes.txt` this generator skips for the lines. Worth being clear that it is the
lower-value half: a map is what the general-purpose apps already do well, whereas
"leave in 4:31" being a lie when the train is six minutes down is the thing that makes
this app wrong.

The documented `www3.septa.org/api/` endpoints `TrainView`, `Arrivals`,
`NextToArrive` and `RRSchedules` are Regional Rail only and will not help here —
`TransitViewAll` is the one that covers Metro.

## Privacy

There is no account, no analytics, and no server. Addresses and preferences live in
`UserDefaults` on the device. The only network calls the app makes are Apple's own
address search and walking directions, and only when you're typing an address or
have measured walk times switched on.

## Data licence

Schedule data is SEPTA's, used under their
[developer licence](https://www.septa.org/license-agreement/). Regenerating it is
a download away; it isn't committed as a feed, only as derived Swift.
