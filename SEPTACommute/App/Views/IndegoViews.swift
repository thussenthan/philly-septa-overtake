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


/// One Indego row on the home screen.
struct IndegoRow: View {
    var option: IndegoOption
    /// The Metro recommendation, to say what the bike gains or costs against it.
    var reference: Date?
    var referenceNoun: String = "the train"
    /// True when this is the cheapest way there of everything on the screen.
    var isCheapestOverall: Bool

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
                    if isCheapestOverall {
                        Text("CHEAPEST")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(option.bike.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(option.bike.color)
                    }
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
                Text("\(option.bikesAvailable) \(option.bikesAvailable == 1 ? "bike" : "bikes") at \(option.pickup.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
                    Text(comparison.text + " · leave now")
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
        .background(isCheapestOverall ? option.bike.color.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if isCheapestOverall {
                Rectangle().fill(option.bike.color).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    /// The time chain is symbols and arrows on screen; read aloud it needs words.
    private var accessibilitySummary: String {
        var parts = [
            "Indego \(option.bike.label.lowercased())\(isCheapestOverall ? ", cheapest option" : "")",
            "Walk \(Format.minutes(option.walkToPickup)), ride \(Format.minutes(option.rideSeconds)), walk \(Format.minutes(option.walkFromDropoff)), \(Format.minutes(option.totalDuration)) in all",
            "\(option.bikesAvailable) at \(option.pickup.name)",
            "Arrive \(Format.clock(option.arrival)), \(priceText(option.price))",
        ]
        if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
            parts.append(comparison.text)
        }
        return parts.joined(separator: ". ")
    }
}

/// The full bike-share trip: map, the three steps, and the price. Each step
/// hands off to Apple Maps for turn-by-turn directions.
struct IndegoDetailView: View {
    var option: IndegoOption
    var pass: IndegoPass
    var origin: Coordinate?
    /// True when the trip starts wherever the phone is, so the first walk can be
    /// handed to Apple Maps from "My Location"; otherwise it starts at `origin`.
    var originIsCurrentLocation: Bool
    var destination: Coordinate?
    var destinationName: String
    var reference: Date?
    var referenceNoun: String

    @EnvironmentObject private var model: CommuteModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RouteMapView(segments: segments, stops: stops)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text("Arrive \(Format.clock(option.arrival))")
                            .font(.title2.weight(.bold))
                        Text("\(Format.minutes(option.totalDuration)) door to door · leave now")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(priceText(option.price))
                            .font(.title3.weight(.semibold))
                        Text(pass.label).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let comparison = comparisonText(option.arrival, against: reference, noun: referenceNoun) {
                    Label(comparison.text, systemImage: comparison.faster ? "hare.fill" : "clock")
                        .font(.subheadline)
                }

                Button {
                    AppleMapsHandoff.open(
                        from: option.pickup.coordinate, fromName: option.pickup.name,
                        to: option.dropoff.coordinate, toName: option.dropoff.name,
                        mode: .cycling
                    )
                } label: {
                    Label("Bike directions in Apple Maps", systemImage: "bicycle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(option.bike.color)
                .foregroundStyle(option.bike.foreground)

                VStack(alignment: .leading, spacing: 0) {
                    step("figure.walk",
                         "Walk \(Format.minutes(option.walkToPickup)) to \(option.pickup.name)",
                         "\(option.pickup.classicBikes) classic · \(option.pickup.electricBikes) electric there now") {
                        AppleMapsHandoff.open(
                            from: originIsCurrentLocation ? nil : origin, fromName: "Start",
                            to: option.pickup.coordinate, toName: option.pickup.name,
                            mode: .walking
                        )
                    }
                    Divider().padding(.leading, 36)
                    step(option.bike.symbol,
                         "Ride \(Format.minutes(option.rideSeconds)) on a \(option.bike.label.lowercased())",
                         String(format: "About %.1f mi to %@", option.rideMeters * 1.3 / Coordinate.metersPerMile, option.dropoff.name)) {
                        AppleMapsHandoff.open(
                            from: option.pickup.coordinate, fromName: option.pickup.name,
                            to: option.dropoff.coordinate, toName: option.dropoff.name,
                            mode: .cycling
                        )
                    }
                    Divider().padding(.leading, 36)
                    step("figure.walk",
                         "Dock, then walk \(Format.minutes(option.walkFromDropoff)) to \(destinationName)",
                         "\(option.dropoff.openDocks) open docks at \(option.dropoff.name) now") {
                        guard let destination else { return }
                        // From the phone when the rider is at (or past) the dock;
                        // from the dock when they're still planning at home.
                        let nearDock = model.locationService.coordinate.map { $0.distance(to: option.dropoff.coordinate) < 400 } ?? false
                        AppleMapsHandoff.open(
                            from: nearDock ? nil : option.dropoff.coordinate,
                            fromName: option.dropoff.name,
                            to: destination, toName: destinationName,
                            mode: .walking
                        )
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))

                Text("Tap a step for turn-by-turn directions in Apple Maps, with spoken guidance. Dock counts are live from Indego. Ride time assumes about \(option.bike == .classic ? "9" : "12½") mph. Price for \(pass.label): \(pass.passPriceNote).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: URL(string: "https://www.rideindego.com/pricing/")!) {
                    Label("Indego pricing", systemImage: "arrow.up.right.square")
                }
            }
            .padding(20)
        }
        .navigationTitle("Indego")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens directions in Apple Maps")
    }

    private var segments: [MapSegment] {
        var result: [MapSegment] = []
        let pickup = option.pickup.coordinate.clCoordinate
        let dropoff = option.dropoff.coordinate.clCoordinate
        if let origin { result.append(MapSegment(coordinates: [origin.clCoordinate, pickup], color: MapSegment.walkColor, style: .walk)) }
        result.append(MapSegment(coordinates: [pickup, dropoff], color: option.bike.color, style: .bike))
        if let destination { result.append(MapSegment(coordinates: [dropoff, destination.clCoordinate], color: MapSegment.walkColor, style: .walk)) }
        return result
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
