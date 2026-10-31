import SwiftUI
import UIKit
import WidgetKit

// The engine reaches this target one of two ways, depending on how the project is
// wired: as compiled-in sources (the MetroKit folder added to this target's
// membership), in which case there is no module to import — or as the local
// `MetroKit` package product, in which case there is. `canImport` covers both, so
// the choice is a project setting rather than an edit to this file.
#if canImport(MetroKit)
import MetroKit
#endif

/// The home-screen and lock-screen widget: when to leave, and when you land.
///
/// It plans from the bundled timetable, in the extension, for the moment it is being
/// looked at — no network call and no location fix, both of which a widget is bad at.
/// What it takes from the app is the rider's two addresses, their settings, and the
/// last place the app saw them — written to the shared App Group as soon as they exist.
/// Which way round to read the addresses follows the app's own rule: within a mile of
/// home means heading out, anywhere else means heading home, and only a fix too old to
/// trust sends it back to guessing from the clock. So it is right from the first
/// launch, without the app being opened to prime it, which is the whole point.
struct SEPTACommuteWidget: Widget {
    let kind = "SEPTACommuteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CommuteTimelineProvider()) { entry in
            CommuteWidgetRoot(entry: entry)
        }
        .configurationDisplayName("Next train")
        .description("When to leave for your commute — out in the morning, back in the afternoon.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryRectangular, .accessoryInline, .accessoryCircular,
        ])
    }
}

// MARK: - Timeline

/// Picks the palette, because only a view can ask what the phone's appearance is.
struct CommuteWidgetRoot: View {
    @Environment(\.colorScheme) private var systemScheme
    var entry: CommuteEntry

    var body: some View {
        let palette = WidgetPalette.resolve(setting: SharedStore.appearance(), system: systemScheme)
        CommuteWidgetView(entry: entry, palette: palette)
            .containerBackground(palette.background, for: .widget)
            // Forced rather than inherited: WidgetKit renders against the system
            // appearance, so without this a dark app sits next to a light widget.
            .environment(\.colorScheme, palette.colorScheme)
    }
}

struct CommuteEntry: TimelineEntry {
    var date: Date
    var step: WidgetPlanStep?
    var destinationName: String?
    /// Set when there is nothing to show, and why.
    var placeholder: String?
    /// What the rider can do about it, when there is something they can.
    var detail: String? = nil
    /// The countdown to draw, or nil once WidgetKit's live timer takes over. Decided
    /// when the timeline is built, because a widget cannot redraw itself: every value
    /// the number ever shows is an entry, and the switch to seconds is one of them.
    var countdown: String? = nil
}

struct CommuteTimelineProvider: TimelineProvider {

