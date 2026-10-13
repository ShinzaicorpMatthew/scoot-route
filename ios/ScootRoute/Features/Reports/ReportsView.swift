import SwiftUI
import MapKit

enum ReportType: String, CaseIterable, Identifiable {
    case closed, works, noAccess = "no_access", steep, missingCycleway = "missing_cycleway",
         impassableCycleway = "impassable_cycleway", mapError = "map_error"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .closed: return "Chemin fermé"
        case .works: return "Travaux"
        case .noAccess: return "Accès impossible"
        case .steep: return "Pente excessive"
        case .missingCycleway: return "Piste cyclable manquante"
        case .impassableCycleway: return "Piste impraticable"
        case .mapError: return "Erreur cartographique"
        }
    }
    var icon: String {
        switch self {
        case .closed: return "xmark.octagon"
        case .works: return "hammer"
        case .noAccess: return "hand.raised"
        case .steep: return "chart.line.uptrend.xyaxis"
        case .missingCycleway: return "bicycle"
        case .impassableCycleway: return "exclamationmark.triangle"
        case .mapError: return "map"
        }
    }
}

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var showForm = false
    @State private var mine: [ReportRecord] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showForm = true
                    } label: {
                        Label("Nouveau signalement", systemImage: "plus.circle.fill").font(.headline)
                    }
                } footer: {
                    Text("Vos signalements sont vérifiés avant d'être pris en compte dans les itinéraires de tous les livreurs. Une fermeture validée est évitée pendant 14 jours.")
                }
                Section("Mes signalements") {
                    if let loadError { Text(loadError).font(.footnote).foregroundStyle(.secondary) }
                    if mine.isEmpty && loadError == nil {
                        Text("Aucun signalement pour l'instant.").foregroundStyle(.secondary)
                    }
                    ForEach(mine) { r in
                        HStack {
                            Image(systemName: ReportType(rawValue: r.type)?.icon ?? "flag")
                            VStack(alignment: .leading) {
                                Text(ReportType(rawValue: r.type)?.label ?? r.type)
                                Text(Fmt.isoDate(r.createdAt) ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(r.status)
                        }
                    }
                }
            }
            .navigationTitle("Signalements")
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showForm, onDismiss: { Task { await load() } }) {
                ReportFormView(initialCoordinate: model.location.location?.coordinate)
                    .environment(model)
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let (text, color): (String, Color) = switch status {
        case "validated": ("Validé", .green)
        case "rejected": ("Refusé", .secondary)
        default: ("En attente", .orange)
        }
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }

    private func load() async {
        do { mine = try await RoutingAPI.shared.myReports(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

struct ReportFormView: View {
    let initialCoordinate: CLLocationCoordinate2D?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var type: ReportType = .closed
    @State private var comment = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Problème") {
                    Picker("Type", selection: $type) {
                        ForEach(ReportType.allCases) { t in Label(t.label, systemImage: t.icon).tag(t) }
                    }
                    TextField("Précisions (facultatif)", text: $comment, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    ZStack {
                        Map(position: $camera) { UserAnnotation() }
                            .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                        Image(systemName: "mappin").font(.title.bold()).foregroundStyle(Theme.restriction)
                            .offset(y: -12).allowsHitTesting(false)
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Emplacement")
                } footer: {
                    Text("Déplacez la carte pour placer le repère sur le lieu exact.")
                }
                if let result { Text(result).font(.footnote) }
            }
            .navigationTitle("Signaler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") { Task { await send() } }.disabled(sending || center == nil)
                }
            }
            .onAppear {
                let c = initialCoordinate ?? SearchService.lyonRegion.center
                center = c
                camera = .camera(MapCamera(centerCoordinate: c, distance: 600))
            }
        }
    }

    private func send() async {
        guard let center else { return }
        sending = true; defer { sending = false }
        do {
            _ = try await RoutingAPI.shared.sendReport(type: type.rawValue, coordinate: center, comment: comment)
            dismiss()
        } catch {
            result = "Envoi impossible : \(error.localizedDescription)"
        }
    }
}
