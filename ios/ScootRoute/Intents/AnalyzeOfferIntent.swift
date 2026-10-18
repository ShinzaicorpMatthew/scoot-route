import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Action Raccourcis « Analyser une offre de course » : reçoit une capture d'écran,
/// répond ACCEPTER / À ÉVALUER / REFUSER (ou « Analyse incomplète ») sans ouvrir Scoot Route.
/// À associer à « Toucher le dos » (Réglages › Accessibilité › Toucher).
struct AnalyzeOfferIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyser une offre de course"
    static var description = IntentDescription(
        "Lit une capture d'écran : une offre (Uber Eats…) → accepter, à évaluer ou refuser en trottinette ; l'écran batterie de l'app de la trottinette → niveau enregistré.")
    static var openAppWhenRun: Bool = false

    // (supportedContentTypes exige iOS 18 ; l'app vise iOS 17 : toute image est acceptée)
    @Parameter(title: "Capture d'écran")
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Analyser l'offre sur \(\.$screenshot)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let analyzer = OfferAnalyzer.fromStoredPreferences()
        let result = try await analyzer.analyzeScreenshot(imageData: screenshot.data,
                                                          origin: OfferAnalyzer.lastKnownLocation())
        let text: String
        switch result {
        case let .offer(analysis):
            LocalStore.save(analysis, key: OfferAnalysis.storeKey)
            text = analysis.summary
        case let .battery(reading, vehicle):
            LocalStore.save(vehicle, key: "vehicle")
            text = OfferAnalyzer.batterySummary(reading, vehicle: vehicle)
        case .unreadable:
            text = "Ni offre ni niveau de batterie reconnu sur cette capture."
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