    /// What the widget gallery shows. A real-looking answer sells the widget; the
    /// "add your addresses" message is for a widget that is actually on a home screen.
    func placeholder(in context: Context) -> CommuteEntry {
        Self.sample(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        let now = Date()
        if context.isPreview {
            completion(Self.sample(at: now))
        } else {
            completion(entries(from: now).first ?? empty(at: now))
        }
    }

    static func sample(at now: Date) -> CommuteEntry {
        let step = WidgetPlanStep(
            validFrom: now,
            lines: [WidgetLineStyle(badge: "B2", colorHex: "F26100")],
            title: "Express toward NRG",
            platformDescription: "Southbound from Erie",
            boardName: "Erie",
            leaveBy: now.addingTimeInterval(7 * 60),
            arrival: now.addingTimeInterval(27 * 60),
            isWalkOnly: false,
            penaltyText: "Miss it: +6 min",
            nextArrival: now.addingTimeInterval(33 * 60)
        )
        return CommuteEntry(date: now, step: step, destinationName: "Home", placeholder: nil, countdown: "7 min")
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        let now = Date()
        let entries = self.entries(from: now)
        guard let last = entries.last else {
            // Nothing running, or no trip on file. Try again in half an hour rather
            // than hammering a question whose answer is "no".
            completion(Timeline(
                entries: [empty(at: now)],
                policy: .after(now.addingTimeInterval(30 * 60))
            ))
            return
        }
        let deadline = SharedStore.snapshot().map { expiry(for: $0, from: now) } ?? .distantFuture

        // The frame cap cut a long wait short, and the last frame is a held "N min"
        // that is only true for its own minute. Left alone it would sit there, going
        // stale, until the deadline — so reload when that minute is up.
        if last.countdown != nil {
            completion(Timeline(
                entries: entries,
                policy: .after(min(last.date.addingTimeInterval(60), deadline))
            ))
            return
        }

        // Otherwise the last frame runs a live timer to the deadline, and a live timer
        // *counts up* once it passes — a train that has gone would show "0:47" and
        // climbing until WidgetKit got round to reloading, which it does late. So the
        // timeline ends with an entry for the instant after, saying so, and the reload
        // is requested for when that entry arrives. The same applies where the rider
        // could have turned around first and the answer is stale before it is missed.
        let leaves = (last.step?.leaveBy ?? last.date).addingTimeInterval(1)
        let endsAt = max(min(leaves, deadline), last.date.addingTimeInterval(1))
        let closing = CommuteEntry(
            date: endsAt,
            step: nil,
            destinationName: last.destinationName,
            placeholder: "Updating…"
        )
        completion(Timeline(entries: entries + [closing], policy: .atEnd))
    }

    private func entries(from now: Date) -> [CommuteEntry] {
        guard let snapshot = SharedStore.snapshot() else { return [] }
        // One direction for the whole timeline, resolved once. Naming each entry for
        // its own moment would relabel the trip halfway down a plan that was worked
        // out for the other one, which is worse than being briefly out of date —
        // `expiry` is what keeps it from being out of date for long.
        let trip = snapshot.trip(at: now)
        let steps = WidgetPlanner.steps(for: snapshot, from: now)
        // One entry per minute the countdown shows, then one for the ticking stretch
        // at the end — the widget can't redraw itself, so every change is an entry.
        let horizon = expiry(for: snapshot, from: now)
        let frames = WidgetPlanner.frames(for: steps, from: now)
            .filter { $0.at < horizon }
        return frames.map { frame in
            CommuteEntry(
                date: frame.at,
                step: frame.step,
                destinationName: trip.destination.name,
                placeholder: nil,
                countdown: frame.countdown
            )
        }
    }

    /// The point past which this timeline could be answering the wrong direction.
    ///
    /// Entries are computed in advance and cannot be revised, so a timeline running
    /// past the moment the rider counts as facing the other way would sit there
    /// offering the trip they have already made. That moment is either the fix the
    /// direction rests on ageing out, or — when the clock is deciding — the turnaround.
    private func expiry(for snapshot: CommuteSnapshot, from now: Date) -> Date {
        let direction = snapshot.commute?.directionStableUntil(from: now)
        // Never sooner than a minute out: a timeline with nothing in it is a blank
        // widget, and a reload loop on top of one.
        return max(direction ?? .distantFuture, now.addingTimeInterval(60))
    }

    private func empty(at date: Date) -> CommuteEntry {
        let snapshot = SharedStore.snapshot()
        return CommuteEntry(
            date: date,
            step: nil,
            destinationName: snapshot?.trip(at: date).destination.name,
            // Two different problems, and a rider can act on one of them: "set your
            // addresses" is a thing to go and do, whereas nothing running at 3am is
            // simply the answer.
            placeholder: snapshot == nil ? "Set your addresses" : "Nothing running",
            detail: snapshot == nil ? "Add home and work in the app and this fills itself in." : nil
        )
    }
}

// MARK: - Views

/// The colours the widget draws in, taken from the app's own appearance setting.
///
/// A widget cannot ask the app anything at render time, and it is rendered by the
/// system against the *system* appearance — so an app defaulting to dark shows a
/// light widget on a light phone. The setting is published to the shared container
/// and read here instead.
struct WidgetPalette {
    var colorScheme: ColorScheme
    var background: Color
    var primary: Color
    var secondary: Color
    var tertiary: Color
    /// For the "miss it" cost, which has to stand out in either mode.
    var warning: Color

