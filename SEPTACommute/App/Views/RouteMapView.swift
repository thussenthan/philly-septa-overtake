import MapKit
import SwiftUI

/// One stretch of a trip drawn on the map: a ride in its line colour, or a walk
/// (or bike ride) as a dotted line.
struct MapSegment: Identifiable {
    enum Style { case ride, walk, bike }
    var coordinates: [CLLocationCoordinate2D]
    var color: Color
    var style: Style
    /// For a Metro ride drawn station to station: the route, so the map can
    /// swap in SEPTA's real track geometry once the shapes are loaded.
    var routeShortName: String? = nil

    /// Readable on both the light and the dark map.
    static let walkColor = Color(uiColor: .label).opacity(0.8)

    /// Stable across redraws — the views rebuild their segments on every render,
    /// and routed street geometry is looked up by this.
    var id: String {
        let a = coordinates.first, b = coordinates.last
        return String(format: "%@ %.5f %.5f %.5f %.5f %d", "\(style)",
                      a?.latitude ?? 0, a?.longitude ?? 0, b?.latitude ?? 0, b?.longitude ?? 0, coordinates.count)
    }
}

/// A labelled point: the two ends, and every place the rider changes vehicle.
struct MapStop: Identifiable {
    enum Role { case origin, destination, change, stop }
    var coordinate: CLLocationCoordinate2D
    var name: String
    var color: Color
    var role: Role

    /// Stable across redraws, so annotations aren't torn down and rebuilt every
    /// time the screen re-renders.
    var id: String {
        String(format: "%@ %.6f %.6f %@", "\(role)", coordinate.latitude, coordinate.longitude, name)
    }
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
    /// A segment to zoom to, with the rest dimmed; nil shows the whole trip.
    var focus: Int? = nil

    @State private var isExpanded = false
    @State private var camera: MapCameraPosition?
    /// Street-following geometry for walk and bike legs, once MapKit answers.
    @State private var routed: [String: [CLLocationCoordinate2D]] = [:]

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
            .task(id: segments.map(\.id).joined(separator: "|")) {
                await routeStreetLegs()
            }
            // A new focus (or the street routes arriving) reframes the camera.
            .onChange(of: focus) { _, newFocus in
                withAnimation(.easeInOut) { camera = fitting(newFocus) }
            }
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
        Map(position: Binding(get: { camera ?? fitting(focus) }, set: { camera = $0 }),
            interactionModes: interactive ? .all : []) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, original in
                let segment = dimmed(resolved(original), index: index)
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
            // Where the phone is, and which way it's facing — the blue dot and
            // heading cone, as in Apple Maps. Shown only with location allowed.
            UserAnnotation()
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

    private func resolved(_ segment: MapSegment) -> MapSegment {
        guard let path = routed[segment.id] else { return segment }
        var copy = segment
        copy.coordinates = path
        return copy
    }

    /// Replace each straight walk or bike line with MapKit's route along streets.
    /// The straight line stays if there's no connection — it's still the right
    /// two ends.
    private func routeStreetLegs() async {
        // Rides from the Metro planner know only their stations; SEPTA's published
        // route shape is the line the train actually follows.
        let rides = segments.filter { $0.style == .ride && $0.routeShortName != nil }
        if !rides.isEmpty {
            let shaped = await Task.detached(priority: .userInitiated) { () -> [(String, [CLLocationCoordinate2D])] in
                guard let network = ExtendedData.network else { return [] }
                return rides.compactMap { segment in
                    let stops = segment.coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
                    guard let path = network.shapePath(routeShortName: segment.routeShortName!, through: stops) else { return nil }
                    return (segment.id, path.map(\.clCoordinate))
                }
            }.value
            for (id, path) in shaped { routed[id] = path }
        }

        for segment in segments where segment.style != .ride && segment.coordinates.count == 2 {
            if Task.isCancelled { return }
            guard let from = segment.coordinates.first, let to = segment.coordinates.last,
                  from.distance(to: to) > 40 else { continue }
            let type: MKDirectionsTransportType = segment.style == .bike ? .cycling : .walking
            if let path = await StreetRoutes.shared.path(from: from, to: to, type: type) {
                routed[segment.id] = path
            }
        }
    }

    /// Everything but the focused segment fades back.
    private func dimmed(_ segment: MapSegment, index: Int) -> MapSegment {
        guard let focus, focus != index else { return segment }
        var copy = segment
        copy.color = copy.color.opacity(0.3)
        return copy
    }

