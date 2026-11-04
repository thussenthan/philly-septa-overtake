import SwiftUI

/// Everything under the Metro answer: bike share, buses and Regional Rail, and —
/// when the rider has priced their time — every option ranked by value.
///
/// Supplemental by design. The hero card and the platform sign above stay what
/// they were; this is the "what else could I do" a rider scrolls down for.
struct MoreWaysSection: View {
    @EnvironmentObject private var model: CommuteModel

    private var reference: Date? { model.plan?.best?.arrivalTime }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let ranking = model.valueRanking, ranking.count > 1, let rate = model.preferences.valueOfTimePerHour {
                valueCard(ranking: Array(ranking.prefix(4)), rate: rate)
            }
            if !model.indegoOptions.isEmpty {
                indegoCard
            }
            if !model.extendedItineraries.isEmpty {
                extendedCard
            }
        }
    }

    // MARK: Indego

    private var indegoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Indego bike share")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(model.indegoOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Divider().padding(.leading, 54) }
                    NavigationLink {
                        IndegoDetailView(
                            option: option,
                            pass: model.preferences.indegoPass,
                            origin: model.originCoordinate,
                            destination: model.destinationCoordinate,
                            reference: reference
                        )
                    } label: {
                        IndegoRow(
                            option: option,
                            reference: reference,
                            highlighted: option.bike == .classic && model.indegoOptions.count > 1
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Buses and Regional Rail

    private var extendedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Also on SEPTA · bus & Regional Rail")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(model.extendedItineraries.enumerated()), id: \.element.id) { index, itinerary in
                    if index > 0 { Divider().padding(.leading, 14) }
                    NavigationLink {
                        ExtendedDetailView(
                            itinerary: itinerary,
                            origin: model.originCoordinate,
                            destination: model.destinationCoordinate,
                            reference: reference
                        )
                    } label: {
                        ExtendedRow(itinerary: itinerary, reference: reference)
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
            SectionLabel(text: "Best value at \(Format.money(rate))/hr")
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(ranking.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(index == 0 ? Theme.accent : Color.secondary.opacity(0.2), in: Circle())
                            .foregroundStyle(index == 0 ? .white : .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(candidate.fare < 0.005 ? "No fare" : Format.money(candidate.fare)) + \(Format.minutes(candidate.travelTime)) · arrive \(Format.clock(candidate.arrival))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.money(candidate.cost(perHour: rate)))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }
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
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.adaptive(ride.colorHex), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ExtendedRow: View {
    var itinerary: ExtendedItinerary
    var reference: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    ForEach(Array(itinerary.rides.enumerated()), id: \.offset) { index, ride in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        RouteChip(ride: ride)
                    }
                }
                if let first = itinerary.rides.first {
                    Text("\(first.boardName) \(Format.clock(first.departure)) · toward \(first.headsign)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(deltaText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(deltaColor)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(itinerary.arrival))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(Format.money(itinerary.fare))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var leaveText: String {
        let seconds = itinerary.leaveBy.timeIntervalSinceNow
        return seconds < 60 ? "leave now" : "leave in \(Format.minutes(seconds))"
    }

    private var deltaText: String {
        guard let reference else { return leaveText }
        let delta = itinerary.arrival.timeIntervalSince(reference)
        let comparison = abs(delta) < 60 ? "Same arrival as the train"
            : delta < 0 ? "\(Format.minutes(-delta)) sooner than the train"
            : "\(Format.minutes(delta)) later than the train"
        return comparison + " · " + leaveText
    }

    private var deltaColor: Color {
        guard let reference else { return .secondary }
        return itinerary.arrival.timeIntervalSince(reference) < -60 ? .green : .secondary
    }
}

struct ExtendedDetailView: View {
    var itinerary: ExtendedItinerary
    var origin: Coordinate?
    var destination: Coordinate?
    var reference: Date?

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
                    Text("≈ " + Format.money(itinerary.fare))
                        .font(.title3.weight(.semibold))
                }
                if let reference {
                    let delta = itinerary.arrival.timeIntervalSince(reference)
                    Label(
                        abs(delta) < 60 ? "Arrives about when the recommended train does"
                            : delta < 0 ? "\(Format.minutes(-delta)) sooner than the recommended train"
                            : "\(Format.minutes(delta)) later than the recommended train",
                        systemImage: delta < -60 ? "hare.fill" : "clock"
                    )
                    .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { _, leg in
                        switch leg {
                        case .walk(let walk):
                            if walk.seconds >= 30 {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "figure.walk").frame(width: 24).foregroundStyle(.secondary)
                                    Text("Walk \(Format.minutes(walk.seconds)) to \(walk.toName)")
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
                                    Text("\(max(0, ride.path.count - 1)) stops · \(Format.minutes(ride.arrival.timeIntervalSince(ride.departure)))")
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

                Text("Scheduled times from SEPTA's published bus and Regional Rail timetables, not live positions. Fares are SEPTA Key estimates; Regional Rail fares depend on zone and time of day.")
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
        if let destination { result.append(MapStop(coordinate: destination.clCoordinate, name: "Destination", color: Theme.accent, role: .destination)) }
        return result
    }
}
