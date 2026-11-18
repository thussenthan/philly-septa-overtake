import Charts
import SwiftUI

/// Every way there, plotted as price against arrival, with the Pareto frontier
/// drawn through the ones worth considering.
///
/// The value ranking above shows only the frontier, ordered by one rate. This is
/// the picture behind it: each dot is an option the app knows of, and the dashed
/// staircase joins those that nothing else beats on both price and arrival. A dot
/// above and to the right of the staircase is something cheaper-and-sooner beats.
///
/// Open by default; the header folds it away for anyone who would rather not see it.
struct FrontierChartView: View {
    @EnvironmentObject private var model: CommuteModel
    /// Called just after the chart opens, so the page can bring it into view: it
    /// is the last thing on the screen, and otherwise opens below the fold.
    var onExpand: () -> Void = {}

    /// What the page scrolls to when the chart opens.
    static let scrollID = "frontier-chart"

    @State private var isExpanded = true
    @State private var selectedArrival: Date?
    /// The last place the rider pointed. Chart selection clears when the finger
    /// lifts; this keeps the readout (and its button) up so it can be tapped.
    @State private var pinnedArrival: Date?
    /// The option tapped, kept as a snapshot (as MoreWaysSection does) so a replan
    /// every thirty seconds doesn't swap or pop the screen the rider is reading.
    @State private var opened: OpenedRoute?

    private enum OpenedRoute: Hashable {
        case metro(Journey)
        case alternative(AlternativeSelection)
        case indego(IndegoSelection)
    }

