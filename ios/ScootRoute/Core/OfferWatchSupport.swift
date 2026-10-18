import Foundation

/// Reconnaît, dans le texte lu sur une image de l'écran, une offre de course en attente.
/// Utilisé par la veille des offres (diffusion d'écran ReplayKit) : c'est de la lecture d'écran,
/// pas un accès aux données d'Uber Driver.
enum OfferScreenDetector {
    /// Une offre affiche un montant, une distance ou une durée, et un bouton pour l'accepter.
    static func looksLikeOffer(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n").lowercased()
        // Nos propres écrans et notifications ne doivent jamais être pris pour une offre
        if text.contains("scoot route") || text.contains("lu sur la capture") || text.contains("mes critères") {
            return false
        }
        guard OfferParser.price(in: lines) != nil else { return false }
        guard text.range(of: #"\d\s*(km|min)\b"#, options: .regularExpression) != nil else { return false }
        return text.range(of: #"\b(accepter|accept|match)\b"#, options: .regularExpression) != nil
    }

    /// Empreinte d'une offre : la même offre reste à l'écran plusieurs secondes,
    /// on ne la signale qu'une fois.
    static func fingerprint(_ offer: ParsedOffer) -> String {
        func r(_ v: Double?, _ step: Double) -> String { v.map { String(Int(($0 / step).rounded())) } ?? "-" }
        return [r(offer.priceEur, 0.05), r(offer.announcedDistanceKm, 0.2), r(offer.announcedDurationMin, 1)]
            .joined(separator: "|")
    }
}

/// État de la veille, partagé entre l'extension et l'app (groupe d'apps).
enum WatchStatus {
    private static let activeKey = "watchActive"
    private static let frameKey = "watchLastFrame"
    private static let offersKey = "watchOfferCount"
    private static let foregroundKey = "appForegroundUntil"

    static func setActive(_ on: Bool) {
        SharedStore.defaults.set(on, forKey: activeKey)
        if on { SharedStore.defaults.set(0, forKey: offersKey) }
    }

    /// Appelé à chaque image analysée (au plus toutes les quelques secondes).
    static func heartbeat() {
        SharedStore.defaults.set(Date().timeIntervalSince1970, forKey: frameKey)
    }

    static func countOffer() {
        SharedStore.defaults.set(offersSeen + 1, forKey: offersKey)
    }

    static var offersSeen: Int { SharedStore.defaults.integer(forKey: offersKey) }

    static var lastFrame: Date? {
        let t = SharedStore.defaults.double(forKey: frameKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// La veille tourne : diffusion démarrée et image récente.
    static var isRunning: Bool {
        guard SharedStore.defaults.bool(forKey: activeKey), let lastFrame else { return false }
        return Date().timeIntervalSince(lastFrame) < 30
    }

    /// Scoot Route est à l'écran : la veille ne lit pas nos propres pages.
    static func setAppForeground(_ on: Bool) {
        SharedStore.defaults.set(on ? Date().addingTimeInterval(3600).timeIntervalSince1970 : 0, forKey: foregroundKey)
    }

    static var appIsForeground: Bool {
        SharedStore.defaults.double(forKey: foregroundKey) > Date().timeIntervalSince1970
    }
}
