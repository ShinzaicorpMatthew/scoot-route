import Foundation
import CoreLocation

/// Interprète un texte collé ou partagé (adresse copiée depuis l'app livreur, lien
/// Apple Plans / Google Maps, URI geo:, coordonnées) — sans aucun accès à l'app Uber Eats.
enum ParsedDestination: Equatable {
    case coordinate(CLLocationCoordinate2D, label: String?)
    case address(String)

    static func == (l: ParsedDestination, r: ParsedDestination) -> Bool {
        switch (l, r) {
        case let (.coordinate(a, la), .coordinate(b, lb)):
            return abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7 && la == lb
        case let (.address(a), .address(b)):
            return a == b
        default:
            return false
        }
    }
}

enum AddressTextParser {
    static func parse(_ raw: String) -> ParsedDestination? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = firstURL(in: text), let parsed = parseMapURL(url) { return parsed }
        if let c = coordinatePair(in: text) { return .coordinate(c, label: nil) }

        let cleaned = cleanAddress(text)
        return cleaned.count >= 4 ? .address(cleaned) : nil
    }

    // MARK: Liens cartographiques

    static func parseMapURL(_ url: URL) -> ParsedDestination? {
        let s = url.absoluteString
        if url.scheme?.lowercased() == "geo" {
            // geo:45.76,4.83?q=...
            let body = s.dropFirst(4).split(separator: "?").first.map(String.init) ?? ""
            if let c = coordinatePair(in: body, minDecimals: 1) { return .coordinate(c, label: nil) }
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let host = url.host?.lowercased() ?? ""

        if host.contains("maps.apple.com") || host.contains("maps.apple") {
            let label = q("q") ?? q("name")
            for key in ["daddr", "ll", "sll", "coordinate"] {
                if let v = q(key), let c = coordinatePair(in: v, minDecimals: 1) { return .coordinate(c, label: label) }
            }
            if let addr = q("daddr") ?? q("address") ?? q("q") { return .address(addr) }
        }
        if host.contains("google.") || host.contains("goo.gl") {
            // .../@45.7578,4.8320,17z  ou  ?q=45.75,4.83  ou  ?destination=...
            if let at = s.range(of: "@") {
                let tail = String(s[at.upperBound...])
                if let c = coordinatePair(in: tail, minDecimals: 1) { return .coordinate(c, label: nil) }
            }
            for key in ["q", "query", "destination", "daddr"] {
                if let v = q(key) {
                    if let c = coordinatePair(in: v, minDecimals: 1) { return .coordinate(c, label: nil) }
                    return .address(v)
                }
            }
        }
        if url.scheme == "scootroute", let v = q("q") ?? q("to") {
            return parse(v)
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("geo:") || lower.hasPrefix("scootroute:") {
            return URL(string: text.components(separatedBy: .whitespacesAndNewlines)[0])
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    // MARK: Coordonnées

    /// Dans un texte libre on exige ≥ 3 décimales pour ne pas confondre avec un prix ;
    /// dans un lien cartographique (contexte non ambigu) une seule suffit.
    static func coordinatePair(in text: String, minDecimals: Int = 3) -> CLLocationCoordinate2D? {
        let pattern = "(-?\\d{1,2}\\.\\d{\(minDecimals),})\\s*[,; ]\\s*(-?\\d{1,3}\\.\\d{\(minDecimals),})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
              let lat = Double(text[r1]), let lon = Double(text[r2]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: Nettoyage d'adresse

    static func cleanAddress(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let noise = ["livrer à", "livraison", "adresse de livraison", "client", "instructions", "deliver to"]
        lines = lines.map { line in
            var l = line
            for n in noise where l.lowercased().hasPrefix(n) {
                l = String(l.dropFirst(n.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :-–"))
            }
            return l
        }
        // Retire numéros de téléphone et codes d'accès évidents
        let phone = try? NSRegularExpression(pattern: #"(\+33|0)[1-9](?:[ .-]?\d{2}){4}"#)
        lines = lines.compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            let stripped = phone?.stringByReplacingMatches(in: line, range: range, withTemplate: "") ?? line
            let t = stripped.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if t.isEmpty || lower.hasPrefix("code") || lower.hasPrefix("digicode") || lower.hasPrefix("étage") { return nil }
            return t
        }
        // Garde les lignes qui ressemblent à une adresse (numéro, code postal, mot-clé de voie)
        let addressLike = lines.filter { l in
            l.range(of: #"\b\d{5}\b"#, options: .regularExpression) != nil
                || l.range(of: #"^\d+\s*(bis|ter)?\s"#, options: [.regularExpression, .caseInsensitive]) != nil
                || l.range(of: #"\b(rue|avenue|av\.|bd|boulevard|place|quai|cours|chemin|allée|impasse|montée|route)\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
        }
        let chosen = addressLike.isEmpty ? lines : addressLike
        return chosen.prefix(3).joined(separator: ", ")
    }
}
