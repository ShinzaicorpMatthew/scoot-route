import Foundation
import CoreLocation
import Observation

/// Géolocalisation : position courante, autorisations et suivi de navigation en arrière-plan.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastFixDate: Date?
    private(set) var isNavigating = false

    /// Appelé à chaque nouvelle position pendant la navigation.
    @ObservationIgnored var onNavigationUpdate: (@MainActor (CLLocation) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .otherNavigation
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Qualité du signal : nil si aucune position récente
    var signalIsWeak: Bool {
        guard let loc = location, let date = lastFixDate else { return true }
        return Date().timeIntervalSince(date) > 10 || loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 65
    }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        requestPermission()
        manager.startUpdatingLocation()
    }

    /// Mode navigation : précision maximale et poursuite en arrière-plan (indicateur bleu iOS).
    func startNavigation() {
        isNavigating = true
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        if Bundle.main.backgroundModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
    }

    func stopNavigation() {
        isNavigating = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        onNavigationUpdate = nil
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.location = last
            self.lastFixDate = Date()
            if self.isNavigating { self.onNavigationUpdate?(last) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Perte temporaire du GPS : on conserve la dernière position, l'UI affiche « signal faible ».
    }
}

private extension Bundle {
    var backgroundModes: [String] {
        object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    }
}
