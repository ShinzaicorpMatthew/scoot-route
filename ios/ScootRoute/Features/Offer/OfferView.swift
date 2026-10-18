import SwiftUI
import PhotosUI
import ReplayKit
import UIKit

/// Onglet « Offre » : faut-il accepter la course proposée, en trottinette ?
struct OfferView: View {
    @Environment(AppModel.self) private var model
    @State private var photo: PhotosPickerItem?
    @State private var showShortcutHelp = false
    @State private var showWatchHelp = false
    @State private var editing = false
    @State private var notificationsAllowed = true

    var body: some View {
        NavigationStack {
            List {
                watchSection

                Section {
                    PhotosPicker(selection: $photo, matching: .screenshots) {
                        Label("Analyser une capture d'écran d'offre", systemImage: "photo.badge.magnifyingglass")
                    }
                    Button {
                        showShortcutHelp = true
                    } label: {
                        Label("Raccourci « toucher le dos »", systemImage: "hand.tap")
                    }
                } header: {
                    Text("Sans la veille")
                }

                if model.isAnalyzingOffer {
                    Section { HStack { ProgressView(); Text("Analyse de l'offre…") } }
                }

                if let offer = model.lastOffer {
                    resultSection(offer)
                    if !offer.parsed.uncertainFields.isEmpty { checkSection(offer) }
                    detailsSection(offer)
                    Section {
                        Button {
                            Task { await model.startOfferRoute() }
                        } label: {
                            Label("J'ai pris la course : itinéraire vers le restaurant", systemImage: "location.north.line.fill")
                                .font(.headline)
                        }
                        .disabled(offer.pickup == nil || offer.dropoff == nil)
                    }
                } else if !model.isAnalyzingOffer {
                    Section {
                        ContentUnavailableView("Aucune offre analysée", systemImage: "eurosign.circle",
                                               description: Text("Démarrez la veille, ou analysez une capture d'écran d'offre."))
                    }
                }

                thresholdsSection
                costsSection
            }
            .navigationTitle("Offre")
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await model.analyzeOffer(imageData: data)
                    }
                    photo = nil
                }
            }
            .task { notificationsAllowed = await OfferNotifier.isAuthorized() }
            .sheet(isPresented: $showShortcutHelp) { ShortcutHelpView() }
            .sheet(isPresented: $showWatchHelp) { WatchHelpView() }
            .sheet(isPresented: $editing) {
                if let offer = model.lastOffer { OfferEditView(offer: offer).environment(model) }
            }
        }
    }

    // MARK: Veille des offres

    private var watchSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let running = WatchStatus.isRunning
                HStack {
                    Image(systemName: running ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(running ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(running ? "Veille active" : "Veille arrêtée").font(.headline)
                        Text(running
                             ? "\(WatchStatus.offersSeen) offre(s) lue(s) depuis le démarrage"
                             : "Lancez-la au début de votre service")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                Task {
                    if !notificationsAllowed { notificationsAllowed = await OfferNotifier.requestAuthorization() }
                    BroadcastLauncher.shared.toggle()
                }
            } label: {
                Label("Démarrer ou arrêter la veille", systemImage: "record.circle")
                    .font(.headline)
            }
            .background(BroadcastPickerHost().frame(width: 1, height: 1).opacity(0.01))
            if !notificationsAllowed {
                Button("Autoriser les notifications (indispensable)") {
                    Task { notificationsAllowed = await OfferNotifier.requestAuthorization() }
                }
                .foregroundStyle(.orange)
            }
            if !SharedStore.isShared {
                Label("Réglages non partagés avec la veille : elle utilisera les seuils par défaut et la distance de l'offre.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button("Comment ça marche ?") { showWatchHelp = true }
        } header: {
            Text("Veille automatique des offres")
        } footer: {
            Text("Lecture de l'écran par la diffusion d'écran d'iOS, sur votre iPhone : aucune image n'est enregistrée ni envoyée. Scoot Route n'accède pas à Uber Driver et n'accepte jamais une course à votre place.")
        }
    }

    // MARK: Décision

    @ViewBuilder
    private func resultSection(_ offer: OfferAnalysis) -> some View {
        Section {
            if let e = offer.evaluation {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(e.decisionEmoji) \(e.decisionLabel)")
                            .font(.title.bold())
                            .foregroundStyle(color(e.decision))
                        Spacer()
                        if e.priceEur > 0 { Text(OfferEvaluation.eur(e.priceEur)).font(.title2.bold()) }
                    }
                    if e.decision == .incomplete {
                        ForEach(e.issues, id: \.self) { i in
                            Label(i, systemImage: "questionmark.circle").foregroundStyle(.orange)
                        }
                        Button("Compléter l'offre") { editing = true }
                    } else {
                        HStack(spacing: 0) {
                            metric(OfferEvaluation.eur(e.eurPerHour), "brut / heure")
                            metric(OfferEvaluation.eur(e.eurPerKm), "brut / km")
                            metric("\(Int(e.totalMinutes.rounded())) min", "au total")
                        }
                        if let net = e.afterCostsPerHour {
                            HStack(spacing: 0) {
                                metric(OfferEvaluation.eur(net), "/ h après frais")
                                metric(e.afterChargesPerHour.map(OfferEvaluation.eur) ?? "—", "/ h après cotis.")
                                metric(e.operatingCostEur.map(OfferEvaluation.eur) ?? "—", "frais estimés")
                            }
                        }
                        HStack(spacing: 0) {
                            metric(OfferEvaluation.km(e.totalKm), "parcourus")
                            metric("↑\(Int(e.ascentM.rounded())) ↓\(Int(e.descentM.rounded())) m", "dénivelé")
                            metric("\(Int(max(0, e.batteryAtEndPercent).rounded())) %", "batterie à la fin")
                        }
                        ForEach(e.reasons + offer.notes, id: \.self) { r in
                            Label(r, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Seuils (\(e.judgedOn)) : accepter dès \(OfferEvaluation.eur(model.offerSettings.targetEurPerHour))/h et \(OfferEvaluation.eur(model.offerSettings.minEurPerKm))/km ; refuser sous \(OfferEvaluation.eur(model.offerSettings.minEurPerHour))/h ou \(OfferEvaluation.eur(model.offerSettings.refuseEurPerKm))/km.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Label(offer.summary, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.difficulty)
                Button("Compléter l'offre") { editing = true }
            }
        } header: {
            Text("Analysée \(offer.date.formatted(date: .omitted, time: .shortened))\(viaLabel(offer.via))")
        }
    }

    private func checkSection(_ offer: OfferAnalysis) -> some View {
        Section {
            Text("Lecture peu sûre : " + offer.parsed.uncertainFields.map(\.label).joined(separator: ", "))
                .foregroundStyle(.orange)
            Button("Vérifier et corriger") { editing = true }
        } header: {
            Text("À vérifier")
        }
    }

    private func detailsSection(_ offer: OfferAnalysis) -> some View {
        Section("Détail") {
            LabeledContent("Restaurant", value: offer.pickup?.title ?? offer.parsed.pickupText ?? "non trouvé")
            LabeledContent("Client", value: offer.dropoff?.title ?? offer.parsed.dropoffText ?? "non trouvé")
            if let e = offer.evaluation, e.decision != .incomplete {
                if let km = e.approachKm, let min = e.approachMin {
                    LabeledContent("Jusqu'au restaurant", value: "\(OfferEvaluation.km(km)) · \(Int(min.rounded())) min")
                }
                LabeledContent("Roulage", value: "\(Int(e.rideMinutes.rounded())) min")
                LabeledContent("Attente et remise", value: "\(Int(e.stopMinutes.rounded())) min")
                Text(e.source == .scooterRoute
                     ? "Calcul : trajet trottinette réel (position → restaurant → client), relief compris."
                     : "Calcul : distance et durée affichées sur l'offre (relief non compté).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tip = offer.parsed.tipEur { LabeledContent("Pourboire affiché", value: OfferEvaluation.eur(tip)) }
            if let km = offer.parsed.announcedDistanceKm { LabeledContent("Distance de l'offre", value: OfferEvaluation.km(km)) }
            if let min = offer.parsed.announcedDurationMin { LabeledContent("Durée de l'offre", value: "\(Int(min)) min") }
            Button("Corriger une information") { editing = true }
        }
    }

    // MARK: Critères

    private var thresholdsSection: some View {
        @Bindable var model = model
        return Section {
            Stepper("✅ Accepter dès \(OfferEvaluation.eur(model.offerSettings.targetEurPerHour))/h",
                    value: $model.offerSettings.targetEurPerHour, in: 5...40, step: 0.5)
            Stepper("❌ Refuser sous \(OfferEvaluation.eur(model.offerSettings.minEurPerHour))/h",
                    value: $model.offerSettings.minEurPerHour, in: 3...40, step: 0.5)
            Stepper("✅ Accepter dès \(OfferEvaluation.eur(model.offerSettings.minEurPerKm))/km",
                    value: $model.offerSettings.minEurPerKm, in: 0.3...3, step: 0.05)
            Stepper("❌ Refuser sous \(OfferEvaluation.eur(model.offerSettings.refuseEurPerKm))/km",
                    value: $model.offerSettings.refuseEurPerKm, in: 0.1...3, step: 0.05)
            Stepper("Attente au restaurant : \(Int(model.offerSettings.waitAtRestaurantMin)) min",
                    value: $model.offerSettings.waitAtRestaurantMin, in: 0...20, step: 1)
            Stepper("Remise au client : \(Int(model.offerSettings.handoffMin)) min",
                    value: $model.offerSettings.handoffMin, in: 0...10, step: 1)
        } header: {
            Text("Mes seuils de décision")
        } footer: {
            Text("ACCEPTER si les deux seuils d'acceptation sont atteints, REFUSER sous l'un des seuils de refus, À ÉVALUER entre les deux. Valeurs de départ à ajuster selon vos revenus réels.")
        }
    }

    private var costsSection: some View {
        @Bindable var model = model
        let costBinding = Binding<Double>(
            get: { self.model.offerSettings.operatingCostPerKm ?? 0 },
            set: { self.model.offerSettings.operatingCostPerKm = $0 })
        let chargesBinding = Binding<Double>(
            get: { self.model.offerSettings.socialChargesPercent ?? 0 },
            set: { self.model.offerSettings.socialChargesPercent = $0 })
        return Section {
            Toggle("Renseigner mes frais par km", isOn: Binding(
                get: { self.model.offerSettings.operatingCostPerKm != nil },
                set: { self.model.offerSettings.operatingCostPerKm = $0 ? 0 : nil }))
            if model.offerSettings.operatingCostPerKm != nil {
                Stepper("Frais : \(OfferEvaluation.eur(costBinding.wrappedValue))/km", value: costBinding, in: 0...1, step: 0.01)
                Toggle("Décider sur le gain après frais", isOn: $model.offerSettings.judgeAfterCosts)
            }
            Toggle("Estimer mes cotisations sociales", isOn: Binding(
                get: { self.model.offerSettings.socialChargesPercent != nil },
                set: { self.model.offerSettings.socialChargesPercent = $0 ? 0 : nil }))
            if model.offerSettings.socialChargesPercent != nil {
                Stepper("Taux : \(String(format: "%.1f", chargesBinding.wrappedValue).replacingOccurrences(of: ".", with: ",")) % du montant",
                        value: chargesBinding, in: 0...50, step: 0.1)
            }
        } header: {
            Text("Frais et cotisations (facultatif)")
        } footer: {
            Text("Frais : électricité, pneus, freins, entretien, usure de la batterie ; calculez-les sur vos dépenses réelles. Cotisations : indiquez le taux URSSAF de votre statut (vérifiez-le sur autoentrepreneur.urssaf.fr). Ce sont des estimations : ni un bénéfice comptable, ni un revenu après impôt.")
        }
    }

    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func viaLabel(_ via: String?) -> String {
        switch via {
        case "watch": return " · veille"
        case "shortcut": return " · raccourci"
        default: return ""
        }
    }

    private func color(_ d: OfferEvaluation.Decision) -> Color {
        switch d {
        case .accept: return .green
        case .evaluate: return .orange
        case .refuse: return .red
        case .incomplete: return .secondary
        }
    }
}

/// Bouton système de diffusion d'écran, préréglé sur l'extension « Veille des offres ».
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let picker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "fr.scootroute.ScootRoute") + ".OfferWatch"
        picker.showsMicrophoneButton = false
        return picker
    }()

    /// Ouvre la fenêtre système « Diffusion d'écran » (démarrer ou arrêter).
    func toggle() {
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .touchUpInside)
        }
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { BroadcastLauncher.shared.picker }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Mode d'emploi de la veille des offres.
struct WatchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Au début du service") {
                    Text("Touchez **Démarrer ou arrêter la veille**, puis **Commencer la diffusion**. Une pastille rouge apparaît en haut de l'écran : la veille tourne.")
                    Text("Autre possibilité : Centre de contrôle › appui long sur **Enregistrement de l'écran** › **Scoot Route · Veille des offres** › **Commencer la diffusion**.")
                    Text("Ouvrez ensuite Uber Driver comme d'habitude.")
                }
                Section("Pendant les livraisons") {
                    Text("Dès qu'une offre s'affiche, une notification donne la décision en 1 à 2 secondes : ✅ ACCEPTER, 🟠 À ÉVALUER, ❌ REFUSER, ou ⚠️ Analyse incomplète.")
                    Text("Si le serveur répond, la notification est mise à jour quelques secondes après avec le vrai trajet en trottinette et les montées.")
                    Text("C'est toujours vous qui acceptez ou refusez dans Uber Driver.")
                }
                Section("À la fin") {
                    Text("Touchez la pastille rouge › **Arrêter**, ou revenez ici.")
                }
                Section("Bon à savoir") {
                    Text("C'est de la lecture d'écran, pas un accès aux données d'Uber : si Uber change l'affichage de ses offres, la lecture peut se tromper. Les champs douteux sont signalés « À vérifier ».")
                    Text("Pendant la diffusion, ce qui est à l'écran est lu par Scoot Route sur l'iPhone. Rien n'est enregistré ni envoyé. Arrêtez la veille quand vous ne travaillez pas.")
                    Text("Batterie : la lecture d'une image toutes les 1,5 seconde consomme un peu plus que d'habitude.")
                }
            }
            .navigationTitle("Veille des offres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

/// Correction manuelle de ce que la lecture automatique a mal compris.
struct OfferEditView: View {
    let offer: OfferAnalysis
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @State private var pickup = ""
    @State private var dropoff = ""
    @State private var km = ""
    @State private var minutes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Rémunération") {
                    TextField("Prix de la course (€)", text: $price).keyboardType(.decimalPad)
                }
                Section {
                    TextField("Restaurant (nom ou adresse)", text: $pickup)
                    TextField("Adresse du client", text: $dropoff)
                } header: {
                    Text("Adresses")
                } footer: {
                    Text("Elles servent à calculer le vrai trajet en trottinette, avec les montées.")
                }
                Section("Valeurs affichées par l'offre") {
                    TextField("Distance totale (km)", text: $km).keyboardType(.decimalPad)
                    TextField("Durée totale (min)", text: $minutes).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Corriger l'offre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculer") {
                        var p = offer.parsed
                        p.priceEur = number(price)
                        p.announcedDistanceKm = number(km)
                        p.announcedDurationMin = number(minutes)
                        let placesChanged = pickup != (offer.parsed.pickupText ?? "") || dropoff != (offer.parsed.dropoffText ?? "")
                        p.pickupText = pickup.isEmpty ? nil : pickup
                        p.dropoffText = dropoff.isEmpty ? nil : dropoff
                        p.uncertain = nil   // vérifié par le livreur
                        dismiss()
                        Task { await model.reanalyzeOffer(p, keepPlaces: !placesChanged) }
                    }
                }
            }
            .onAppear {
                price = offer.parsed.priceEur.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
                pickup = offer.parsed.pickupText ?? ""
                dropoff = offer.parsed.dropoffText ?? ""
                km = offer.parsed.announcedDistanceKm.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
                minutes = offer.parsed.announcedDurationMin.map { String(Int($0)) } ?? ""
            }
        }
    }

    private func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }
}

