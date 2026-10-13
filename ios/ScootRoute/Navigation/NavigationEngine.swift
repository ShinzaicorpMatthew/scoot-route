import Foundation
import CoreLocation
import UIKit
import Observation

/// Pilote une session de navigation : progression, annonces vocales, alertes,
/// recalcul automatique en cas de sortie d'itinéraire, gestion GPS / réseau.
@MainActor
@Observable
final class NavigationEngine {
    enum Banner: Equatable {
        case rerouting
        case rerouteFailed(String)
        case gpsWeak
        case offline
        case hazard(String)
    }

    private(set) var route: PlannedRoute
    private(set) var progress: RouteProgressTracker.State
    private(set) var banner: Banner?
    private(set) var isRerouting = false
    private(set) var rerouteCount = 0
    private(set) var arrived = false
    private(set) var currentSpeedKmh: Double = 0
    private(set) var traveledDistance: Double = 0
    let destination: Place
    let origin: Place
    let startDate = Date()
    let batteryAtStart: Double

    @ObservationIgnored private var tracker: RouteProgressTracker
    @ObservationIgnored private let api: RoutingAPI
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private var weights: RouteWeights
    @ObservationIgnored private var maxSpeedKmh: Double
    @ObservationIgnored private var lastRerouteAttempt = Date.distantPast
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastGpsCheck: Timer?

    @ObservationIgnored var isOnline: @MainActor () -> Bool = { true }

    init(route: PlannedRoute, origin: Place, destination: Place, weights: RouteWeights, maxSpeedKmh: Double,
         batteryAtStart: Double, voiceEnabled: Bool, api: RoutingAPI = .shared) {
        self.route = route
        self.origin = origin
        self.destination = destination
        self.weights = weights
        self.maxSpeedKmh = maxSpeedKmh
        self.batteryAtStart = batteryAtStart
        self.api = api
        let speech = SpeechService()
        speech.isEnabled = voiceEnabled
        self.speech = speech
        let tracker = RouteProgressTracker(route: route)
        self.tracker = tracker
        self.progress = tracker.state
    }

    var nextInstruction: RouteInstruction? {
        route.instructions.indices.contains(progress.nextInstructionIndex)
            ? route.instructions[progress.nextInstructionIndex] : nil
    }

    /// À l'arrêt ou presque : l'interface autorise les interactions (signalement, options).
    var isStopped: Bool { currentSpeedKmh < 6 }

    var voiceEnabled: Bool {
        get { speech.isEnabled }
        set { speech.isEnabled = newValue; if !newValue { speech.stop() } }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        speech.prepare()
        let first = route.instructions.first?.text ?? "C'est parti"
        speech.speak("\(first). Destination \(destination.title), \(Fmt.distance(route.distanceM)).")
        lastGpsCheck = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignal() }
        }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        lastGpsCheck?.invalidate()
        speech.stop()
    }

    // MARK: Mises à jour GPS

    func handle(location: CLLocation) {
        if let prev = lastLocation, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 40 {
            let d = location.distance(from: prev)
            if d < 200 { traveledDistance += d }
        }
        lastLocation = location
        currentSpeedKmh = max(0, location.speed) * 3.6
        if banner == .gpsWeak { banner = nil }

        progress = tracker.update(location: location.coordinate, horizontalAccuracy: location.horizontalAccuracy)

        if progress.hasArrived && !arrived {
            arrived = true
            speech.speak("Vous êtes arrivé : \(destination.title).", interrupt: true)
            return
        }
        if progress.isOffRoute {
            reroute(from: location)
            return
        }
        announceManeuver()
        announceHazard()
    }

    private func checkSignal() {
        if let date = lastLocation?.timestamp, Date().timeIntervalSince(date) > 10 {
            banner = .gpsWeak
        }
        if !isOnline(), banner == nil { banner = .offline }
        if isOnline(), banner == .offline { banner = nil }
    }

    // MARK: Annonces vocales

    private func announceManeuver() {
        guard let ins = nextInstruction else { return }
        let d = progress.distanceToNextManeuver
        let key = "\(progress.nextInstructionIndex)"
        // Annonce anticipée (~150 m) puis imminente (~30 m)
        if d <= 170, d > 60, !announced.contains(key + "-far") {
            announced.insert(key + "-far")
            speech.speak("\(Fmt.spokenDistance(d)), \(lowercasedFirst(ins.text))")
        } else if d <= 35, !announced.contains(key + "-near") {
            announced.insert(key + "-near")
            speech.speak(ins.text)
        }
    }

    private func announceHazard() {
        guard let seg = progress.hazardAhead else {
            if case .hazard = banner { banner = nil }
            return
        }
        let text: String
        if seg.worksId != nil {
            text = "Chantier signalé par la Métropole sur votre trajet"
        } else if seg.accessReason == "pedestrian" {
            text = "Zone piétonne : trottinette à la main"
        } else {
            text = "Accès trottinette incertain sur la portion à venir"
        }
        banner = .hazard(text)
        let key = "hazard-\(seg.fromIndex)"
        if !announced.contains(key) {
            announced.insert(key)
            speech.speak(text)
        }
    }

    private func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    // MARK: Recalcul

    private func reroute(from location: CLLocation) {
        guard !isRerouting, Date().timeIntervalSince(lastRerouteAttempt) > 8 else { return }
        guard isOnline() else {
            banner = .rerouteFailed("Hors ligne : impossible de recalculer. Revenez sur le tracé bleu.")
            return
        }
        isRerouting = true
        banner = .rerouting
        lastRerouteAttempt = Date()
        speech.speak("Recalcul de l'itinéraire", interrupt: true)
        let heading = location.course >= 0 && location.speed > 1.5 ? location.course : nil
        Task {
            defer { isRerouting = false }
            do {
                let plan = try await api.planRoutes(
                    from: location.coordinate, to: destination.coordinate, weights: weights,
                    maxSpeedKmh: maxSpeedKmh, profiles: [route.reroutingProfile], heading: heading)
                guard let newRoute = plan.routes.first else { throw APIError.invalidResponse }
                route = newRoute
                tracker = RouteProgressTracker(route: newRoute)
                progress = tracker.state
                announced.removeAll()
                rerouteCount += 1
                banner = nil
                speech.speak("Nouvel itinéraire : \(Fmt.duration(newRoute.durationS)).")
            } catch {
                banner = .rerouteFailed(error.localizedDescription)
            }
        }
    }

    /// Relance manuelle (bouton) en cas d'échec du recalcul automatique.
    func retryReroute() {
        guard let loc = lastLocation else { return }
        lastRerouteAttempt = .distantPast
        reroute(from: loc)
    }
}
