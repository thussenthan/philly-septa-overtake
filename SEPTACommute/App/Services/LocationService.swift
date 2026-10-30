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

        /// The fix and when it was taken, so nothing downstream has to pretend a
        /// location from this morning is from this second.
        var fix: (coordinate: Coordinate, at: Date)? {
            if case .located(let coordinate, _, let at) = self { return (coordinate, at) }
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
    var fix: (coordinate: Coordinate, at: Date)? { status.fix }

    /// Gives up waiting for a usable fix, so "Finding you…" can't last forever.
    private var locatingTimeout: Task<Void, Never>?
    private static let locatingTimeoutSeconds: UInt64 = 15
    /// A fix older than this isn't trusted as where the rider is now.
    private static let staleFixSeconds: TimeInterval = 120

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
        // Judged by what the system says now, not by the status last recorded: after
        // a rider turns location on in Settings the status still reads "denied", and
        // checking it here meant the app never started again until it was relaunched.
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: return
        }
        // Coming back after a while: the old fix says where the rider *was*.
        let stale = status.fix.map { Date().timeIntervalSince($0.at) > Self.staleFixSeconds } ?? false
        if status.coordinate == nil || stale {
            status = .locating
            armLocatingTimeout()
        }
        manager.startUpdatingLocation()
        // A cached fix, if there is one, beats an empty screen while the first
        // real update arrives.
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -120 {
            accept(cached)
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        locatingTimeout?.cancel()
    }

    private func armLocatingTimeout() {
        locatingTimeout?.cancel()
        locatingTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.locatingTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.status == .locating else { return }
            self.status = .failed(
                self.manager.accuracyAuthorization == .reducedAccuracy
                    ? "Precise Location is turned off for Overtake."
                    : "Couldn't get a precise location."
            )
        }
    }

    /// Ask for one fresh fix, e.g. on a pull-to-refresh.
    func refresh() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: return
        }
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
        locatingTimeout?.cancel()
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
