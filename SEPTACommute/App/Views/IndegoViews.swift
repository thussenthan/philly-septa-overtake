import MapKit
import SwiftUI

extension IndegoBike {
    var symbol: String { self == .classic ? "bicycle" : "bolt.fill" }
    /// Indego's own blue for classic, a green for electric.
    var colorHex: String { self == .classic ? "0076BE" : "2E9E44" }
    var color: Color { Theme.adaptive(colorHex) }
    /// Glyph colour on top of `color`, readable in both appearances.
    var foreground: Color { Theme.foreground(onHex: colorHex) }
}

private func priceText(_ price: Double) -> String {
    price < 0.005 ? "Free" : "≈ " + Format.money(price)
}

/// A small coloured tag after a row's title.
private struct Tag: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// One Indego row on the home screen.
struct IndegoRow: View {
    var option: IndegoOption
    /// The Metro recommendation, to say what the bike gains or costs against it.
    var reference: Date?
    var referenceNoun: String = "the train"
    /// True when this is the cheapest way there of everything on the screen.
    var isCheapestOverall: Bool
    /// The classic ride's climb, when it's enough to suggest the e-bike instead.
    var hillClimb: Double?

    private var isSuggestedForHills: Bool { option.bike == .electric && hillClimb != nil }
    private var isHighlighted: Bool { isCheapestOverall || isSuggestedForHills }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: option.bike.symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(option.bike.foreground)
                .frame(width: 30, height: 24)
                .background(option.bike.color, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Indego \(option.bike.label.lowercased())")
                        .font(.subheadline.weight(.semibold))
                    if isCheapestOverall { Tag(text: "CHEAPEST", color: option.bike.color) }
                    if isSuggestedForHills { Tag(text: "HILLS", color: option.bike.color) }
                }
                // The whole trip, not just the ride: the walks at either end are
                // most of what a bike trip costs that a train trip doesn't.
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                    Text(Format.compactMinutes(option.walkToPickup))
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Image(systemName: option.bike.symbol)
                    Text(Format.compactMinutes(option.rideSeconds))
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Image(systemName: "figure.walk")
                    Text(Format.compactMinutes(option.walkFromDropoff))
                    Text("= \(Format.minutes(option.totalDuration))")
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
                    Text(comparison.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(comparison.faster ? Color.fasterText : .secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(option.arrival))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(priceText(option.price))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHighlighted ? option.bike.color.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle().fill(option.bike.color).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    /// "2 bikes · Municipal Services Building Plaza · ↗ 45 m"
    private var detailLine: String {
        var parts = ["\(option.bikesAvailable) \(option.bikesAvailable == 1 ? "bike" : "bikes")", option.pickup.name]
        if let climb = option.climbMeters, climb >= 5 { parts.insert("↗ \(Int(climb.rounded())) m", at: 1) }
        return parts.joined(separator: " · ")
    }

    /// The time chain is symbols and arrows on screen; read aloud it needs words.
    private var accessibilitySummary: String {
        var parts = [
            "Indego \(option.bike.label.lowercased())\(isCheapestOverall ? ", cheapest option" : "")\(isSuggestedForHills ? ", suggested for the hills" : "")",
            "Walk \(Format.minutes(option.walkToPickup)), ride \(Format.minutes(option.rideSeconds)), walk \(Format.minutes(option.walkFromDropoff)), \(Format.minutes(option.totalDuration)) in all",
            "\(option.bikesAvailable) at \(option.pickup.name)",
            "Arrive \(Format.clock(option.arrival)), \(priceText(option.price))",
        ]
        if let climb = option.climbMeters, climb >= 5 { parts.append("Climbs \(Int(climb.rounded())) metres") }
        if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
            parts.append(comparison.text)
        }
        return parts.joined(separator: ". ")
    }
}

/// The full bike-share trip: the map, and the three legs. Tapping a leg shows it
/// on the map; its arrow opens it in the rider's maps app.
struct IndegoDetailView: View {
    var option: IndegoOption
    var pass: IndegoPass
    var origin: Coordinate?
    /// True when the trip starts wherever the phone is, so the first walk can be
    /// handed off from "My Location"; otherwise it starts at `origin`.
    var originIsCurrentLocation: Bool
    var destination: Coordinate?
    var destinationName: String
    var reference: Date?
    var referenceNoun: String