    /// The camera framing the focused segment, or the whole trip.
    private func fitting(_ focus: Int?) -> MapCameraPosition {
        if let focus, segments.indices.contains(focus) {
            let segment = resolved(segments[focus])
            return frame(segment.coordinates, minimumMeters: 300)
        }
        return frame(segments.map(resolved).flatMap(\.coordinates) + stops.map(\.coordinate), minimumMeters: 800)
    }

    private func frame(_ points: [CLLocationCoordinate2D], minimumMeters: Double) -> MapCameraPosition {
        guard !points.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for point in points {
            let p = MKMapPoint(point)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        // Breathing room so the pins aren't on the edge, and a floor so a short
        // walk isn't zoomed in to a single building.
        let minimum = minimumMeters * MKMapPointsPerMeterAtLatitude(points[0].latitude)
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
                segments.append(MapSegment(coordinates: path, color: color, style: .ride, routeShortName: ride.routeBadge))
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

/// MapKit walking and cycling routes, cached for the session so revisiting a trip
/// or redrawing a map doesn't ask Apple again.
actor StreetRoutes {
    static let shared = StreetRoutes()
    private var cache: [String: [CLLocationCoordinate2D]] = [:]
    /// Requests that failed (offline, or MapKit throttling), and when — retried
    /// only after a pause rather than on every redraw.
    private var failures: [String: Date] = [:]

    private static func key(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, _ type: MKDirectionsTransportType) -> String {
        String(format: "%.5f,%.5f>%.5f,%.5f#%lu", from.latitude, from.longitude, to.latitude, to.longitude, type.rawValue)
    }

    /// A route fetched elsewhere (timing a bike ride), so drawing it on a map
    /// doesn't cost a second request against Apple's per-minute limit.
    func store(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, type: MKDirectionsTransportType, path: [CLLocationCoordinate2D]) {
        cache[Self.key(from, to, type)] = path
    }

    func path(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, type: MKDirectionsTransportType) async -> [CLLocationCoordinate2D]? {
        let key = Self.key(from, to, type)
        if let hit = cache[key] { return hit }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 120 { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = type
        guard let route = try? await MKDirections(request: request).calculate().routes.first else {
            failures[key] = Date()
            return nil
        }
        let polyline = route.polyline
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        cache[key] = points
        return points
    }
}

/// Which app turn-by-turn directions open in. Set in Settings.
enum MapsApp: String, Codable, CaseIterable, Identifiable {
    case apple, google

    var id: String { rawValue }
    var label: String { self == .apple ? "Apple Maps" : "Google Maps" }
}

/// Hands a leg off to the rider's maps app for turn-by-turn directions — spoken
/// directions included, which is what a rider with AirPods in actually wants.
enum MapsHandoff {
    enum Mode {
        case walking, cycling, transit

        var launchValue: String {
            switch self {
            case .walking: return MKLaunchOptionsDirectionsModeWalking
            case .cycling: return MKLaunchOptionsDirectionsModeCycling
            case .transit: return MKLaunchOptionsDirectionsModeTransit
            }
        }

        var googleTravelMode: String {
            switch self {
            case .walking: return "walking"
            case .cycling: return "bicycling"
            case .transit: return "transit"
            }
        }
    }

    /// `from: nil` starts from wherever the phone is.
    @MainActor
    static func open(app: MapsApp, from: Coordinate?, fromName: String? = nil, to: Coordinate, toName: String, mode: Mode) {
        switch app {
        case .apple:
            let source: MKMapItem
            if let from {
                source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
                source.name = fromName
            } else {
                source = MKMapItem.forCurrentLocation()
            }
            let destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
            destination.name = toName
            MKMapItem.openMaps(with: [source, destination], launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launchValue])
        case .google:
            // Google's universal link: opens the Google Maps app when it's
            // installed, the website when it isn't. No origin means "my location".
            var components = URLComponents(string: "https://www.google.com/maps/dir/")!
            var items = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: "\(to.latitude),\(to.longitude)"),
                URLQueryItem(name: "travelmode", value: mode.googleTravelMode),
                URLQueryItem(name: "dir_action", value: "navigate"),
            ]
            if let from { items.append(URLQueryItem(name: "origin", value: "\(from.latitude),\(from.longitude)")) }
            components.queryItems = items
            if let url = components.url { UIApplication.shared.open(url) }
        }
    }
}
