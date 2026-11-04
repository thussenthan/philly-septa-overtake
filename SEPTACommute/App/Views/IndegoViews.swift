import SwiftUI

extension IndegoBike {
    var symbol: String { self == .classic ? "bicycle" : "bolt.fill" }
    /// Indego's own blue for classic, a green for electric.
    var color: Color { self == .classic ? Theme.adaptive("0076BE") : Theme.adaptive("2E9E44") }
}

/// One Indego row on the home screen.
struct IndegoRow: View {
    var option: IndegoOption
    /// The Metro recommendation, to say what the bike gains or costs against it.
    var reference: Date?
    /// True when this is the cheapest (classic) bike and should stand out.
    var highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: option.bike.symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 24)
                .background(option.bike.color, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Indego \(option.bike.label.lowercased())")
                        .font(.subheadline.weight(.semibold))
                    if highlighted {
                        Text("CHEAPEST")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(option.bike.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(option.bike.color)
                    }
                }
                Text("\(Format.minutes(option.walkToPickup)) walk · \(option.bikesAvailable) \(option.bikesAvailable == 1 ? "bike" : "bikes") at \(option.pickup.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(deltaText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(deltaColor)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(option.arrival))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(option.price < 0.005 ? "Included" : "≈ " + Format.money(option.price))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(highlighted ? option.bike.color.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if highlighted {
                Rectangle().fill(option.bike.color).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }

    private var delta: TimeInterval? {
        reference.map { option.arrival.timeIntervalSince($0) }
    }

    private var deltaText: String {
        let ride = "\(Format.minutes(option.rideSeconds)) ride · leave now"
        guard let delta else { return ride }
        if abs(delta) < 60 { return "Same arrival as the train · " + ride }
        return (delta < 0 ? "\(Format.minutes(-delta)) sooner" : "\(Format.minutes(delta)) later") + " than the train · " + ride
    }

    private var deltaColor: Color {
        guard let delta else { return .secondary }
        return delta < -60 ? .green : .secondary
    }
}

/// The full bike-share trip: map, the three steps, and the price.
struct IndegoDetailView: View {
    var option: IndegoOption
    var pass: IndegoPass
    var origin: Coordinate?
    var destination: Coordinate?
    var reference: Date?

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
                        Text(option.price < 0.005 ? "Included" : "≈ " + Format.money(option.price))
                            .font(.title3.weight(.semibold))
                        Text(pass.label).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let reference {
                    let delta = option.arrival.timeIntervalSince(reference)
                    Label(
                        abs(delta) < 60 ? "Arrives about when the recommended train does"
                            : delta < 0 ? "\(Format.minutes(-delta)) sooner than the recommended train"
                            : "\(Format.minutes(delta)) later than the recommended train",
                        systemImage: delta < -60 ? "hare.fill" : "clock"
                    )
                    .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 14) {
                    step("figure.walk", "Walk \(Format.minutes(option.walkToPickup)) to \(option.pickup.name)",
                         "\(option.pickup.classicBikes) classic · \(option.pickup.electricBikes) electric there now")
                    step(option.bike.symbol, "Ride \(Format.minutes(option.rideSeconds)) on a \(option.bike.label.lowercased())",
                         String(format: "About %.1f mi", option.rideMeters * 1.3 / Coordinate.metersPerMile))
                    step("parkingsign.circle", "Dock at \(option.dropoff.name)",
                         "\(option.dropoff.openDocks) open docks now")
                    step("figure.walk", "Walk \(Format.minutes(option.walkFromDropoff)) to your destination", nil)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))

                Text("Dock counts are live from Indego. Ride time assumes about \(option.bike == .classic ? "9" : "12½") mph; the price is an estimate for \(pass.label.lowercased()) (\(pass.passPriceNote)). Check rideindego.com for current rates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: URL(string: "https://www.rideindego.com/")!) {
                    Label("Open Indego", systemImage: "arrow.up.right.square")
                }
            }
            .padding(20)
        }
        .navigationTitle("Indego")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
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
        if let destination { result.append(MapStop(coordinate: destination.clCoordinate, name: "Destination", color: Theme.accent, role: .destination)) }
        return result
    }
}
