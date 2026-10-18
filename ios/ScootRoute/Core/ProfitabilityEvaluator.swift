import Foundation

/// Seuils de décision choisis par le livreur (onglet Offre › Mes critères). Tous sont visibles
/// et modifiables dans l'app ; les valeurs par défaut ne sont que des points de départ.
struct OfferSettings: Codable, Equatable {
    /// ACCEPTER si le gain horaire atteint ce seuil (€/h)…
    var targetEurPerHour: Double = 15
    /// … REFUSER en dessous de celui-ci (€/h). Entre les deux : À ÉVALUER.
    var minEurPerHour: Double = 12
    /// ACCEPTER si le gain par kilomètre atteint ce seuil (€/km)…
    var minEurPerKm: Double = 1.0
    /// … REFUSER en dessous de celui-ci (€/km).
    var refuseEurPerKm: Double = 0.8
    /// Attente moyenne au restaurant (min)
    var waitAtRestaurantMin: Double = 5
    /// Remise de la commande au client : parking, étage, porte (min)
    var handoffMin: Double = 3
    /// Frais variables de la trottinette par km (électricité, pneus, freins, usure batterie).
    /// nil = non renseigné : aucun calcul « après frais » n'est fait.
    var operatingCostPerKm: Double? = nil
    /// Taux de cotisations sociales appliqué au chiffre d'affaires (%), à renseigner soi-même
    /// (taux URSSAF de son statut). nil = non pris en compte.
    var socialChargesPercent: Double? = nil
    /// Juger les seuils sur le gain après frais variables plutôt que sur le montant brut
    var judgeAfterCosts: Bool = false
}

extension OfferSettings {
    /// Lecture tolérante : les réglages enregistrés par une version précédente restent valables.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OfferSettings()
        targetEurPerHour = try c.decodeIfPresent(Double.self, forKey: .targetEurPerHour) ?? d.targetEurPerHour
        minEurPerKm = try c.decodeIfPresent(Double.self, forKey: .minEurPerKm) ?? d.minEurPerKm
        // Anciennes versions : « Moyen » au-dessus de 80 % des objectifs
        minEurPerHour = try c.decodeIfPresent(Double.self, forKey: .minEurPerHour) ?? (targetEurPerHour * 0.8).rounded()
        refuseEurPerKm = try c.decodeIfPresent(Double.self, forKey: .refuseEurPerKm) ?? minEurPerKm * 0.8
        waitAtRestaurantMin = try c.decodeIfPresent(Double.self, forKey: .waitAtRestaurantMin) ?? d.waitAtRestaurantMin
        handoffMin = try c.decodeIfPresent(Double.self, forKey: .handoffMin) ?? d.handoffMin
        operatingCostPerKm = try c.decodeIfPresent(Double.self, forKey: .operatingCostPerKm)
        socialChargesPercent = try c.decodeIfPresent(Double.self, forKey: .socialChargesPercent)
        judgeAfterCosts = try c.decodeIfPresent(Bool.self, forKey: .judgeAfterCosts) ?? false
    }

    /// Seuils incohérents (refus au-dessus de l'acceptation) : on les remet dans l'ordre.
    var normalized: OfferSettings {
        var s = self
        s.minEurPerHour = min(s.minEurPerHour, s.targetEurPerHour)
        s.refuseEurPerKm = min(s.refuseEurPerKm, s.minEurPerKm)
        return s
    }
}

/// Un trajet calculé par le serveur Scoot Route (en trottinette, avec le relief).
struct OfferLeg: Codable, Equatable {
    var distanceM: Double
    var durationS: Double
    var ascentM: Double
    var descentM: Double
}

struct OfferEvaluation: Codable, Equatable {
    enum Decision: String, Codable { case accept, evaluate, refuse, incomplete }
    enum Source: String, Codable {
        /// Trajets recalculés en trottinette (position → restaurant → client)
        case scooterRoute
        /// Distance et durée lues sur l'offre (estimation de l'app de livraison)
        case announced
    }

    var decision: Decision
    var source: Source
    var priceEur: Double
    var tipEur: Double?
    /// Montant brut par heure et par km
    var eurPerHour: Double
    var eurPerKm: Double
    var totalMinutes: Double
    var rideMinutes: Double
    var stopMinutes: Double
    var totalKm: Double
    /// Part du trajet jusqu'au restaurant (km, min), quand elle est connue
    var approachKm: Double?
    var approachMin: Double?
    var ascentM: Double
    var descentM: Double
    var batteryUsedPercent: Double
    var batteryAtEndPercent: Double
    /// Frais variables estimés pour cette course et gain restant (si les frais sont renseignés)
    var operatingCostEur: Double?
    var afterCostsEur: Double?
    var afterCostsPerHour: Double?
    /// Après frais variables ET cotisations estimées (si le taux est renseigné) — hors impôt
    var afterChargesEur: Double?
    var afterChargesPerHour: Double?
    /// Valeurs comparées aux seuils : « brut » ou « après frais »
    var judgedOn: String
    var reasons: [String]
    /// Données manquantes ou incohérentes (décision « incomplete »)
    var issues: [String]

