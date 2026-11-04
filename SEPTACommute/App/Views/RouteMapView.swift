import MapKit
import SwiftUI

/// One stretch of a trip drawn on the map: a ride in its line colour, or a walk
/// (or bike ride) as a dotted line.
struct MapSegment: Identifiable {
    enum Style { case ride, walk, bike }
    let id = UUID()
    var coordinates: [CLLocationCoordinate2D]
    var color: Color
    var style: Style

    /// Readable on both the light and the dark map.
    static let walkColor = Color(uiColor: .label).opacity(0.8)
}

/// A labelled point: the two ends, and every place the rider changes vehicle.
struct MapStop: Identifiable {
    enum Role { case origin, destination, change, stop }
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var name: String
    var color: Color
    var role: Role
}

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The trip on a map, the way a transit app draws it: thick coloured lines for the
/// rides, dots for walking, a pin at each end. Tapping it opens it full screen.
struct RouteMapView: View {
    var segments: [MapSegment]
    var stops: [MapStop]
    var height: CGFloat = 220

    @State private var isExpanded = false

    var body: some View {
        map(interactive: false)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { isExpanded = true }
            .accessibilityElement()
            .accessibilityLabel("Map of this trip")
            .accessibilityHint("Double tap to open the map full screen")
            .accessibilityAddTraits(.isButton)
            .fullScreenCover(isPresented: $isExpanded) {
                NavigationStack {
                    map(interactive: true)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Route")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { isExpanded = false }
                            }
                        }
                }
            }
    }

    private func map(interactive: Bool) -> some View {
        Map(initialPosition: initialPosition, interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                switch segment.style {
                case .ride:
                    // A white casing under the line, like a printed transit map.
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                case .bike:
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 5]))
                case .walk:
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.5, 7]))
                }
            }
            ForEach(stops) { stop in
                switch stop.role {
                case .origin:
                    Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                        Circle().fill(.blue)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                    }
                case .destination:
                    Marker(stop.name, systemImage: "flag.checkered", coordinate: stop.coordinate)
                        .tint(Theme.accent)
                case .change:
                    Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                        Circle().fill(.white)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(stop.color, lineWidth: 3))
                    }
                case .stop:
                    Annotation("", coordinate: stop.coordinate, anchor: .center) {
                        Circle().fill(.white)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(stop.color, lineWidth: 1.5))
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            if interactive {
                MapCompass()
                MapScaleView()
                MapUserLocationButton()
            }
        }
    }

    private var initialPosition: MapCameraPosition {
        let points = segments.flatMap(\.coordinates) + stops.map(\.coordinate)
        guard !points.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for point in points {
            let p = MKMapPoint(point)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        // Breathing room so the pins aren't on the edge, and a floor so a short
        // walk isn't zoomed in to a single building.
        let minimum = 800.0 * MKMapPointsPerMeterAtLatitude(points[0].latitude)
        let width = max(rect.width, minimum)
        let height = max(rect.height, minimum)
        let padded = MKMapRect(
            x: rect.midX - width * 0.65,
            y: rect.midY - height * 0.7,
            width: width * 1.3,
            height: height * 1.4
        )
        return .rect(padded)
    }
}

// MARK: - Building a map from a Metro journey

extension RouteMapView {
    /// The map for one of the planner's journeys: walks dotted, each ride along the
    /// stations it actually passes, in its line's colour.
    init(journey: Journey, network: Network, origin: Coordinate?, destination: Coordinate?, height: CGFloat = 220) {
        var segments: [MapSegment] = []
        var stops: [MapStop] = []
        let walkColor = MapSegment.walkColor

        func coordinate(_ id: StationID) -> CLLocationCoordinate2D? {
            network.station(id)?.coordinate.clCoordinate
        }

        let rides = journey.rides
        // Where the rider is just before each leg, to draw walks from.
        var cursor: CLLocationCoordinate2D? = origin?.clCoordinate
            ?? rides.first.flatMap { coordinate($0.boardStation) }

        for (index, leg) in journey.legs.enumerated() {
            switch leg {
            case .ride(let ride):
                let color = Theme.color(for: network.line(ride.lineID))
                let path = ride.stationsServed.compactMap(coordinate)
                if let start = path.first, let cursor, cursor.distance(to: start) > 15 {
                    segments.append(MapSegment(coordinates: [cursor, start], color: walkColor, style: .walk))
                }
                segments.append(MapSegment(coordinates: path, color: color, style: .ride))
                for id in ride.stationsServed.dropFirst().dropLast() {
                    if let c = coordinate(id) { stops.append(MapStop(coordinate: c, name: "", color: color, role: .stop)) }
                }
                if let board = coordinate(ride.boardStation) {
                    stops.append(MapStop(coordinate: board, name: network.station(ride.boardStation)?.name ?? "", color: color, role: .change))
                }
                if let alight = coordinate(ride.alightStation) {
                    stops.append(MapStop(coordinate: alight, name: network.station(ride.alightStation)?.name ?? "", color: color, role: .change))
                }
                cursor = path.last
            case .walk where index == journey.legs.count - 1:
                break // drawn below to the real destination
            default:
                break
            }
        }
        if let destination = destination?.clCoordinate {
            if let cursor, cursor.distance(to: destination) > 15 {
                segments.append(MapSegment(coordinates: [cursor, destination], color: walkColor, style: .walk))
            }
            stops.append(MapStop(coordinate: destination, name: "Destination", color: Theme.accent, role: .destination))
        }
        if let origin = origin?.clCoordinate {
            stops.append(MapStop(coordinate: origin, name: "Start", color: .blue, role: .origin))
        }
        self.init(segments: segments, stops: stops, height: height)
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> Double {
        Coordinate(latitude: latitude, longitude: longitude)
            .distance(to: Coordinate(latitude: other.latitude, longitude: other.longitude))
    }
}