/// Mode d'emploi du raccourci « toucher le dos de l'iPhone ».
struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("1. Créer le raccourci (une seule fois)") {
                    Text("Ouvrez l'app **Raccourcis** › **+** (en haut à droite).")
                    Text("Ajoutez l'action **Prendre une capture d'écran**.")
                    Text("Ajoutez l'action **Analyser une offre de course** (Scoot Route). Elle reçoit automatiquement la capture.")
                    Text("Nommez le raccourci « Offre trottinette » et validez.")
                }
                Section("2. Le lancer en touchant le dos de l'iPhone") {
                    Text("**Réglages** › **Accessibilité** › **Toucher** › **Toucher le dos**.")
                    Text("Choisissez **Toucher deux fois**, puis le raccourci « Offre trottinette ».")
                }
                Section("3. En livraison") {
                    Text("Quand une offre apparaît dans Uber Eats, tapotez deux fois le dos de l'iPhone : le verdict s'affiche en haut de l'écran en 2 à 4 secondes, sans quitter Uber Eats.")
                    Text("Le détail reste disponible dans l'onglet **Offre** de Scoot Route.")
                }
                Section {
                    Text("Le PC (serveur) doit être allumé pour le calcul des montées. Sans connexion, l'analyse utilise la distance et la durée affichées sur l'offre.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Raccourci « toucher le dos »")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
