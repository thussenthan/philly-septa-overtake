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
/// What it takes from the app is only the rider's two addresses, written to the shared
/// App Group as soon as they are saved; which way round to read them it works out from
/// the clock. So it is right from the first launch, without the app being opened to
/// prime it, which is the whole point of a widget.
struct SEPTACommuteWidget: Widget {
    let kind = "SEPTACommuteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CommuteTimelineProvider()) { entry in
            CommuteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("When to leave for your commute — out in the morning, back in the afternoon.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct CommuteEntry: TimelineEntry {
    var date: Date
    var step: WidgetPlanStep?
    var destinationName: String?
    /// Set when there is nothing to show, and why.
    var placeholder: String?
}

struct CommuteTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> CommuteEntry {
        CommuteEntry(date: Date(), step: nil, destinationName: nil, placeholder: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        completion(entries(from: Date()).first ?? empty(at: Date()))
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
        // WidgetKit reloads when the last entry expires, which is the moment the
        // final option stops being catchable — exactly when a fresh plan is needed.
        completion(Timeline(entries: entries, policy: .after(last.date.addingTimeInterval(60))))
    }

    private func entries(from now: Date) -> [CommuteEntry] {
        guard let snapshot = SharedStore.snapshot() else { return [] }
        return WidgetPlanner.steps(for: snapshot, from: now).map { step in
            CommuteEntry(
                date: step.validFrom,
                step: step,
                // Named per entry, not per snapshot: an entry that takes over after
                // midday is answering the trip home, and has to say so.
                destinationName: snapshot.trip(at: step.validFrom).destination.name,
                placeholder: nil
            )
        }
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
            placeholder: snapshot == nil ? "Set your addresses" : "Nothing running"
        )
    }
}

// MARK: - Views

struct CommuteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CommuteEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: accessory
        case .systemMedium: medium
        default: small
        }
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(Format.clock(step.arrival))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("arrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let penalty = step.penaltyText {
                        Text(penalty)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if let next = step.nextArrival {
                        Text("next \(Format.clock(next))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                    Text(step.leaveBy, style: .timer)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                Text("arrive \(Format.clock(step.arrival)) · \(entry.destinationName ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(entry.placeholder ?? "—").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A self-updating countdown. WidgetKit renders `.timer` live, so one entry
    /// covers the whole stretch until this option stops being catchable — no entry
    /// per minute, and no stale "leave in 4 min" sitting on the home screen.
    private func countdown(_ step: WidgetPlanStep, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.isWalkOnly ? "walk now" : "leave in")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(step.leaveBy, style: .timer)
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
                .foregroundStyle(.secondary)
            Text(entry.placeholder ?? "—")
                .font(.caption.weight(.medium))
            Text("Add home and work in the app and this fills itself in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