    var decisionLabel: String {
        switch decision {
        case .accept: return "ACCEPTER"
        case .evaluate: return "À ÉVALUER"
        case .refuse: return "REFUSER"
        case .incomplete: return "Analyse incomplète"
        }
    }

    var decisionEmoji: String {
        switch decision {
        case .accept: return "✅"
        case .evaluate: return "🟠"
        case .refuse: return "❌"
        case .incomplete: return "⚠️"
        }
    }

    /// Phrase courte affichée par le raccourci et la notification, sans ouvrir l'app.
    var summary: String {
        if decision == .incomplete {
            return "\(decisionEmoji) \(decisionLabel) : \(issues.joined(separator: ", ")). Ouvrez Scoot Route › Offre pour compléter."
        }
        let climb = ascentM >= 10 ? " · ↑\(Int(ascentM.rounded())) m" : ""
        var text = "\(decisionEmoji) \(decisionLabel) · \(Self.eur(eurPerHour))/h · \(Self.eur(eurPerKm))/km brut\n"
            + "\(Self.eur(priceEur)) pour \(Int(totalMinutes.rounded())) min et \(Self.km(totalKm))\(climb)"
        if let net = afterCostsPerHour { text += " · \(Self.eur(net))/h après frais" }
        text += " · batterie \(Int(max(0, batteryAtEndPercent).rounded())) % à la fin"
        if source == .announced { text += "\n(distance de l'offre, relief non compté)" }
        return text
    }

    static func eur(_ v: Double) -> String {
        String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",")
    }

    static func km(_ v: Double) -> String {
        String(format: "%.1f km", v).replacingOccurrences(of: ".", with: ",")
    }
}

