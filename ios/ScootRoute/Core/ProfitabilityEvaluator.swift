import Foundation

/// Seuils de rentabilité choisis par le livreur (Réglages > Offre).
struct OfferSettings: Codable, Equatable {
    /// Gain horaire visé (€/h) : au-dessus → « Rentable »
    var targetEurPerHour: Double = 15
    /// Gain minimum par kilomètre parcouru (€/km)
    var minEurPerKm: Double = 1.0
    /// Attente moyenne au restaurant (min)
    var waitAtRestaurantMin: Double = 5
    /// Remise de la commande au client : parking, étage, porte (min)
    var handoffMin: Double = 3
}

/// Un trajet calculé par le serveur Scoot Route (en trottinette, avec le relief).
struct OfferLeg: Codable, Equatable {
    var distanceM: Double
    var durationS: Double
    var ascentM: Double
    var descentM: Double
}

struct OfferEvaluation: Codable, Equatable {
    enum Verdict: String, Codable { case good, average, bad }
    enum Source: String, Codable {
        /// Trajets recalculés en trottinette (position → restaurant → client)
        case scooterRoute
        /// Distance et durée lues sur l'offre (estimation de l'app de livraison)
        case announced
    }

    var verdict: Verdict
    var source: Source
    var priceEur: Double
    var eurPerHour: Double
    var eurPerKm: Double
    var totalMinutes: Double
    var totalKm: Double
    var ascentM: Double
    var batteryUsedPercent: Double
    var batteryAtEndPercent: Double
    var reasons: [String]

    var verdictLabel: String {
        switch verdict {
        case .good: return "Rentable"
        case .average: return "Moyen"
        case .bad: return "Pas rentable"
        }
    }

    var verdictEmoji: String {
        switch verdict {
        case .good: return "✅"
        case .average: return "🟠"
        case .bad: return "❌"
        }
    }

    /// Phrase courte affichée par le raccourci (notification) sans ouvrir l'app.
    var summary: String {
        let climb = ascentM >= 10 ? " · ↑\(Int(ascentM.rounded())) m" : ""
        return "\(verdictEmoji) \(verdictLabel) : \(Self.eur(eurPerHour))/h · \(Self.eur(eurPerKm))/km\n"
            + "\(Self.eur(priceEur)) pour \(Int(totalMinutes.rounded())) min et \(Self.km(totalKm))\(climb)"
            + " · batterie \(Int(max(0, batteryAtEndPercent).rounded())) % à la fin"
    }

    static func eur(_ v: Double) -> String {
        String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",")
    }

    static func km(_ v: Double) -> String {
        String(format: "%.1f km", v).replacingOccurrences(of: ".", with: ",")
    }
}

enum ProfitabilityEvaluator {
    /// - Parameters:
    ///   - legs: trajets trottinette (approche + livraison) ; nil si les adresses n'ont pas pu être localisées
    ///   - announcedKm / announcedMin: valeurs lues sur l'offre, utilisées à défaut de trajets
    static func evaluate(priceEur: Double, legs: [OfferLeg]?, announcedKm: Double?, announcedMin: Double?,
                         settings: OfferSettings, vehicle: VehicleProfile) -> OfferEvaluation? {
        guard priceEur > 0 else { return nil }
        var reasons: [String] = []

        let source: OfferEvaluation.Source
        var meters: Double, rideSeconds: Double, ascent: Double, descent: Double
        if let legs, !legs.isEmpty {
            source = .scooterRoute
            meters = legs.reduce(0) { $0 + $1.distanceM }
            rideSeconds = legs.reduce(0) { $0 + $1.durationS }
            ascent = legs.reduce(0) { $0 + $1.ascentM }
            descent = legs.reduce(0) { $0 + $1.descentM }
            if legs.count == 1 { reasons.append("Trajet jusqu'au restaurant non compté (position inconnue)") }
        } else if let km = announcedKm, km > 0 {
            source = .announced
            meters = km * 1000
            // Sans durée annoncée : vitesse de croisière du livreur
            rideSeconds = (announcedMin ?? (km / max(5, vehicle.cruiseSpeedKmh) * 60)) * 60
            ascent = 0
            descent = 0
            reasons.append("Basé sur la distance de l'offre : relief non pris en compte")
        } else {
            return nil
        }

        // Temps total : roulage + attente au restaurant + remise au client
        let stopMinutes = settings.waitAtRestaurantMin + settings.handoffMin
        let totalMinutes = rideSeconds / 60 + (source == .scooterRoute ? stopMinutes : settings.handoffMin)
        let totalKm = meters / 1000
        let eurPerHour = priceEur / max(1, totalMinutes) * 60
        let eurPerKm = priceEur / max(0.2, totalKm)

        let battery = BatteryEstimator.estimate(distanceM: meters, durationS: rideSeconds,
                                                ascentM: ascent, descentM: descent, vehicle: vehicle)

        var verdict: OfferEvaluation.Verdict
        let hourOK = eurPerHour >= settings.targetEurPerHour
        let kmOK = eurPerKm >= settings.minEurPerKm
        if hourOK && kmOK {
            verdict = .good
        } else if eurPerHour >= settings.targetEurPerHour * 0.8 && eurPerKm >= settings.minEurPerKm * 0.8 {
            verdict = .average
        } else {
            verdict = .bad
        }
        if !hourOK { reasons.append("Sous votre objectif de \(OfferEvaluation.eur(settings.targetEurPerHour))/h") }
        if !kmOK { reasons.append("Sous votre minimum de \(OfferEvaluation.eur(settings.minEurPerKm))/km") }
        if ascent >= 40 { reasons.append("Montées importantes : \(Int(ascent.rounded())) m de dénivelé") }
        if battery.risk == .insufficient {
            verdict = .bad
            reasons.append("Batterie probablement insuffisante")
        } else if battery.risk == .tight {
            reasons.append("Batterie juste après cette course")
        }

        return OfferEvaluation(
            verdict: verdict, source: source, priceEur: priceEur,
            eurPerHour: eurPerHour, eurPerKm: eurPerKm, totalMinutes: totalMinutes, totalKm: totalKm,
            ascentM: ascent, batteryUsedPercent: battery.percentUsed,
            batteryAtEndPercent: battery.arrivalPercent, reasons: reasons)
    }
}