    var body: some View {
        // Always present, so the destination below survives a replan that briefly
        // leaves fewer than two options to plot.
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .navigationDestination(item: $opened) { route in
            switch route {
            case .metro(let journey):
                JourneyDetailView(
                    journey: journey,
                    summary: model.narrator.summary(for: journey),
                    narrator: model.narrator,
                    network: model.network,
                    originName: model.originName,
                    destinationName: model.targetName,
                    alert: model.alert(for: journey)
                )
            case .alternative(let selection):
                ExtendedDetailView(
                    itinerary: selection.itinerary,
                    origin: selection.origin,
                    destination: selection.destination,
                    destinationName: selection.destinationName,
                    reference: selection.reference,
                    referenceNoun: selection.referenceNoun
                )
            case .indego(let selection):
                IndegoDetailView(
                    option: selection.option,
                    pass: selection.pass,
                    origin: selection.origin,
                    originIsCurrentLocation: selection.originIsCurrentLocation,
                    destination: selection.destination,
                    destinationName: selection.destinationName,
                    reference: selection.reference,
                    referenceNoun: selection.referenceNoun
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let candidates = model.valueCandidates
        if candidates.count >= 2 {
            let frontier = model.valueFrontier(of: candidates).sorted { $0.arrival < $1.arrival }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    // One short ease for the card and the chevron together. The old
                    // spring slid the card down from behind the header, which read
                    // as it dropping through the title.
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
                    if isExpanded { onExpand() }
                } label: {
                    HStack {
                        SectionLabel(text: "Price vs. arrival · Pareto frontier")
                        Spacer()
                        // Both words in one slot, so the swap is a crossfade rather
                        // than the row reflowing around a word of a new width.
                        ZStack(alignment: .trailing) {
                            Text("Show").opacity(isExpanded ? 0 : 1)
                            Text("Hide").opacity(isExpanded ? 1 : 0)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 4)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide price versus arrival Pareto frontier chart" : "Show price versus arrival Pareto frontier chart")

                if isExpanded {
                    card(candidates: candidates, frontier: frontier)
                        // Grows out of the header rather than sliding past it.
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .id(Self.scrollID)
        }
    }

    private func card(candidates: [ValueCandidate], frontier: [ValueCandidate]) -> some View {
        let frontierIDs = Set(frontier.map(\.id))
        let others = candidates.filter { !frontierIDs.contains($0.id) }
        let selected = (selectedArrival ?? pinnedArrival).flatMap { nearest(to: $0, in: candidates) }

        return VStack(alignment: .leading, spacing: 10) {
            Chart {
                // The frontier as a staircase: each option's price holds until the
                // next-sooner one takes over, which is exactly the edge of what it
                // beats. Drawn first so the dots sit on top of it.
                ForEach(frontier) { candidate in
                    LineMark(
                        x: .value("Arrival", candidate.arrival),
                        y: .value("Price", candidate.fare),
                        series: .value("Series", "Frontier")
                    )
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Theme.accent)
                }

                ForEach(others) { candidate in
                    PointMark(
                        x: .value("Arrival", candidate.arrival),
                        y: .value("Price", candidate.fare)
                    )
                    .symbol(candidate.fareIsLowerBound ? BasicChartSymbolShape.triangle : BasicChartSymbolShape.circle)
                    .symbolSize(40)
                    .foregroundStyle(Color.secondary.opacity(0.55))
                }

                ForEach(frontier) { candidate in
                    PointMark(
                        x: .value("Arrival", candidate.arrival),
                        y: .value("Price", candidate.fare)
                    )
                    .symbol(candidate.fareIsLowerBound ? BasicChartSymbolShape.triangle : BasicChartSymbolShape.circle)
                    .symbolSize(60)
                    .foregroundStyle(Theme.accent)
                }

                if let selected {
                    RuleMark(x: .value("Arrival", selected.arrival))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(
                        x: .value("Arrival", selected.arrival),
                        y: .value("Price", selected.fare)
                    )
                    .symbolSize(140)
                    .foregroundStyle(Color.clear)
                    .annotation(position: .overlay) {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .chartXSelection(value: $selectedArrival)
            .onChange(of: selectedArrival) { _, arrival in
                if let arrival { pinnedArrival = arrival }
            }
            // A tap on a dot opens that route; a drag still scrubs the readout.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if let hit = candidate(at: location, proxy: proxy, geometry: geometry, in: candidates, frontierIDs: frontierIDs) {
                                pinnedArrival = hit.arrival
                                open(hit)
                            }
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount < 0.005 ? "$0" : Format.money(amount))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Format.clock(date))
                        }
                    }
                }
            }
            .frame(height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(candidates: candidates, frontier: frontier))
            // VoiceOver can't aim at a dot, so each option is an action on the chart.
            .accessibilityActions {
                ForEach(candidates.sorted { $0.arrival < $1.arrival }) { candidate in
                    Button("Open \(candidate.title), arriving \(Format.clock(candidate.arrival))") { open(candidate) }
                }
            }

            readout(selected: selected, isOnFrontier: selected.map { frontierIDs.contains($0.id) } ?? false)

            legend(hasTolls: candidates.contains(where: \.fareIsLowerBound))
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    /// What's under the rider's finger, or how to get something there.
    @ViewBuilder
    private func readout(selected: ValueCandidate?, isOnFrontier: Bool) -> some View {
        if let selected {
            Button { open(selected) } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(price(selected)) • \(Format.minutes(selected.travelTime)) • \(isOnFrontier ? "on the frontier" : "beaten on both")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.clock(selected.arrival))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: opensInMaps(selected) ? "arrow.up.forward.app" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(opensInMaps(selected) ? "Opens directions in \(model.preferences.mapsApp.label)" : "Shows this route")
        } else {
            Text("Tap a dot to open that route, or drag across the chart to compare.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func legend(hasTolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                legendItem(color: Theme.accent, dashed: true, text: "Pareto frontier")
                legendItem(color: Color.secondary.opacity(0.55), dashed: false, text: "Beaten on price and time")
            }
            if hasTolls {
                Label("Plus tolls of unknown cost", systemImage: "triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("The dashed line is the Pareto frontier: no other option is both cheaper and sooner than anything on it. Lower and further left is better.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legendItem(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            if dashed {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 14, height: 1.5)
                    .overlay(
                        DashSwatchLine().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    )
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The dot under a tap, if one is close enough to mean it: the nearest within
    /// a fingertip, preferring the frontier's where dots overlap.
    private func candidate(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        in candidates: [ValueCandidate],
        frontierIDs: Set<String>
    ) -> ValueCandidate? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let reach: CGFloat = 24
        var best: (candidate: ValueCandidate, distance: CGFloat)?
        for candidate in candidates {
            guard let point = proxy.position(for: (x: candidate.arrival, y: candidate.fare)) else { continue }
            let dx: CGFloat = point.x + origin.x - location.x
            let dy: CGFloat = point.y + origin.y - location.y
            // A frontier dot wins a near-tie with a grey one drawn under it.
            let distance: CGFloat = (dx * dx + dy * dy).squareRoot() - (frontierIDs.contains(candidate.id) ? 4 : 0)
            if distance <= reach, distance < (best?.distance ?? .infinity) {
                best = (candidate, distance)
            }
        }
        return best?.candidate
    }

    /// Walking and driving have no screen of their own in the app, so they hand
    /// off to the rider's maps app, as the other routes' "Open in Maps" does.
    private func opensInMaps(_ candidate: ValueCandidate) -> Bool {
        switch candidate.kind {
        case .walking, .driving: return true
        case .metro, .extended, .indego: return false
        }
    }

    private func open(_ candidate: ValueCandidate) {
        let reference = model.plan?.best?.arrivalTime
        switch candidate.kind {
        case .metro(let journey):
            opened = .metro(journey)
        case .extended(let itinerary):
            opened = .alternative(AlternativeSelection(
                itinerary: itinerary,
                origin: model.originCoordinate,
                destination: model.destinationCoordinate,
                destinationName: model.targetName,
                reference: reference,
                referenceNoun: model.referenceNoun
            ))
        case .indego(let option):
            opened = .indego(IndegoSelection(
                option: option,
                pass: model.preferences.indegoPass,
                origin: model.originCoordinate,
                originIsCurrentLocation: model.isPlanningFromCurrentLocation,
                destination: model.destinationCoordinate,
                destinationName: model.targetName,
                reference: reference,
                referenceNoun: model.referenceNoun
            ))
        case .walking:
            handOff(mode: .walking)
        case .driving:
            handOff(mode: .driving)
        }
    }

    private func handOff(mode: MapsHandoff.Mode) {
        guard let destination = model.destinationCoordinate else { return }
        MapsHandoff.open(
            app: model.preferences.mapsApp,
            from: model.isPlanningFromCurrentLocation ? nil : model.originCoordinate,
            fromName: model.originName,
            to: destination,
            toName: model.targetName,
            mode: mode
        )
    }

    private func price(_ candidate: ValueCandidate) -> String {
        if candidate.fareIsLowerBound { return Format.money(candidate.fare) + " + tolls" }
        return candidate.fare < 0.005 ? "Free" : Format.money(candidate.fare)
    }

    /// The option closest in arrival to where the rider is pointing; among ties,
    /// the frontier's (cheapest) one.
    private func nearest(to date: Date, in candidates: [ValueCandidate]) -> ValueCandidate? {
        candidates.min { a, b in
            let da = abs(a.arrival.timeIntervalSince(date)), db = abs(b.arrival.timeIntervalSince(date))
            return da == db ? a.fare < b.fare : da < db
        }
    }

    private func accessibilitySummary(candidates: [ValueCandidate], frontier: [ValueCandidate]) -> String {
        let points = frontier.map { "\($0.title), \(price($0)), arriving \(Format.clock($0.arrival))" }
        return "Price against arrival for \(candidates.count) options. \(frontier.count) on the Pareto frontier: " + points.joined(separator: "; ")
    }
}

/// A horizontal line across its rect, for the dashed legend swatch.
private struct DashSwatchLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
