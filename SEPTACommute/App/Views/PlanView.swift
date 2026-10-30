import SwiftUI

/// The home screen: which train, and how long have I got.
///
/// Deliberately the smallest thing that answers that. One card for the
/// recommendation, at most two alternatives on one line each, and a single row for
/// anything else worth knowing. Stops, transfers, skipped stations, SEPTA's alert
/// text and the provenance of the timetable are all real information — they are
/// also all reasons to read instead of deciding, so each of them is a tap away.
struct PlanView: View {
    @EnvironmentObject private var model: CommuteModel
    @Environment(\.scenePhase) private var scenePhase
    /// One sheet at a time, named.
    ///
    /// SwiftUI supports a single `.sheet` per view. Four of them stacked on this one
    /// mostly worked, right up until a sheet tried to present a sheet of its own —
    /// then the presentation machinery dismissed the parent instead. One modifier
    /// driven by an enum is the shape that has always been supported.
    private enum ActiveSheet: String, Identifiable {
        case settings, notes, destination, origin, board
        var id: String { rawValue }
    }

    @State private var activeSheet: ActiveSheet?

    /// Alternatives shown inline before the rest move behind "all options".
    private let inlineAlternatives = 2

    var body: some View {
        NavigationStack {
            // The content is asked to fill the viewport, and the answer card is the
            // only flexible thing in it, so a short plan gives the recommendation the
            // rest of the screen instead of leaving it stranded above a black gap.
            // With enough options to overflow, the minimum stops binding and the card
            // returns to its natural size.
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        tripRow
                        answerSection
                        if let station = model.currentStation { boardLink(for: station) }
                        statusRow
                    }
                    // Tighter than the usual inset: the answer card is the screen, and
                    // every point of margin is a point it isn't using.
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // An inline title bar is 44pt tall, so this is about as large as
                    // the mark can be drawn without the stops clipping.
                    Wordmark(height: 30)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { activeSheet = .board } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Station board")
                    .accessibilityHint("Shows every train leaving a station")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                case .notes:
                    ServiceNotesView()
                case .destination:
                    DestinationPickerView(
                        title: "Going to",
                        selection: Binding(
                            get: { model.target },
                            set: { model.chooseTarget($0) }
                        )
                    )
                case .board:
                    StationBoardView(initial: model.suggestedBoardStation)
                case .origin:
                    OriginPickerView(
                        selection: Binding(
                            get: { model.source },
                            set: { model.source = $0; model.replan() }
                        )
                    )
                }
            }
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
        // Coming back to the app is not an appearance, so without this a plan, a
        // location and a set of alerts from hours ago sat on screen until the next
        // thirty-second tick — and the alerts were never refetched at all.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.onAppear()
            case .background: model.onDisappear()
            default: break
            }
        }
    }

    // MARK: - Where to where

    /// The trip, as one fact: `Erie → Home`.
    ///
    /// Two rows labelled FROM and TO said the same thing in twice the space. The
    /// halves are separately tappable, so changing either end is still one tap —
    /// and addresses, cross-streets and "you're at this station" moved into the
    /// pickers, which is where a rider is actually choosing between them.
    private var tripRow: some View {
        HStack(spacing: 10) {
            Button { activeSheet = .origin } label: {
                endpoint(symbol: originSymbol, text: originDescription, detail: nil, alignment: .leading)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Starting from \(originDescription)")
            .accessibilityHint("Double tap to change where you start")

            swapControl

            Button { activeSheet = .destination } label: {
                // The one caption worth keeping: when the app guessed the
                // destination, the rider needs to see that it guessed.
                endpoint(
                    symbol: "flag.checkered",
                    text: model.targetName,
                    detail: model.targetReason ?? (model.target == nil ? "Tap to choose" : nil),
                    alignment: .trailing
                )
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.target == nil ? "Choose where you are going" : "Going to \(model.targetName)")
            .accessibilityHint(model.targetReason ?? "Double tap to change your destination")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    /// The arrow between the ends, which turns the trip round when it can be.
    @ViewBuilder
    private var swapControl: some View {
        if model.canSwapEnds {
            Button {
                withAnimation(.snappy) { model.swapEnds() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Swap start and destination")
            .accessibilityHint("Plans the trip the other way round")
        } else {
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private func endpoint(
        symbol: String,
        text: String,
        detail: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .contentShape(Rectangle())
    }

    private var originSymbol: String {
        switch model.source {
        case .currentLocation: return model.currentStation == nil ? "location.fill" : "tram.fill"
        case .station: return "tram.fill"
        case .saved(let place): return place.role.symbol
        }
    }

    /// `model.originName` names a *resolved* origin, which is what the widget needs.
    /// On screen there is one more case: location that hasn't arrived yet.
    private var originDescription: String {
        if case .currentLocation = model.source, model.currentStation == nil {
            return model.locationStatusSummary ?? "Current location"
        }
        return model.originName
    }

    // MARK: - The answer

    @ViewBuilder
    private var answerSection: some View {
        if model.target == nil {
            MessageCard(
                symbol: "flag.checkered",
                title: "Where are you headed?",
                message: "Pick a destination above and this screen will tell you which train to take, and how long you have to catch it."
            )
        } else if model.resolvedOrigin == nil {
            locationPrompt
        } else if let plan = model.plan, let best = plan.journeys.first {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    detailView(for: best)
                } label: {
                    HeroCard(
                        journey: best,
                        summary: model.narrator.summary(for: best),
                        narrator: model.narrator,
                        network: model.network,
                        alert: model.alert(for: best),
                        alertLabel: model.alert(for: best).map { model.alertChipText($0) }
                    )
                }
                .buttonStyle(.plain)

                alternatives(in: plan, best: best)
                DepartureBoardView()
            }
        } else if model.plan != nil {
            // The reason is already worked out — too far from a station, no step-free
            // route, a timetable that has run out — but it lived behind "1 note" on the
            // status row, while the card here said only to check septa.org.
            let empty = emptyPlanCopy
            MessageCard(
                symbol: empty.symbol,
                title: empty.title,
                message: model.noteMessages.first
                    ?? "No trips found in the next hour and a half. Check septa.org for service alerts."
            )
        } else {
            ProgressView("Working out your options…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    /// "Nothing running" under a moon was the heading whatever the reason — including
    /// an address too far from any station, where service is running perfectly well.
    private var emptyPlanCopy: (symbol: String, title: String) {
        switch model.plan?.notes.first {
        case .originTooFarFromLine?, .destinationTooFarFromLine?:
            return ("figure.walk", "Too far from a station")
        case .noStepFreeRouteFound?:
            return ("figure.roll", "No step-free route")
        case .scheduleOutOfDate?:
            return ("calendar.badge.exclamationmark", "Timetable has run out")
        default:
            return ("moon.zzz", "Nothing running")
        }
    }

    @ViewBuilder
    private func alternatives(in plan: Plan, best: Journey) -> some View {
        let rest = Array(plan.journeys.dropFirst())
        if !rest.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rest.prefix(inlineAlternatives).enumerated()), id: \.element.id) { index, journey in
                    if index > 0 { Divider().padding(.leading, 44) }
                    NavigationLink {
                        detailView(for: journey)
                    } label: {
                        OptionRow(
                            journey: journey,
                            summary: model.narrator.summary(for: journey),
                            comparison: model.narrator.comparison(of: journey, against: best),
                            network: model.network,
                            hasAlert: model.alert(for: journey) != nil
                        )
                    }
                    .buttonStyle(.plain)
                }

                if rest.count > inlineAlternatives {
                    Divider().padding(.leading, 44)
                    NavigationLink {
                        OptionsListView(originName: originDescription)
                    } label: {
                        HStack {
                            Text("All \(plan.journeys.count) options")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func detailView(for journey: Journey) -> some View {
        JourneyDetailView(
            journey: journey,
            summary: model.narrator.summary(for: journey),
            narrator: model.narrator,
            network: model.network,
            originName: originDescription,
            destinationName: model.targetName,
            alert: model.alert(for: journey)
        )
    }

    @ViewBuilder
    private var locationPrompt: some View {
        switch model.locationService.status {
        case .denied, .restricted:
            VStack(spacing: 12) {
                MessageCard(
                    symbol: "location.slash",
                    title: "Location is off",
                    message: "Turn on location access to plan from where you are — or pick a starting station instead.",
                    tint: Theme.color(for: .leaveSoon)
                )
                Button("Open Settings") { Self.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Choose a starting station") { activeSheet = .origin }
                    .font(.subheadline)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                MessageCard(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't get your location",
                    message: message,
                    tint: Theme.color(for: .leaveSoon)
                )
                Button("Try again") { model.locationService.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Choose a starting station") { activeSheet = .origin }
                    .font(.subheadline)
                Button("Open Settings") { Self.openSystemSettings() }
                    .font(.footnote)
            }
        default:
            VStack(spacing: 12) {
                ProgressView("Finding you…")
                Button("Pick a starting station instead") { activeSheet = .origin }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    /// Standing in a station is exactly when a platform sign would help, and most of
    /// these stations have none.
    private func boardLink(for station: Station) -> some View {
        Button { activeSheet = .board } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text("Everything leaving \(station.name)")
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Status

    /// One row for everything that isn't the answer: SEPTA's alerts, the planner's
    /// caveats, where the timetable came from. Counted rather than quoted, so the
    /// screen stays the same height whether there are none or nine.
    private var statusRow: some View {
        Button { activeSheet = .notes } label: {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.footnote)
                    .foregroundStyle(statusTint)
                    .frame(width: 18)
                Text(statusSummary)
                    .font(.footnote)
                    .foregroundStyle(statusTint)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusSymbol: String {
        if let worst = model.serviceAlerts.first {
            return worst.severity >= .delay ? "exclamationmark.triangle.fill" : "megaphone.fill"
        }
        return model.noteMessages.isEmpty ? "info.circle" : "info.circle.fill"
    }

    private var statusTint: Color {
        guard let worst = model.serviceAlerts.first else { return .secondary }
        return Theme.color(for: worst.severity)
    }

    /// "Delays on the B · 1 note", or just where the times came from.
    private var statusSummary: String {
        var parts: [String] = []
        if let worst = model.serviceAlerts.first {
            parts.append(model.alertChipText(worst))
            let others = model.serviceAlerts.count - 1
            if others > 0 { parts.append("\(others) more alert\(others == 1 ? "" : "s")") }
        }
        let notes = model.noteMessages.count
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        guard parts.isEmpty else { return parts.joined(separator: " · ") }
        return "Scheduled times, not live · service & data"
    }
}

extension CommuteModel {
    /// A short phrase for the "From" row while location is still settling.
    var locationStatusSummary: String? {
        switch locationService.status {
        case .located: return "Current location"
        case .locating, .requestingPermission: return "Finding you…"
        case .denied, .restricted: return "Location off"
        case .failed: return "Location unavailable"
        case .idle: return "Current location"
        }
    }
}
