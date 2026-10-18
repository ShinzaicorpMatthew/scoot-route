import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false
    @State private var showProfile = false
    @State private var pairingCode = ServerLink.code ?? ""
    @State private var linkStatus: String?
    @State private var linking = false
    @State private var serverURL = AppConfig.apiBaseURL.absoluteString

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Button {
                        showProfile = true
                    } label: {
                        Label("Ma trottinette et ma batterie", systemImage: "scooter")
                    }
                }
                Section {
                    Picker("Profil sélectionné par défaut", selection: $model.settings.defaultProfile) {
                        Text("Rapide").tag("fast")
                        Text("Éco").tag("eco")
                        Text("Équilibré").tag("balanced")
                    }
                } header: {
                    Text("Profils de routage")
                } footer: {
                    Text("Les trois profils sont toujours calculés. Les réglages ci-dessous personnalisent le profil Équilibré et le classement « recommandé ».")
                }

                Section("Importance de chaque critère") {
                    weightSlider("Temps de trajet", value: $model.settings.weights.time)
                    weightSlider("Distance", value: $model.settings.weights.distance)
                    weightSlider("Dénivelé cumulé", value: $model.settings.weights.climb)
                    weightSlider("Pentes raides", value: $model.settings.weights.slope)
                    weightSlider("Revêtement (pavés, non revêtu)", value: $model.settings.weights.surface)
                    weightSlider("Sécurité (pistes cyclables)", value: $model.settings.weights.safety)
                    Button("Valeurs par défaut") { model.settings.weights = .balancedDefault }
                }

                Section("Guidage") {
                    Toggle("Guidage vocal en français", isOn: $model.settings.voiceGuidance)
                    Picker("Unités", selection: $model.settings.unit) {
                        ForEach(DistanceUnit.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Toggle("Enregistrer l'historique des trajets", isOn: $model.settings.keepHistory)
                    Button("Effacer l'historique", role: .destructive) { confirmDelete = true }
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Autorisations de localisation", destination: url)
                    }
                } header: {
                    Text("Confidentialité")
                } footer: {
                    Text("L'historique et le profil restent sur cet iPhone. Seuls le départ et l'arrivée de chaque calcul sont envoyés au serveur Scoot Route, qui ne les conserve pas. Les signalements sont associés à un identifiant anonyme.")
                }

                Section {
                    LabeledContent("Cartes hors ligne", value: "Non disponible")
                } header: {
                    Text("Hors ligne")
                } footer: {
                    Text("Le calcul d'itinéraire se fait sur le serveur. Un itinéraire déjà calculé reste suivi sans réseau, mais le recalcul nécessite une connexion.")
                }

                Section("Sources des données") {
                    if let map = model.serverMeta?.map {
                        LabeledContent("Carte", value: map.source ?? "OpenStreetMap")
                        LabeledContent("Données du", value: Fmt.isoDate(map.dataDate ?? map.importDate) ?? "inconnue")
                    } else {
                        Text("Serveur non joignable").foregroundStyle(.secondary)
                    }
                    if let works = model.serverMeta?.works {
                        LabeledContent("Chantiers Métropole", value: works.available == true ? "\(works.count ?? 0) actifs" : "indisponibles")
                        if let f = Fmt.isoDate(works.fetchedAt) { LabeledContent("Relevés le", value: f) }
                    }
                    LabeledContent("Altitude", value: model.serverMeta?.elevationSource ?? "—")
                    Text("Aucune de ces sources n'est en temps réel : OpenStreetMap est rafraîchi chaque nuit, les chantiers toutes les 6 heures.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("© contributeurs OpenStreetMap (ODbL) · Métropole de Lyon (Licence Ouverte) · IGN RGE ALTI®")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Code de liaison (ex. K7Q2-9FMX-3HPA)", text: $pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        Task { await link() }
                    } label: {
                        HStack {
                            if linking { ProgressView() }
                            Text("Lier mon serveur")
                        }
                    }
                    .disabled(ServerLink.normalize(pairingCode).count < 8 || linking)
                    if let linkStatus { Text(linkStatus).font(.caption) }
                    if let sync = ServerLink.lastSync {
                        Text("Dernière synchronisation : \(sync.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Liaison automatique")
                } footer: {
                    Text("Sur le PC, ouvrez http://localhost:8080/liaison pour voir le code. Une fois lié, l'app retrouve seule l'adresse du serveur à chaque redémarrage : plus rien à copier.")
                }

                Section {
                    TextField("https://…trycloudflare.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Enregistrer et tester") {
                        AppConfig.setServerOverride(serverURL)
                        serverURL = AppConfig.apiBaseURL.absoluteString
                        Task { await model.loadServerMeta() }
                    }
                    Text(model.serverMeta == nil ? "Serveur non joignable" : "Serveur connecté ✓")
                        .font(.caption)
                        .foregroundStyle(model.serverMeta == nil ? Theme.restriction : Theme.cycle)
                } header: {
                    Text("Adresse du serveur (manuel)")
                } footer: {
                    Text("Remplie automatiquement par la liaison. À ne modifier qu'en dépannage.")
                }
            }
            .navigationTitle("Réglages")
            .sheet(isPresented: $showProfile) { ProfileView().environment(model) }
            .task { await model.loadServerMeta() }
            .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Effacer", role: .destructive) {
                    try? context.delete(model: TripRecord.self)
                    try? context.save()
                }
            }
        }
    }

    private func weightSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(level(value.wrappedValue)).foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: value, in: 0...1, step: 0.1)
        }
    }

    private func level(_ v: Double) -> String {
        switch v {
        case ..<0.15: return "ignoré"
        case ..<0.45: return "faible"
        case ..<0.75: return "moyen"
        default: return "prioritaire"
        }
    }

    private func link() async {
        linking = true
        defer { linking = false }
        ServerLink.code = pairingCode.trimmingCharacters(in: .whitespaces)
        switch await ServerLink.refresh() {
        case let .updated(url):
            serverURL = url
            linkStatus = "Lié ✓ — serveur \(url)"
        case .unchanged:
            serverURL = AppConfig.apiBaseURL.absoluteString
            linkStatus = "Lié ✓"
        case .notFound:
            linkStatus = "Aucune adresse publiée pour ce code. Vérifiez le code et que le PC et Docker sont allumés (attendez 2 minutes après le démarrage)."
        case .noCode:
            linkStatus = "Code invalide."
        }
        await model.loadServerMeta()
    }
}
