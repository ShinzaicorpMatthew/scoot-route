import Foundation
import UserNotifications

/// Notification de décision, affichée par-dessus Uber Driver.
enum OfferNotifier {
    static let identifier = "scootroute.offer"
    static let tabKey = "openTab"

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// - Parameter silent: mise à jour d'une notification déjà affichée (sans nouveau son)
    static func post(_ analysis: OfferAnalysis, silent: Bool = false) {
        let content = UNMutableNotificationContent()
        let e = analysis.evaluation
        content.title = "Scoot Route · " + (e.map { "\($0.decisionEmoji) \($0.decisionLabel)" } ?? "⚠️ Analyse incomplète")
        var body = analysis.summary
        // Première ligne déjà dans le titre
        if let e, e.decision != .incomplete, let cut = body.firstIndex(of: "\n") {
            let rest = String(body[body.index(after: cut)...])
            body = "\(OfferEvaluation.eur(e.eurPerHour))/h · \(OfferEvaluation.eur(e.eurPerKm))/km brut\n" + rest
        }
        if !SharedStore.isShared { body += "\n(seuils par défaut : réglages de l'app non partagés)" }
        content.body = body
        content.sound = silent ? nil : .default
        content.threadIdentifier = "offers"
        content.userInfo = [tabKey: "offer"]
        if #available(iOS 15.0, *) { content.interruptionLevel = .active }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