    @EnvironmentObject private var model: CommuteModel
    /// The leg shown on the map, or nil for the whole trip.
    @State private var focusedLeg: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RouteMapView(segments: segments, stops: stops, focus: focusedLeg)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arrive \(Format.clock(option.arrival))")
                            .font(.title2.weight(.bold))
                        Text("\(Format.minutes(option.totalDuration)) · leave now")
                            .foregroundStyle(.secondary)
                        if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
                            Text(comparison.text)
                                .font(.subheadline)
                                .foregroundStyle(comparison.faster ? Color.fasterText : .secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(priceText(option.price))
                            .font(.title3.weight(.semibold))
                        Text(pass.label).font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    leg(0, symbol: "figure.walk", tint: Theme.accent,
                        title: "Walk \(Format.minutes(option.walkToPickup)) to \(option.pickup.name)",
                        detail: "\(option.pickup.classicBikes) classic · \(option.pickup.electricBikes) e-bikes") {
                        MapsHandoff.open(
                            app: model.preferences.mapsApp,
                            from: originIsCurrentLocation ? nil : origin, fromName: "Start",
                            to: option.pickup.coordinate, toName: option.pickup.name,
                            mode: .walking
                        )
                    }
                    Divider().padding(.leading, 36)
                    leg(1, symbol: option.bike.symbol, tint: option.bike.color,
                        title: "Ride \(Format.minutes(option.rideSeconds)) to \(option.dropoff.name)",
                        detail: rideDetail) {
                        MapsHandoff.open(
                            app: model.preferences.mapsApp,
                            from: option.pickup.coordinate, fromName: option.pickup.name,
                            to: option.dropoff.coordinate, toName: option.dropoff.name,
                            mode: .cycling
                        )
                    }
                    Divider().padding(.leading, 36)
                    leg(2, symbol: "figure.walk", tint: Theme.accent,
                        title: "Dock, walk \(Format.minutes(option.walkFromDropoff)) to \(destinationName)",
                        detail: "\(option.dropoff.openDocks) open docks") {
                        guard let destination else { return }
                        // From the phone once the rider is at the dock; from the dock
                        // while they're still planning.
                        let nearDock = model.locationService.coordinate.map { $0.distance(to: option.dropoff.coordinate) < 400 } ?? false
                        MapsHandoff.open(
                            app: model.preferences.mapsApp,
                            from: nearDock ? nil : option.dropoff.coordinate,
                            fromName: option.dropoff.name,
                            to: destination, toName: destinationName,
                            mode: .walking
                        )
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))

                Text("Tap a step to see it on the map. Go opens \(model.preferences.mapsApp.label).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Indego")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rideDetail: String {
        var parts = [String(format: "%.1f mi", option.rideMeters / Coordinate.metersPerMile)]
        if let climb = option.climbMeters, climb >= 5 { parts.append("↗ \(Int(climb.rounded())) m climb") }
        parts.append(option.bike.label)
        return parts.joined(separator: " · ")
    }

    /// One leg: tap the row to see it on the map (again to see the whole trip);
    /// tap the arrow for directions.
    private func leg(
        _ index: Int, symbol: String, tint: Color, title: String, detail: String?,
        directions: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedLeg == index
        return HStack(alignment: .center, spacing: 12) {
            Button {
                withAnimation(.easeInOut) { focusedLeg = isFocused ? nil : index }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .frame(width: 24)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(isFocused ? .bold : .medium)).foregroundStyle(.primary)
                        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isFocused ? "Shows the whole trip on the map" : "Shows this part on the map")

            // Labelled, not a bare glyph: a new rider didn't read the arrow as
            // "turn-by-turn directions". "Go" is what the maps apps themselves say.
            Button(action: directions) {
                Label("Go", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(tint == Theme.accent ? Theme.foreground(onHex: "F26100") : option.bike.foreground)
                    .background(tint, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Directions in \(model.preferences.mapsApp.label)")
        }
    }

    private var segments: [MapSegment] {
        let pickup = option.pickup.coordinate.clCoordinate
        let dropoff = option.dropoff.coordinate.clCoordinate
        // Always three, in leg order, so `focus` indexes them.
        return [
            MapSegment(coordinates: [(origin ?? option.pickup.coordinate).clCoordinate, pickup], color: MapSegment.walkColor, style: .walk),
            MapSegment(coordinates: [pickup, dropoff], color: option.bike.color, style: .bike),
            MapSegment(coordinates: [dropoff, (destination ?? option.dropoff.coordinate).clCoordinate], color: MapSegment.walkColor, style: .walk),
        ]
    }

    private var stops: [MapStop] {
        var result = [
            MapStop(coordinate: option.pickup.coordinate.clCoordinate, name: option.pickup.name, color: option.bike.color, role: .change),
            MapStop(coordinate: option.dropoff.coordinate.clCoordinate, name: option.dropoff.name, color: option.bike.color, role: .change),
        ]
        if let origin { result.append(MapStop(coordinate: origin.clCoordinate, name: "Start", color: .blue, role: .origin)) }
        if let destination { result.append(MapStop(coordinate: destination.clCoordinate, name: destinationName, color: Theme.accent, role: .destination)) }
        return result
    }
}