enum ProfitabilityEvaluator {
    /// Évalue une offre lue (ou corrigée).
    /// - Parameter legs: trajets trottinette (approche + livraison, ou livraison seule) ;
    ///   nil si les adresses n'ont pas pu être localisées → valeurs annoncées par l'offre.
    static func evaluate(offer: ParsedOffer, legs: [OfferLeg]?, settings rawSettings: OfferSettings,
                         vehicle: VehicleProfile) -> OfferEvaluation {
        let settings = rawSettings.normalized
        var reasons: [String] = []
        let price = offer.priceEur ?? 0

        // 1. Distance et durée de roulage
        let source: OfferEvaluation.Source
        var meters = 0.0, rideSeconds = 0.0, ascent = 0.0, descent = 0.0
        var approachKm: Double?, approachMin: Double?
        var issues: [String]
        if let legs, !legs.isEmpty {
            source = .scooterRoute
            meters = legs.reduce(0) { $0 + $1.distanceM }
            rideSeconds = legs.reduce(0) { $0 + $1.durationS }
            ascent = legs.reduce(0) { $0 + $1.ascentM }
            descent = legs.reduce(0) { $0 + $1.descentM }
            if legs.count >= 2 {
                approachKm = legs[0].distanceM / 1000
                approachMin = legs[0].durationS / 60
            } else if let km = offer.approachKm, let min = offer.approachMin {
                // Livraison calculée, approche reprise de l'offre (position inconnue)
                meters += km * 1000
                rideSeconds += min * 60
                approachKm = km
                approachMin = min
                reasons.append("Trajet jusqu'au restaurant : valeur de l'offre (relief non compté)")
            } else {
                reasons.append("Trajet jusqu'au restaurant non compté (position inconnue)")
            }
            issues = OfferValidator.issues(priceEur: offer.priceEur, km: meters / 1000, minutes: max(1, rideSeconds / 60))
                .filter { !$0.hasPrefix("Distance et durée incohérentes") }
        } else {
            source = .announced
            issues = OfferValidator.issues(priceEur: offer.priceEur, km: offer.announcedDistanceKm,
                                           minutes: offer.announcedDurationMin)
            meters = (offer.announcedDistanceKm ?? 0) * 1000
            rideSeconds = (offer.announcedDurationMin ?? 0) * 60
            approachKm = offer.approachKm
            approachMin = offer.approachMin
            reasons.append("Basé sur la distance et la durée de l'offre : relief non pris en compte")
        }

        // 2. Temps total : roulage + attente au restaurant + remise au client
        let stopMinutes = source == .scooterRoute ? settings.waitAtRestaurantMin + settings.handoffMin : settings.handoffMin
        let rideMinutes = rideSeconds / 60
        let totalMinutes = rideMinutes + stopMinutes
        let totalKm = meters / 1000
        let battery = BatteryEstimator.estimate(distanceM: meters, durationS: max(1, rideSeconds),
                                                ascentM: ascent, descentM: descent, vehicle: vehicle)

        guard issues.isEmpty else {
            return OfferEvaluation(
                decision: .incomplete, source: source, priceEur: price, tipEur: offer.tipEur,
                eurPerHour: 0, eurPerKm: 0, totalMinutes: totalMinutes, rideMinutes: rideMinutes,
                stopMinutes: stopMinutes, totalKm: totalKm, approachKm: approachKm, approachMin: approachMin,
                ascentM: ascent, descentM: descent, batteryUsedPercent: battery.percentUsed,
                batteryAtEndPercent: battery.arrivalPercent, judgedOn: "—", reasons: reasons, issues: issues)
        }

        // 3. Indicateurs bruts puis après frais (estimations, pas un bénéfice comptable)
        let hours = totalMinutes / 60
        let eurPerHour = price / hours
        let eurPerKm = price / max(0.2, totalKm)
        var costEur: Double?, afterCosts: Double?, afterCostsPerHour: Double?
        var afterCharges: Double?, afterChargesPerHour: Double?
        if let perKm = settings.operatingCostPerKm, perKm >= 0 {
            costEur = perKm * totalKm
            afterCosts = price - perKm * totalKm
            afterCostsPerHour = (price - perKm * totalKm) / hours
        }
        if let rate = settings.socialChargesPercent, rate > 0 {
            // Cotisations calculées sur le chiffre d'affaires (cas du micro-entrepreneur)
            let net = price - (costEur ?? 0) - price * rate / 100
            afterCharges = net
            afterChargesPerHour = net / hours
        }

        // 4. Décision selon les seuils
        let judgeNet = settings.judgeAfterCosts && afterCosts != nil
        let judgedHour = judgeNet ? (afterCostsPerHour ?? eurPerHour) : eurPerHour
        let judgedKm = judgeNet ? (afterCosts ?? price) / max(0.2, totalKm) : eurPerKm
        var decision: OfferEvaluation.Decision
        if judgedHour >= settings.targetEurPerHour && judgedKm >= settings.minEurPerKm {
            decision = .accept
        } else if judgedHour < settings.minEurPerHour || judgedKm < settings.refuseEurPerKm {
            decision = .refuse
        } else {
            decision = .evaluate
        }
        let basis = judgeNet ? " après frais" : ""
        if judgedHour < settings.targetEurPerHour {
            reasons.append("\(OfferEvaluation.eur(judgedHour))/h\(basis) : sous votre seuil d'acceptation de \(OfferEvaluation.eur(settings.targetEurPerHour))/h")
        }
        if judgedKm < settings.minEurPerKm {
            reasons.append("\(OfferEvaluation.eur(judgedKm))/km\(basis) : sous votre seuil d'acceptation de \(OfferEvaluation.eur(settings.minEurPerKm))/km")
        }
        if ascent >= 40 { reasons.append("Montées importantes : \(Int(ascent.rounded())) m de dénivelé") }
        if battery.risk == .insufficient {
            decision = .refuse
            reasons.append("Batterie probablement insuffisante")
        } else if battery.risk == .tight {
            reasons.append("Batterie juste après cette course")
        }

        return OfferEvaluation(
            decision: decision, source: source, priceEur: price, tipEur: offer.tipEur,
            eurPerHour: eurPerHour, eurPerKm: eurPerKm, totalMinutes: totalMinutes, rideMinutes: rideMinutes,
            stopMinutes: stopMinutes, totalKm: totalKm, approachKm: approachKm, approachMin: approachMin,
            ascentM: ascent, descentM: descent, batteryUsedPercent: battery.percentUsed,
            batteryAtEndPercent: battery.arrivalPercent, operatingCostEur: costEur,
            afterCostsEur: afterCosts, afterCostsPerHour: afterCostsPerHour,
            afterChargesEur: afterCharges, afterChargesPerHour: afterChargesPerHour,
            judgedOn: judgeNet ? "après frais" : "brut", reasons: reasons, issues: [])
    }

    /// Forme simplifiée (montant, trajets, valeurs annoncées).
    static func evaluate(priceEur: Double?, legs: [OfferLeg]?, announcedKm: Double?, announcedMin: Double?,
                         settings: OfferSettings, vehicle: VehicleProfile) -> OfferEvaluation {
        var offer = ParsedOffer()
        offer.priceEur = priceEur
        offer.announcedDistanceKm = announcedKm
        offer.announcedDurationMin = announcedMin
        return evaluate(offer: offer, legs: legs, settings: settings, vehicle: vehicle)
    }
}
