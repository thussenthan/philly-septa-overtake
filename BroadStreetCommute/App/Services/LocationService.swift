import CoreLocation
import Foundation

// Note for anyone splitting this project up later: MetroKit's types are used
// here without an `import MetroKit`. The Xcode target compiles MetroKit's sources
// into the app module directly (see the synchronized group in the project), so
// they are already in scope. Package.swift exposes the same sources as a module
// purely so `swift test` can reach them.

/// Wraps CoreLocation in something a view can watch.
@MainActor
final class LocationService: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case requestingPermission
        case denied
        case restricted
        case locating
        case located(Coordinate, accuracy: Double, at: Date)
        case failed(String)

        var coordinate: Coordinate? {
            if case .located(let coordinate, _, _) = self { return coordinate }
            return nil
        }

        var isDenied: Bool { self == .denied || self == .restricted }
    }

    @Published private(set) var status: Status = .idle

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // A rider walking to a station moves tens of metres between useful
        // updates; anything finer just burns battery and churns the UI.
        manager.distanceFilter = 25
        syncAuthorization()
    }

    var coordinate: Coordinate? { status.coordinate }

    func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .requestingPermission
            manager.requestWhenInUseAuthorization()
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        default:
            start()
        }
    }

    func start() {
        guard !status.isDenied else { return }
        if status.coordinate == nil { status = .locating }
        manager.startUpdatingLocation()
        // A cached fix, if there is one, beats an empty screen while the first
        // real update arrives.
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -120 {
            accept(cached)
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Ask for one fresh fix, e.g. on a pull-to-refresh.
    func refresh() {
        guard !status.isDenied else { return }
        manager.requestLocation()
    }

    private func syncAuthorization() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            start()
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        case .notDetermined:
            status = .idle
        @unknown default:
            status = .idle
        }
    }

    private func accept(_ location: CLLocation) {
        accept(Fix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        ))
    }

    /// The parts of a `CLLocation` we need, in a form that can cross actors.
    fileprivate struct Fix: Sendable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var timestamp: Date
    }

    fileprivate func accept(_ fix: Fix) {
        // A fix accurate to only half a kilometre would put the rider at the
        // wrong station; better to keep waiting than to route from the wrong place.
        guard fix.accuracy >= 0, fix.accuracy < 250 else { return }
        status = .located(
            Coordinate(latitude: fix.latitude, longitude: fix.longitude),
            accuracy: fix.accuracy,
            at: fix.timestamp
        )
    }

    fileprivate func handle(failure description: String, isDenied: Bool) {
        // A transient failure while we already have a fix is not worth throwing
        // away a working screen for.
        guard status.coordinate == nil else { return }
        status = isDenied ? .denied : .failed(description)
    }
}

// The delegate methods are `nonisolated` and hop to the main actor with plain
// values, rather than assuming CoreLocation's callback queue.
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.syncAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let fix = Fix(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            accuracy: latest.horizontalAccuracy,
            timestamp: latest.timestamp
        )
        Task { @MainActor [weak self] in self?.accept(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let isDenied = (error as? CLError)?.code == .denied
        let description = error.localizedDescription
        Task { @MainActor [weak self] in self?.handle(failure: description, isDenied: isDenied) }
    }
}