    /// Absent (or "system") means follow the phone, which is the platform default and
    /// what the container-unavailable case should fall back to as well. The phone's
    /// appearance comes from the view's environment: `UITraitCollection.current` is
    /// only meaningful inside UIKit's own drawing and answers "light" here.
    static func resolve(setting: String?, system: ColorScheme) -> WidgetPalette {
        switch setting {
        case "light": return .light
        case "dark": return .dark
        default: return system == .dark ? .dark : .light
        }
    }

    static let dark = WidgetPalette(
        colorScheme: .dark,
        background: Color(red: 0.07, green: 0.07, blue: 0.08),
        primary: .white,
        secondary: Color(white: 0.72),
        tertiary: Color(white: 0.48),
        // The app's accent orange as Theme draws it in dark mode (F28135).
        warning: Color(red: 0.949, green: 0.505, blue: 0.209)
    )

    static let light = WidgetPalette(
        colorScheme: .light,
        background: Color(white: 0.95),
        primary: .black,
        secondary: Color(white: 0.32),
        tertiary: Color(white: 0.52),
        // ...and in light mode (DB5800).
        warning: Color(red: 0.86, green: 0.345, blue: 0.0)
    )
}

struct CommuteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CommuteEntry
    var palette: WidgetPalette = .dark

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: accessory
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .systemMedium: medium
            default: small
            }
        }
        // One sentence rather than a badge, a ticking timer and some fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        guard let step = entry.step else {
            return [entry.placeholder, entry.detail].compactMap { $0 }.joined(separator: ". ")
        }
        var parts = [step.lines.map(\.badge).joined(separator: ", then ")]
        parts.append(step.isWalkOnly ? "walk now" : "leave by \(Format.clock(step.leaveBy))")
        if let board = step.boardName { parts.append("from \(board)") }
        var arrival = "arrive \(Format.clock(step.arrival))"
        if let destination = entry.destinationName { arrival += " at \(destination)" }
        parts.append(arrival)
        if let penalty = step.penaltyText { parts.append(penalty) }
        return parts.joined(separator: ", ")
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let step = entry.step {
                badges(step)
                countdown(step, size: 26)
                if let platform = step.platformDescription {
                    Text(platform)
                        .font(.caption2.weight(.medium))
                        .lineLimit(2)
                }
                if let board = step.boardName {
                    Text("from \(board)")
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("arrive \(Format.clock(step.arrival))")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if let step = entry.step {
                    badges(step)
                    countdown(step, size: 30)
                    if let platform = step.platformDescription {
                        Text(platform)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    Text(step.boardName.map { "from \($0) · \(step.title)" } ?? step.title)
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                } else {
                    unavailable
                }
                Spacer(minLength: 0)
            }
            if let step = entry.step {
                VStack(alignment: .trailing, spacing: 3) {
                    if let destination = entry.destinationName {
                        Text(destination)
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                    Text(Format.clock(step.arrival))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("arrive")
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                    Spacer(minLength: 0)
                    if let penalty = step.penaltyText {
                        Text(penalty)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.warning)
                    } else if let next = step.nextArrival {
                        Text("next \(Format.clock(next))")
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock screen

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let step = entry.step {
                HStack(spacing: 4) {
                    Text(step.lines.map(\.badge).joined(separator: "→"))
                        .font(.caption.weight(.bold))
                    Text(step.isWalkOnly ? "walk" : "leave")
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                    Group {
                        if let countdown = entry.countdown {
                            Text(countdown)
                        } else {
                            Text(step.leaveBy, style: .timer)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }
                Text("arrive \(Format.clock(step.arrival)) · \(entry.destinationName ?? "")")
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            } else {
                Text(entry.placeholder ?? "—").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line above the lock-screen clock: one run of text, nothing else fits.
    @ViewBuilder
    private var inline: some View {
        if let step = entry.step {
            let lines = step.lines.map(\.badge).joined(separator: "→")
            if step.isWalkOnly {
                Text("Walk · arrive \(Format.clock(step.arrival))")
            } else if let countdown = entry.countdown {
                Text("\(lines) · leave in \(countdown)")
            } else {
                Text("\(lines) · leave in \(Text(step.leaveBy, style: .timer))")
            }
        } else {
            Text(entry.placeholder ?? "Next train")
        }
    }

    /// A route and a countdown, in the lock screen's circle.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let step = entry.step {
                VStack(spacing: 0) {
                    Text(step.isWalkOnly ? "WALK" : (step.lines.first?.badge ?? ""))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                    Group {
                        if let countdown = entry.countdown {
                            Text(countdown)
                        } else {
                            Text(step.leaveBy, style: .timer)
                        }
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                }
                .padding(.horizontal, 5)
            } else {
                Image(systemName: "tram.fill")
                    .font(.title3)
            }
        }
    }

    // MARK: Pieces

    private func badges(_ step: WidgetPlanStep) -> some View {
        HStack(spacing: 4) {
            ForEach(step.lines, id: \.badge) { line in
                Text(line.badge)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetColor.foreground(on: line.colorHex))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(WidgetColor.line(line.colorHex)))
            }
            if step.isWalkOnly {
                Image(systemName: "figure.walk").font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    /// The countdown, in whichever of its two forms this entry calls for.
    ///
    /// Far out it is a plain number of minutes, held still — the entry it belongs to
    /// ends on the instant that number changes, so it is never stale. Inside two
    /// minutes it becomes WidgetKit's live `.timer`, which ticks without needing an
    /// entry per second. That is the same switch the app makes at the same threshold,
    /// which is the point: the two sit next to each other on the home screen.
    @ViewBuilder
    private func countdown(_ step: WidgetPlanStep, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.isWalkOnly ? "walk now" : "leave in")
                .font(.caption2)
                .foregroundStyle(palette.secondary)
            Group {
                if let countdown = entry.countdown {
                    Text(countdown)
                } else {
                    Text(step.leaveBy, style: .timer)
                }
            }
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "tram.fill")
                .font(.headline)
                .foregroundStyle(palette.secondary)
            Text(entry.placeholder ?? "—")
                .font(.caption.weight(.medium))
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(3)
            }
        }
    }
}

/// Line colours for the widget.
///
/// Duplicated from the app's `Theme` on purpose: `MetroKit` is deliberately free of
/// UIKit so the planner can be tested from the command line, and `Theme` lives in
/// the app target, which a widget extension can't see. Twelve lines of HSB
/// arithmetic is a cheaper price than either compromise.
enum WidgetColor {
    static func line(_ hex: String) -> Color {
        let base = UIColor(widgetHex: hex)
        return Color(uiColor: UIColor { traits in
            base.widgetContrasted(darkMode: traits.userInterfaceStyle == .dark)
        })
    }

    static func foreground(on hex: String) -> Color {
        let base = UIColor(widgetHex: hex)
        return Color(uiColor: UIColor { traits in
            let resolved = base.widgetContrasted(darkMode: traits.userInterfaceStyle == .dark)
            var white: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getWhite(&white, alpha: &alpha) else { return .white }
            return white > 0.62 ? .black : .white
        })
    }
}

private extension UIColor {
    convenience init(widgetHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// SEPTA's palette is chosen for white paper: the Norristown purple disappears
    /// on black and the Girard yellow disappears on white.
    func widgetContrasted(darkMode: Bool) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        if darkMode {
            brightness = max(brightness, 0.82)
            saturation = min(saturation, 0.78)
        } else {
            brightness = min(brightness, 0.86)
        }
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
}
