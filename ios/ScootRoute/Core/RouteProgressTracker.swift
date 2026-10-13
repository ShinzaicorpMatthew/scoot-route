import Foundation
import CoreLocation

/// Suivi de la progression sur l'itinéraire : position projetée, prochaine manœuvre,
/// distance restante, dénivelé restant et détection de sortie d'itinéraire.
/// Logique pure (sans UI ni GPS) pour être testable unitairement.
struct RouteProgressTracker {
    struct State: Equatable {
        var distanceAlong: Double = 0
        var remainingDistance: Double = 0
        var remainingDuration: Double = 0
        var remainingAscent: Double = 0
        /// Index de la prochaine instruction (manœuvre à venir)
        var nextInstructionIndex: Int = 0
        var distanceToNextManeuver: Double = 0
        var distanceFromRoute: Double = 0
        var isOffRoute: Bool = false
        var hasArrived: Bool = false
        /// Segment à risque (chantier / accès incertain) dans les 250 m à venir
        var hazardAhead: RouteSegment? = nil
        /// Segment du tracé où se trouve le livreur et position « aimantée » sur le tracé
        /// (affichage de la flèche façon GPS, partie déjà parcourue en gris)
        var segmentIndex: Int = 0
        var snappedLatitude: Double? = nil
        var snappedLongitude: Double? = nil
        /// Cap du tracé à la position actuelle (degrés, 0 = nord)
        var routeBearing: Double = 0
    }

    let route: PlannedRoute
    let coords: [CLLocationCoordinate2D]
    let cumulative: [Double]
    let totalDistance: Double

    /// Tolérances
    var offRouteThreshold: Double = 30
    var offRouteConfirmations: Int = 3
    var arrivalRadius: Double = 25
    var maxUsableAccuracy: Double = 50

    private(set) var state = State()
    private var lastSegment = 0
    private var offRouteStreak = 0

    init(route: PlannedRoute) {
        self.route = route
        self.coords = route.coordinates
        self.cumulative = GeoMath.cumulativeDistances(coords)
        self.totalDistance = cumulative.last ?? route.distanceM
        state.remainingDistance = totalDistance
        state.remainingDuration = route.durationS
        state.remainingAscent = route.ascentM
        state.nextInstructionIndex = min(1, max(0, route.instructions.count - 1))
        updateManeuver(distanceAlong: 0)
        if coords.count >= 2 { state.routeBearing = GeoMath.bearing(coords[0], coords[1]) }
    }

    /// Met à jour la progression avec une nouvelle position GPS.
    /// - Returns: l'état mis à jour. Les positions trop imprécises sont ignorées pour la détection de sortie.
    @discardableResult
    mutating func update(location: CLLocationCoordinate2D, horizontalAccuracy: Double) -> State {
        guard coords.count >= 2 else { return state }

        // Recherche locale (vers l'avant) puis globale si on semble perdu
        var proj = GeoMath.project(location, on: coords, cumulative: cumulative,
                                   range: (lastSegment - 3)..<(lastSegment + 80))
        if proj == nil || proj!.distanceFromLine > offRouteThreshold {
            if let global = GeoMath.project(location, on: coords, cumulative: cumulative),
               global.distanceFromLine < (proj?.distanceFromLine ?? .infinity) {
                proj = global
            }
        }
        guard let p = proj else { return state }

        let reliableFix = horizontalAccuracy >= 0 && horizontalAccuracy <= maxUsableAccuracy
        let tolerance = max(offRouteThreshold, horizontalAccuracy * 1.5)
        if reliableFix {
            if p.distanceFromLine > tolerance { offRouteStreak += 1 } else { offRouteStreak = 0 }
        }
        state.distanceFromRoute = p.distanceFromLine
        state.isOffRoute = offRouteStreak >= offRouteConfirmations

        // On ne recule pas si le GPS fluctue (sauf grand saut confirmé)
        if p.distanceFromLine <= tolerance {
            if p.distanceAlong >= state.distanceAlong - 15 || p.segmentIndex > lastSegment {
                lastSegment = p.segmentIndex
                state.distanceAlong = max(state.distanceAlong, p.distanceAlong)
            }
            let a = coords[p.segmentIndex], b = coords[p.segmentIndex + 1]
            state.segmentIndex = p.segmentIndex
            state.snappedLatitude = a.latitude + (b.latitude - a.latitude) * p.fraction
            state.snappedLongitude = a.longitude + (b.longitude - a.longitude) * p.fraction
            state.routeBearing = GeoMath.bearing(a, b)
        } else {
            state.snappedLatitude = nil
            state.snappedLongitude = nil
        }

        let along = state.distanceAlong
        state.remainingDistance = max(0, totalDistance - along)
        state.remainingDuration = totalDistance > 0 ? route.durationS * state.remainingDistance / totalDistance : 0
        state.remainingAscent = Self.remainingAscent(profile: route.elevationSamples, from: along)
        state.hasArrived = state.remainingDistance <= arrivalRadius
            || GeoMath.distance(location, coords[coords.count - 1]) <= arrivalRadius
        updateManeuver(distanceAlong: along)
        state.hazardAhead = route.segments.first { seg in
            (seg.worksId != nil || seg.accessUncertain)
                && seg.startM + seg.lengthM > along
                && seg.startM - along < 250
        }
        return state
    }

    private mutating func updateManeuver(distanceAlong along: Double) {
        let ins = route.instructions
        guard !ins.isEmpty else { return }
        // Prochaine instruction = première dont le point de départ est devant nous (marge 5 m)
        var next = ins.count - 1
        for (i, instruction) in ins.enumerated() where i > 0 {
            let idx = min(max(0, instruction.pointIndex), cumulative.count - 1)
            if cumulative[idx] > along + 5 { next = i; break }
        }
        state.nextInstructionIndex = next
        let idx = min(max(0, ins[next].pointIndex), cumulative.count - 1)
        state.distanceToNextManeuver = max(0, cumulative[idx] - along)
    }

    /// Dénivelé positif restant (seuil 1,5 m pour ignorer le bruit), sans compensation par les descentes.
    static func remainingAscent(profile: [ElevationSample], from distance: Double) -> Double {
        let ahead = profile.filter { $0.distance >= distance }
        guard var ref = ahead.first?.altitude else { return 0 }
        var ascent = 0.0
        for s in ahead.dropFirst() {
            let diff = s.altitude - ref
            if diff >= 1.5 { ascent += diff; ref = s.altitude }
            else if diff <= -1.5 { ref = s.altitude }
        }
        return ascent
    }
}
