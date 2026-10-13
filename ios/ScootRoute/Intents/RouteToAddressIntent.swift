import AppIntents
import Foundation

/// Action « Itinéraire Scoot Route » utilisable dans l'app Raccourcis.
/// Un raccourci qui accepte le texte partagé permet d'envoyer une adresse depuis
/// n'importe quelle app via le menu de partage iOS (voir README).
struct RouteToAddressIntent: AppIntent {
    static var title: LocalizedStringResource = "Itinéraire Scoot Route"
    static var description = IntentDescription("Ouvre Scoot Route avec cette adresse comme destination client.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Adresse ou lien de carte")
    var text: String

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(text, forKey: PendingImport.key)
        return .result()
    }
}

struct ScootRouteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RouteToAddressIntent(),
                    phrases: ["Itinéraire avec \(.applicationName)"],
                    shortTitle: "Itinéraire",
                    systemImageName: "scooter")
    }
}
