import Foundation

/// Informations lues sur une offre de course (Uber Eats ou autre app de livraison).
/// Le texte provient de la reconnaissance de caractères faite sur l'iPhone : chaque champ peut
/// manquer ou être mal lu ; les champs douteux sont signalés pour une vérification rapide.
struct ParsedOffer: Codable, Equatable {
    var priceEur: Double?
    /// Pourboire affiché sur l'offre (en général déjà compris dans le montant)
    var tipEur: Double?
    /// Distance totale annoncée par l'app de livraison (km)
    var announcedDistanceKm: Double?
    /// Durée totale annoncée par l'app de livraison (min)
    var announcedDurationMin: Double?
    /// Trajet jusqu'au restaurant, quand l'offre le détaille
    var approachKm: Double?
    var approachMin: Double?
    /// Nom ou adresse du restaurant
    var pickupText: String?
    /// Adresse (souvent approximative) du client
    var dropoffText: String?
    var lines: [String] = []
    /// Champs dont la lecture est douteuse : voir `Field`
    var uncertain: [String]?

    enum Field: String, CaseIterable {
        case price, pickup, dropoff, distance, duration
        var label: String {
            switch self {
            case .price: return "Montant"
            case .pickup: return "Restaurant"
            case .dropoff: return "Client"
            case .distance: return "Distance"
            case .duration: return "Durée"
            }
        }
    }

    var isUsable: Bool { priceEur != nil }

    func isUncertain(_ field: Field) -> Bool { uncertain?.contains(field.rawValue) ?? false }
    var uncertainFields: [Field] { Field.allCases.filter(isUncertain) }
}

enum OfferParser {
    /// Mots qui signalent une ligne d'interface (boutons, titres) à ignorer pour les adresses.
    private static let uiWords = [
        "accepter", "refuser", "ignorer", "accept", "decline", "match", "course", "livraison",
        "retrait", "collecte", "total", "estim", "inclus", "pourboire", "tip", "min", "km", "€",
        "uber", "eats", "offre", "commande", "commandes", "trajet", "aller", "nouvelle", "exclusive",
        "appuyez", "glissez", "en ligne", "hors ligne", "itinéraire",
    ]

    private static let streetWords =
        #"\b(rue|avenue|av\.?|bd|boulevard|place|pl\.|quai|cours|chemin|ch\.|allée|allee|impasse|montée|montee|route|rte|passage|square|grande[- ]rue|esplanade|chaussée)\b"#

    /// Seuil de confiance de la reconnaissance (0…1) sous lequel une ligne est jugée douteuse.
    static let lowConfidence: Float = 0.5

    /// - Parameter confidence: confiance de la reconnaissance pour chaque ligne (facultatif)
    static func parse(lines rawLines: [String], confidence: [String: Float] = [:]) -> ParsedOffer {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var offer = ParsedOffer(lines: lines)
        let (price, priceLine) = priceWithLine(in: lines)
        offer.priceEur = price
        offer.tipEur = tip(in: lines)

        let pairs = legPairs(in: lines)
        if let total = pairs.first(where: { $0.isTotal }) {
            offer.announcedDurationMin = total.minutes
            offer.announcedDistanceKm = total.km
            if let first = pairs.first(where: { !$0.isTotal }) {
                offer.approachMin = first.minutes
                offer.approachKm = first.km
            }
        } else if pairs.count >= 2 {
            // Étapes détaillées (vers le restaurant, puis vers le client) sans total affiché
            offer.approachMin = pairs[0].minutes
            offer.approachKm = pairs[0].km
            offer.announcedDurationMin = pairs.reduce(0) { $0 + $1.minutes }
            offer.announcedDistanceKm = pairs.reduce(0) { $0 + $1.km }
        } else {
            offer.announcedDistanceKm = distanceKm(in: lines)
            offer.announcedDurationMin = durationMin(in: lines)
        }

        let (pickup, dropoff, pickupHasName) = places(in: lines)
        offer.pickupText = pickup
        offer.dropoffText = dropoff

        // Champs à faire vérifier
        func doubtful(_ line: String?) -> Bool {
            guard let line, let c = confidence[line] else { return false }
            return c < lowConfidence
        }
        var uncertain: [ParsedOffer.Field] = []
        if price != nil, doubtful(priceLine) { uncertain.append(.price) }
        if pickup == nil || !pickupHasName || doubtful(pickup) { uncertain.append(.pickup) }
        if dropoff == nil || doubtful(dropoff) { uncertain.append(.dropoff) }
        if let km = offer.announcedDistanceKm, let min = offer.announcedDurationMin,
           !OfferValidator.isCoherent(km: km, minutes: min) {
            uncertain += [.distance, .duration]
        }
        offer.uncertain = uncertain.isEmpty ? nil : uncertain.map(\.rawValue)
        return offer
    }

