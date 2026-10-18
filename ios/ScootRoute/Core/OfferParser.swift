import Foundation

/// Informations lues sur une capture d'écran d'offre de course (Uber Eats ou autre app de livraison).
/// Le texte provient de la reconnaissance de caractères faite sur l'iPhone : chaque champ peut
/// manquer ou être mal lu, l'utilisateur peut toujours le corriger.
struct ParsedOffer: Codable, Equatable {
    var priceEur: Double?
    /// Distance totale annoncée par l'app de livraison (km)
    var announcedDistanceKm: Double?
    /// Durée totale annoncée par l'app de livraison (min)
    var announcedDurationMin: Double?
    /// Nom ou adresse du restaurant
    var pickupText: String?
    /// Adresse (souvent approximative) du client
    var dropoffText: String?
    var lines: [String] = []

    var isUsable: Bool { priceEur != nil }
}

enum OfferParser {
    /// Mots qui signalent une ligne d'interface (boutons, titres) à ignorer pour les adresses.
    private static let uiWords = [
        "accepter", "refuser", "ignorer", "accept", "decline", "match", "course", "livraison",
        "retrait", "collecte", "total", "estim", "inclus", "pourboire", "tip", "min", "km", "€",
        "uber", "eats", "offre", "commande", "commandes", "trajet", "aller", "nouvelle",
    ]

    private static let streetWords =
        #"\b(rue|avenue|av\.?|bd|boulevard|place|pl\.|quai|cours|chemin|ch\.|allée|allee|impasse|montée|montee|route|rte|passage|square|grande[- ]rue|esplanade|chaussée)\b"#

    static func parse(lines rawLines: [String]) -> ParsedOffer {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var offer = ParsedOffer(lines: lines)
        offer.priceEur = price(in: lines)
        offer.announcedDistanceKm = distanceKm(in: lines)
        offer.announcedDurationMin = durationMin(in: lines)
        let (pickup, dropoff) = places(in: lines)
        offer.pickupText = pickup
        offer.dropoffText = dropoff
        return offer
    }

    // MARK: Prix

    /// Le montant mis en avant est en général le plus élevé de l'écran ; on ignore les montants
    /// précédés de « + » (bonus ou pourboire affiché séparément) sauf s'il n'y a rien d'autre.
    static func price(in lines: [String]) -> Double? {
        let pattern = #"(\+?)\s*(?:€\s*(\d{1,3}(?:[.,]\d{1,2})?)|(\d{1,3}(?:[.,]\d{1,2})?)\s*€)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var main: [Double] = [], extras: [Double] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for m in regex.matches(in: line, range: range) {
                let plus = Range(m.range(at: 1), in: line).map { !line[$0].isEmpty } ?? false
                let r = Range(m.range(at: 2), in: line) ?? Range(m.range(at: 3), in: line)
                guard let r, let v = Double(line[r].replacingOccurrences(of: ",", with: ".")),
                      v > 0, v < 500 else { continue }
                if plus { extras.append(v) } else { main.append(v) }
            }
        }
        return main.max() ?? extras.max()
    }

    // MARK: Distance et durée

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

    static func places(in lines: [String]) -> (String?, String?) {
        func looksLikeAddress(_ l: String) -> Bool {
            l.range(of: streetWords, options: [.regularExpression, .caseInsensitive]) != nil
                || l.range(of: #"\b69\d{3}\b"#, options: .regularExpression) != nil
        }
        func isUI(_ l: String) -> Bool {
            let low = l.lowercased()
            if l.count < 3 || l.count > 70 { return true }
            if l.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true } // heure
            if l.range(of: #"\d"#, options: .regularExpression) != nil && !looksLikeAddress(l) { return true }
            return uiWords.contains { low.contains($0) } && !looksLikeAddress(l)
        }

        let addresses = lines.filter(looksLikeAddress)
        let named = lines.filter { !isUI($0) && !looksLikeAddress($0) }

        // Cas courant : nom du restaurant (sans numéro), puis adresse de livraison.
        var pickup: String?
        var dropoff: String?
        if addresses.count >= 2 {
            pickup = addresses[0]
            dropoff = addresses[addresses.count - 1]
            // Un nom de restaurant juste au-dessus de sa première adresse la rend plus précise
            if let i = lines.firstIndex(of: addresses[0]), i > 0, named.contains(lines[i - 1]) {
                pickup = "\(lines[i - 1]), \(addresses[0])"
            }
        } else if addresses.count == 1 {
            dropoff = addresses[0]
            let idx = lines.firstIndex(of: addresses[0]) ?? lines.count
            pickup = named.first { (lines.firstIndex(of: $0) ?? 0) < idx } ?? named.first
        } else {
            pickup = named.first
            dropoff = named.dropFirst().first
        }
        return (pickup, dropoff)
    }
}
