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
/// Collapsed by default — it explains the answer rather than being one.
struct FrontierChartView: View {
    @EnvironmentObject private var model: CommuteModel
    @State private var isExpanded = false
    @State private var selectedArrival: Date?

    var body: some View {
        let candidates = model.valueCandidates
        if candidates.count >= 2 {
            let frontier = model.valueFrontier(of: candidates).sorted { $0.arrival < $1.arrival }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack {
                        SectionLabel(text: "Price vs. arrival")
                        Spacer()
                        Text(isExpanded ? "Hide" : "Show")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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
                .accessibilityLabel(isExpanded ? "Hide price versus arrival chart" : "Show price versus arrival chart")

                if isExpanded {
                    card(candidates: candidates, frontier: frontier)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func card(candidates: [ValueCandidate], frontier: [ValueCandidate]) -> some View {
        let frontierIDs = Set(frontier.map(\.id))
        let others = candidates.filter { !frontierIDs.contains($0.id) }
        let selected = selectedArrival.flatMap { nearest(to: $0, in: candidates) }

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
            }
        } else {
            Text("Drag across the chart to see each option.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func legend(hasTolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                legendItem(color: Theme.accent, dashed: true, text: "Frontier")
                legendItem(color: Color.secondary.opacity(0.55), dashed: false, text: "Beaten on price and time")
            }
            if hasTolls {
                Label("Plus tolls of unknown cost", systemImage: "triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Nothing on the dashed line is both cheaper and sooner than another option. Lower and further left is better.")
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
        return "Price against arrival for \(candidates.count) options. \(frontier.count) on the frontier: " + points.joined(separator: "; ")
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