    // MARK: Prix et pourboire

    static func price(in lines: [String]) -> Double? { priceWithLine(in: lines).0 }

    /// Le montant mis en avant est en général le plus élevé de l'écran ; on ignore les montants
    /// précédés de « + » (bonus) et ceux des lignes de pourboire, sauf s'il n'y a rien d'autre.
    static func priceWithLine(in lines: [String]) -> (Double?, String?) {
        var main: [(Double, String)] = [], extras: [(Double, String)] = []
        for line in lines {
            let isTip = isTipLine(line)
            for (value, plus) in amounts(in: line) {
                if plus || isTip { extras.append((value, line)) } else { main.append((value, line)) }
            }
        }
        let best = main.max { $0.0 < $1.0 } ?? extras.max { $0.0 < $1.0 }
        return (best?.0, best?.1)
    }

    /// Pourboire : montant sur une ligne qui parle de pourboire (ou sur la ligne suivante).
    static func tip(in lines: [String]) -> Double? {
        for (i, line) in lines.enumerated() where isTipLine(line) {
            if let v = amounts(in: line).first?.0 { return v }
            if i + 1 < lines.count, let v = amounts(in: lines[i + 1]).first?.0 { return v }
        }
        return nil
    }

    private static func isTipLine(_ line: String) -> Bool {
        let low = line.lowercased()
        return low.contains("pourboire") || low.range(of: #"\btips?\b"#, options: .regularExpression) != nil
    }

    private static func amounts(in line: String) -> [(Double, Bool)] {
        let pattern = #"(\+?)\s*(?:€\s*(\d{1,3}(?:[.,]\d{1,2})?)|(\d{1,3}(?:[.,]\d{1,2})?)\s*€)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [(Double, Bool)] = []
        let range = NSRange(line.startIndex..., in: line)
        for m in regex.matches(in: line, range: range) {
            let plus = Range(m.range(at: 1), in: line).map { !line[$0].isEmpty } ?? false
            let r = Range(m.range(at: 2), in: line) ?? Range(m.range(at: 3), in: line)
            guard let r, let v = Double(line[r].replacingOccurrences(of: ",", with: ".")),
                  v > 0, v < 500 else { continue }
            out.append((v, plus))
        }
        return out
    }

    // MARK: Distance et durée

    struct LegPair: Equatable { var minutes: Double; var km: Double; var isTotal: Bool }

    /// Couples « 22 min (4,1 km) » : une étape, ou le total si la ligne contient « total ».
    static func legPairs(in lines: [String]) -> [LegPair] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d{1,3})\s*min\w*\s*[(·•,-]?\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*km\b"#,
            options: .caseInsensitive) else { return [] }
        var out: [LegPair] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for m in regex.matches(in: line, range: range) {
                guard let rm = Range(m.range(at: 1), in: line), let rk = Range(m.range(at: 2), in: line),
                      let min = Double(line[rm]),
                      let km = Double(line[rk].replacingOccurrences(of: ",", with: ".")) else { continue }
                out.append(LegPair(minutes: min, km: km, isTotal: line.lowercased().contains("total")))
            }
        }
        return out
    }

    static func distanceKm(in lines: [String]) -> Double? {
        // Plusieurs distances (approche + livraison) : on additionne si l'écran ne donne pas de total
        let values = numbers(in: lines, unitPattern: #"km\b"#)
        let meters = numbers(in: lines, unitPattern: #"m\b(?!in)"#).map { $0 / 1000 }
        let all = values + meters
        guard !all.isEmpty else { return nil }
        let total = lines.contains { $0.lowercased().contains("total") }
        return total || all.count == 1 ? all.max() : all.reduce(0, +)
    }

    static func durationMin(in lines: [String]) -> Double? {
        var result: [Double] = []
        // « 1 h 05 » ou « 1h » (on ignore les heures d'horloge du type 12:45)
        let hm = try? NSRegularExpression(pattern: #"\b(\d{1,2})\s*h\s*(\d{2})?\b"#, options: .caseInsensitive)
        for line in lines where !line.contains(":") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = hm?.firstMatch(in: line, range: range),
               let rh = Range(m.range(at: 1), in: line), let h = Double(line[rh]) {
                let mins = Range(m.range(at: 2), in: line).flatMap { Double(line[$0]) } ?? 0
                result.append(h * 60 + mins)
            }
        }
        result += numbers(in: lines.filter { !$0.contains(":") }, unitPattern: #"min\b"#)
        guard !result.isEmpty else { return nil }
        let total = lines.contains { $0.lowercased().contains("total") }
        return total || result.count == 1 ? result.max() : result.reduce(0, +)
    }

    private static func numbers(in lines: [String], unitPattern: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d{1,2})?)\s*"# + unitPattern,
                                                   options: .caseInsensitive) else { return [] }
        var out: [Double] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for m in regex.matches(in: line, range: range) {
                if let r = Range(m.range(at: 1), in: line),
                   let v = Double(line[r].replacingOccurrences(of: ",", with: ".")) { out.append(v) }
            }
        }
        return out
    }

    // MARK: Restaurant et client

    static func looksLikeAddress(_ l: String) -> Bool {
        l.range(of: streetWords, options: [.regularExpression, .caseInsensitive]) != nil
            || l.range(of: #"\b69\d{3}\b"#, options: .regularExpression) != nil
    }

    /// - Returns: restaurant, client, et si le restaurant est identifié par un nom (pas seulement une rue)
    static func places(in lines: [String]) -> (String?, String?, Bool) {
        func isUI(_ l: String) -> Bool {
            let low = l.lowercased()
            if l.count < 3 || l.count > 70 { return true }
            if l.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true } // heure
            if l.range(of: #"\d"#, options: .regularExpression) != nil && !looksLikeAddress(l) { return true }
            if l.range(of: #"[\p{L}]"#, options: .regularExpression) == nil { return true }
            return uiWords.contains { low.contains($0) } && !looksLikeAddress(l)
        }

        let addresses = lines.filter(looksLikeAddress)
        let named = lines.filter { !isUI($0) && !looksLikeAddress($0) }

        // Cas courant : nom du restaurant (sans numéro), son adresse, puis l'adresse de livraison.
        var pickup: String?
        var dropoff: String?
        var hasName = false
        if addresses.count >= 2 {
            dropoff = addresses[addresses.count - 1]
            let firstAddrIdx = lines.firstIndex(of: addresses[0]) ?? 0
            // Nom de restaurant juste au-dessus (ou deux lignes au-dessus) de sa première adresse
            let name = [1, 2].lazy
                .map { firstAddrIdx - $0 }
                .filter { $0 >= 0 }
                .map { lines[$0] }
                .first { named.contains($0) }
            if let name {
                pickup = "\(name), \(addresses[0])"
                hasName = true
            } else {
                pickup = addresses[0]
            }
        } else if addresses.count == 1 {
            dropoff = addresses[0]
            let idx = lines.firstIndex(of: addresses[0]) ?? lines.count
            pickup = named.first { (lines.firstIndex(of: $0) ?? 0) < idx } ?? named.first
            hasName = pickup != nil
        } else {
            pickup = named.first
            dropoff = named.dropFirst().first
            hasName = pickup != nil
        }
        return (pickup, dropoff, hasName)
    }
}

/// Contrôles de cohérence avant tout calcul de rentabilité.
enum OfferValidator {
    static let priceRange = 0.5...150.0
    static let distanceRange = 0.1...60.0
    static let durationRange = 1.0...180.0
    /// Vitesse moyenne plausible pour une livraison (km/h), arrêts compris
    static let speedRange = 2.0...40.0

    static func isCoherent(km: Double, minutes: Double) -> Bool {
        guard distanceRange.contains(km), durationRange.contains(minutes) else { return false }
        return speedRange.contains(km / (minutes / 60))
    }

    /// Problèmes qui empêchent un verdict fiable (liste vide = données exploitables).
    static func issues(priceEur: Double?, km: Double?, minutes: Double?) -> [String] {
        var out: [String] = []
        if let p = priceEur {
            if !priceRange.contains(p) { out.append("Montant improbable (\(OfferEvaluation.eur(p)))") }
        } else {
            out.append("Montant non lu")
        }
        switch (km, minutes) {
        case (nil, nil): out.append("Distance et durée inconnues")
        case (nil, _): out.append("Distance inconnue")
        case (_, nil): out.append("Durée inconnue")
        case let (k?, m?):
            if !distanceRange.contains(k) { out.append("Distance improbable (\(OfferEvaluation.km(k)))") }
            if !durationRange.contains(m) { out.append("Durée improbable (\(Int(m)) min)") }
            if distanceRange.contains(k), durationRange.contains(m), !speedRange.contains(k / (m / 60)) {
                out.append("Distance et durée incohérentes (\(Int((k / (m / 60)).rounded())) km/h de moyenne)")
            }
        }
        return out
    }
}
