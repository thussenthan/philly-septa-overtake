import SwiftUI

/// Everything under the Metro answer: bike share, buses and Regional Rail, and —
/// when the rider has priced their time — every option ranked by value.
///
/// Supplemental by design. The hero card and the platform sign above stay what
/// they were; this is the "what else could I do" a rider scrolls down for.
struct MoreWaysSection: View {
    @EnvironmentObject private var model: CommuteModel

    /// The option being looked at, kept as a value. Rows used to link straight to
    /// their detail, keyed by position; a replan every thirty seconds then swapped
    /// the open screen for whatever slid into that position, or popped it when the
    /// list emptied. A snapshot stays put until the rider goes back.
    @State private var openIndego: IndegoSelection?
    @State private var openAlternative: AlternativeSelection?

    private var reference: Date? { model.plan?.best?.arrivalTime }

    var body: some View {
        let alternatives = model.alternativeRoutes
        VStack(alignment: .leading, spacing: 14) {
            if !alternatives.isEmpty {
                alternativesCard(alternatives)
            }
            if model.preferences.showIndego, !model.visibleIndegoOptions.isEmpty {
                indegoCard
            }
            if let ranking = model.valueRanking, ranking.count > 1, let rate = model.preferences.valueOfTimePerHour {
                valueCard(ranking: Array(ranking.prefix(4)), rate: rate)
            }
        }
        .navigationDestination(item: $openIndego) { selection in
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
        .navigationDestination(item: $openAlternative) { selection in
            ExtendedDetailView(
                itinerary: selection.itinerary,
                origin: selection.origin,
                destination: selection.destination,
                destinationName: selection.destinationName,
                reference: selection.reference,
                referenceNoun: selection.referenceNoun
            )
        }
    }

    // MARK: Indego

    private var indegoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Indego bike share")
                Spacer()
                // Hidden here, back on in Settings → More ways to go.
                Button {
                    withAnimation { model.preferences.showIndego = false }
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide bike share")
                .accessibilityHint("Turn it back on in Settings.")
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(model.visibleIndegoOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Divider().padding(.leading, 54) }
                    Button {
                        openIndego = IndegoSelection(
                            option: option,
                            pass: model.preferences.indegoPass,
                            origin: model.originCoordinate,
                            originIsCurrentLocation: model.isPlanningFromCurrentLocation,
                            destination: model.destinationCoordinate,
                            destinationName: model.targetName,
                            reference: reference,
                            referenceNoun: model.referenceNoun
                        )
                    } label: {
                        IndegoRow(
                            option: option,
                            reference: reference,
                            referenceNoun: model.referenceNoun,
                            isCheapestOverall: model.isCheapestOverall(option),
                            hillClimb: model.hillyClassic?.climbMeters
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Alternative routes

    private func alternativesCard(_ alternatives: [ExtendedItinerary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Alternative routes")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, itinerary in
                    if index > 0 { Divider().padding(.leading, 14) }
                    Button {
                        openAlternative = AlternativeSelection(
                            itinerary: itinerary,
                            origin: model.originCoordinate,
                            destination: model.destinationCoordinate,
                            destinationName: model.targetName,
                            reference: reference,
                            referenceNoun: model.referenceNoun
                        )
                    } label: {
                        ExtendedRow(itinerary: itinerary, reference: reference, referenceNoun: model.referenceNoun)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Value

    private func valueCard(ranking: [ValueCandidate], rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Best value")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(ranking.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider().padding(.leading, 44) }
                    let fare = candidate.fare < 0.005 ? "Free" : Format.money(candidate.fare)
                    let total = Format.money(candidate.cost(perHour: rate))
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(index == 0 ? Theme.accent : Color.secondary.opacity(0.2), in: Circle())
                            .foregroundStyle(index == 0 ? Theme.foreground(onHex: "F26100") : .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            // The concrete things first; the blended score last and
                            // quietest, since it's the one a rider can't check.
                            Text("\(fare) • \(Format.minutes(candidate.travelTime)) • \(total) value")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Format.clock(candidate.arrival))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("arrive")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Number \(index + 1): \(candidate.title). \(fare), \(Format.minutes(candidate.travelTime)), arriving \(Format.clock(candidate.arrival)). \(total) counting your time.")
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A bike option as it was when tapped, with everything its screen needs.
struct IndegoSelection: Hashable {
    var option: IndegoOption
    var pass: IndegoPass
    var origin: Coordinate?
    var originIsCurrentLocation: Bool
    var destination: Coordinate?
    var destinationName: String
    var reference: Date?
    var referenceNoun: String
}

/// An alternative route as it was when tapped.
struct AlternativeSelection: Hashable {
    var itinerary: ExtendedItinerary
    var origin: Coordinate?
    var destination: Coordinate?
    var destinationName: String
    var reference: Date?
    var referenceNoun: String
}

/// "4 min sooner than the train", against whatever the main answer is.
func comparisonText(_ arrival: Date, against reference: Date?, noun: String) -> (text: String, faster: Bool)? {
    guard let reference else { return nil }
    let delta = arrival.timeIntervalSince(reference)
    if abs(delta) < 60 { return ("Same arrival as \(noun)", false) }
    return delta < 0
        ? ("\(Format.minutes(-delta)) sooner than \(noun)", true)
        : ("\(Format.minutes(delta)) later than \(noun)", false)
}

extension Color {
    /// A green that reads as text on white as well as on black.
    static let fasterText = Theme.adaptive("1E8A3A")
}

// MARK: - Bus / Regional Rail row and detail

extension ExtendedMode {
    var symbol: String {
        switch self {
        case .bus: return "bus.fill"
        case .trolley: return "cablecar.fill"
        case .metro: return "tram.fill"
        case .rail: return "train.side.front.car"
        }
    }
}

struct RouteChip: View {
    var ride: ExtendedRide

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ride.mode.symbol).font(.caption2)
            Text(ride.routeShortName).font(.caption.weight(.bold)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(Theme.foreground(onHex: ride.colorHex))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.adaptive(ride.colorHex), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ExtendedRow: View {
    var itinerary: ExtendedItinerary
    var reference: Date?
    var referenceNoun: String = "the train"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                // One line of chips when they fit; stacked when large text or a
                // three-ride trip would push them off the edge.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { chips }
                    VStack(alignment: .leading, spacing: 4) { chips }
                }
                if let first = itinerary.rides.first {
                    Text("\(first.boardName) \(Format.clock(first.departure)) · toward \(first.headsign)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(deltaText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isFaster ? Color.fasterText : .secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(itinerary.arrival))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(fareText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(Array(itinerary.rides.enumerated()), id: \.offset) { index, ride in
            HStack(spacing: 4) {
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                RouteChip(ride: ride)
            }
        }
    }

    private var fareText: String {
        itinerary.fareIsKnown ? Format.money(itinerary.fare) : "Fare varies"
    }

    private var leaveText: String {
        let seconds = itinerary.leaveBy.timeIntervalSinceNow
        return seconds < 60 ? "leave now" : "leave in \(Format.minutes(seconds))"
    }

    private var comparison: (text: String, faster: Bool)? {
        comparisonText(itinerary.arrival, against: reference, noun: referenceNoun)
    }

    private var isFaster: Bool { comparison?.faster ?? false }

    private var deltaText: String {
        guard let comparison else { return leaveText }
        return comparison.text + " · " + leaveText
    }

    private var accessibilitySummary: String {
        let routes = itinerary.rides.map { "\($0.mode.spokenName) \($0.routeShortName)" }.joined(separator: ", then ")
        return "\(routes). Arrive \(Format.clock(itinerary.arrival)), \(fareText). \(deltaText)."
    }
}

extension ExtendedMode {
    var spokenName: String {
        switch self {
        case .bus: return "Bus"
        case .trolley: return "Trolley"
        case .metro: return "Metro"
        case .rail: return "Regional Rail"
        }
    }
}

struct ExtendedDetailView: View {
    var itinerary: ExtendedItinerary
    var origin: Coordinate?
    var destination: Coordinate?
    var destinationName: String = "Destination"
    var reference: Date?
    var referenceNoun: String = "the train"

    @EnvironmentObject private var model: CommuteModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RouteMapView(segments: segments, stops: stops)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text("Arrive \(Format.clock(itinerary.arrival))")
                            .font(.title2.weight(.bold))
                        Text("Leave by \(Format.clock(itinerary.leaveBy)) · \(Format.minutes(itinerary.arrival.timeIntervalSince(itinerary.leaveBy))) door to door")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(itinerary.fareIsKnown ? "≈ " + Format.money(itinerary.fare) : "Fare varies")
                        .font(.title3.weight(.semibold))
                }
                if let comparison = comparisonText(itinerary.arrival, against: reference, noun: referenceNoun) {
                    Label(comparison.text, systemImage: comparison.faster ? "hare.fill" : "clock")
                        .font(.subheadline)
                }

                Button {
                    guard let destination else { return }
                    MapsHandoff.open(app: model.preferences.mapsApp, from: origin, fromName: "Start", to: destination, toName: destinationName, mode: .transit)
                } label: {
                    Label("Open in \(model.preferences.mapsApp.label)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { _, leg in
                        switch leg {
                        case .walk(let walk):
                            if walk.seconds >= 30 {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "figure.walk").frame(width: 24).foregroundStyle(.secondary)
                                    Text("Walk \(Format.minutes(walk.seconds)) to \(walk.toName == "Destination" ? destinationName : walk.toName)")
                                        .font(.subheadline)
                                }
                            }
                        case .ride(let ride):
                            HStack(alignment: .top, spacing: 12) {
                                RouteChip(ride: ride).fixedSize().frame(minWidth: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(ride.routeLongName.isEmpty ? ride.routeShortName : ride.routeLongName) toward \(ride.headsign)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Board \(ride.boardName) · \(Format.clock(ride.departure))")
                                        .font(.caption)
                                    Text("Get off \(ride.alightName) · \(Format.clock(ride.arrival))")
                                        .font(.caption)
                                    Text("\(ride.stopCount) stops · \(Format.minutes(ride.arrival.timeIntervalSince(ride.departure)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))

                Text("Scheduled times • SEPTA Key fare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Your trip")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var segments: [MapSegment] {
        itinerary.legs.map { leg in
            switch leg {
            case .walk(let walk):
                return MapSegment(coordinates: [walk.from.clCoordinate, walk.to.clCoordinate], color: MapSegment.walkColor, style: .walk)
            case .ride(let ride):
                return MapSegment(coordinates: ride.path.map(\.clCoordinate), color: Theme.adaptive(ride.colorHex), style: .ride)
            }
        }
    }

    private var stops: [MapStop] {
        var result: [MapStop] = []
        for ride in itinerary.rides {
            let color = Theme.adaptive(ride.colorHex)
            result.append(MapStop(coordinate: ride.boardCoordinate.clCoordinate, name: ride.boardName, color: color, role: .change))
            result.append(MapStop(coordinate: ride.alightCoordinate.clCoordinate, name: ride.alightName, color: color, role: .change))
        }
        if let origin { result.append(MapStop(coordinate: origin.clCoordinate, name: "Start", color: .blue, role: .origin)) }
        if let destination { result.append(MapStop(coordinate: destination.clCoordinate, name: destinationName, color: Theme.accent, role: .destination)) }
        return result
    }
}
