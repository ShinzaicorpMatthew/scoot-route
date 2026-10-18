import SwiftUI
import PhotosUI

/// Onglet « Offre » : est-ce que la course proposée vaut le coup en trottinette ?
struct OfferView: View {
    @Environment(AppModel.self) private var model
    @State private var photo: PhotosPickerItem?
    @State private var showShortcutHelp = false
    @State private var editing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photo, matching: .screenshots) {
                        Label("Analyser une capture d'écran d'offre", systemImage: "photo.badge.magnifyingglass")
                            .font(.headline)
                    }
                    Button {
                        showShortcutHelp = true
                    } label: {
                        Label("Analyser sans quitter Uber Eats (toucher le dos)", systemImage: "hand.tap")
                    }
                } footer: {
                    Text("La capture est lue sur votre iPhone. Scoot Route ne se connecte jamais à Uber Eats : c'est vous qui acceptez ou refusez la course dans leur app.")
                }

                if model.isAnalyzingOffer {
                    Section { HStack { ProgressView(); Text("Analyse de l'offre…") } }
                }

                if let offer = model.lastOffer {
                    resultSection(offer)
                    detailsSection(offer)
                    Section {
                        Button {
                            Task { await model.startOfferRoute() }
                        } label: {
                            Label("J'ai accepté : itinéraire vers le restaurant", systemImage: "location.north.line.fill")
                                .font(.headline)
                        }
                        .disabled(offer.pickup == nil || offer.dropoff == nil)
                    }
                } else if !model.isAnalyzingOffer {
                    Section {
                        ContentUnavailableView("Aucune offre analysée", systemImage: "eurosign.circle",
                                               description: Text("Faites une capture d'écran d'une offre, puis analysez-la ici ou avec le raccourci."))
                    }
                }

                thresholdsSection
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
            .sheet(isPresented: $showShortcutHelp) { ShortcutHelpView() }
            .sheet(isPresented: $editing) {
                if let offer = model.lastOffer { OfferEditView(offer: offer).environment(model) }
            }
        }
    }

    // MARK: Verdict

    @ViewBuilder
    private func resultSection(_ offer: OfferAnalysis) -> some View {
        Section {
            if let e = offer.evaluation {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(e.verdictEmoji) \(e.verdictLabel)")
                            .font(.title.bold())
                            .foregroundStyle(color(e.verdict))
                        Spacer()
                        Text(OfferEvaluation.eur(e.priceEur)).font(.title2.bold())
                    }
                    HStack(spacing: 0) {
                        metric(OfferEvaluation.eur(e.eurPerHour), "par heure")
                        metric(OfferEvaluation.eur(e.eurPerKm), "par km")
                        metric("\(Int(e.totalMinutes.rounded())) min", "au total")
                    }
                    HStack(spacing: 0) {
                        metric(OfferEvaluation.km(e.totalKm), "parcourus")
                        metric("↑ \(Int(e.ascentM.rounded())) m", "de montée")
                        metric("\(Int(max(0, e.batteryAtEndPercent).rounded())) %", "batterie à la fin")
                    }
                    ForEach(e.reasons + offer.notes, id: \.self) { r in
                        Label(r, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(e.source == .scooterRoute
                         ? "Calcul : trajet trottinette réel (position → restaurant → client) + \(Int(model.offerSettings.waitAtRestaurantMin + model.offerSettings.handoffMin)) min d'attente et de remise."
                         : "Calcul : distance et durée affichées sur l'offre.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Label(offer.summary, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.difficulty)
                Button("Compléter l'offre") { editing = true }
            }
        } header: {
            Text("Analysée \(offer.date.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func detailsSection(_ offer: OfferAnalysis) -> some View {
        Section("Lu sur la capture") {
            LabeledContent("Restaurant", value: offer.pickup?.title ?? offer.parsed.pickupText ?? "non trouvé")
            LabeledContent("Client", value: offer.dropoff?.title ?? offer.parsed.dropoffText ?? "non trouvé")
            if let km = offer.parsed.announcedDistanceKm { LabeledContent("Distance annoncée", value: OfferEvaluation.km(km)) }
            if let min = offer.parsed.announcedDurationMin { LabeledContent("Durée annoncée", value: "\(Int(min)) min") }
            Button("Corriger une information") { editing = true }
        }
    }

    private var thresholdsSection: some View {
        @Bindable var model = model
        return Section {
            Stepper("Objectif : \(OfferEvaluation.eur(model.offerSettings.targetEurPerHour))/h",
                    value: $model.offerSettings.targetEurPerHour, in: 5...40, step: 0.5)
            Stepper("Minimum : \(OfferEvaluation.eur(model.offerSettings.minEurPerKm))/km",
                    value: $model.offerSettings.minEurPerKm, in: 0.3...3, step: 0.05)
            Stepper("Attente au restaurant : \(Int(model.offerSettings.waitAtRestaurantMin)) min",
                    value: $model.offerSettings.waitAtRestaurantMin, in: 0...20, step: 1)
            Stepper("Remise au client : \(Int(model.offerSettings.handoffMin)) min",
                    value: $model.offerSettings.handoffMin, in: 0...10, step: 1)
        } header: {
            Text("Mes critères de rentabilité")
        } footer: {
            Text("✅ Rentable si les deux objectifs sont atteints, 🟠 Moyen à plus de 80 %, ❌ sinon. Ces valeurs sont des points de départ : ajustez-les selon vos revenus réels.")
        }
    }

    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(_ v: OfferEvaluation.Verdict) -> Color {
        switch v {
        case .good: return .green
        case .average: return .orange
        case .bad: return .red
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
                Section("Si les adresses manquent") {
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
