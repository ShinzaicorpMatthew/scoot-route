import SwiftUI
import MapKit

/// Recherche d'adresse avec autocomplétion, collage, choix sur la carte et vérification
/// du point d'accès exact (entrée de l'immeuble, porte du restaurant…).
struct PlaceSearchSheet: View {
    let field: AppModel.Field
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path: [PickTarget] = []
    @State private var error: String?
    @State private var busy = false

    struct PickTarget: Hashable {
        let latitude: Double
        let longitude: Double
        let title: String
        let subtitle: String
    }

    private var title: String {
        switch field {
        case .origin: return "Départ"
        case .restaurant: return "Restaurant"
        case .customer: return "Client"
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if field == .origin {
                        Button {
                            model.set(nil, for: .origin)
                            dismiss()
                        } label: { Label("Ma position actuelle (GPS)", systemImage: "location.fill") }
                    }
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { await importPasted(text) }
                    }
                    .labelStyle(.titleAndIcon)
                    Button {
                        let center = model.place(for: field)?.coordinate
                            ?? model.location.location?.coordinate
                            ?? SearchService.lyonRegion.center
                        path.append(PickTarget(latitude: center.latitude, longitude: center.longitude, title: "", subtitle: ""))
                    } label: { Label("Choisir sur la carte", systemImage: "mappin.and.ellipse") }
                }

                if busy { HStack { ProgressView(); Text("Recherche…") } }
                if let error { Text(error).foregroundStyle(Theme.restriction).font(.callout) }

                if !model.search.suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(model.search.suggestions, id: \.self) { s in
                            Button {
                                Task { await select(s) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(s.title).foregroundStyle(.primary)
                                    if !s.subtitle.isEmpty {
                                        Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: field == .restaurant ? "Nom ou adresse du restaurant" : "Adresse")
            .onChange(of: query) { _, q in model.search.update(query: q, near: model.location.location) }
            .onSubmit(of: .search) { Task { await geocodeQuery() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .navigationDestination(for: PickTarget.self) { target in
                AccessPointPicker(target: target) { place in
                    model.set(place, for: field)
                    dismiss()
                }
                .environment(model)
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        busy = true; defer { busy = false }
        do {
            let place = try await model.search.resolve(completion)
            openPicker(for: place)
        } catch { self.error = error.localizedDescription }
    }

    private func geocodeQuery() async {
        guard query.count >= 3 else { return }
        busy = true; defer { busy = false }
        do { openPicker(for: try await model.search.geocode(query)) }
        catch { self.error = error.localizedDescription }
    }

    private func importPasted(_ text: String) async {
        busy = true; defer { busy = false }
        error = nil
        model.errorMessage = nil
        await model.importText(text, into: field)
        if let message = model.errorMessage {
            error = message
            model.errorMessage = nil
        } else if let place = model.place(for: field) {
            openPicker(for: place)
        }
    }

    private func openPicker(for place: Place) {
        path.append(PickTarget(latitude: place.latitude, longitude: place.longitude, title: place.title, subtitle: place.subtitle))
    }
}

/// Vérification du point exact : on déplace la carte sous le repère central.
struct AccessPointPicker: View {
    let target: PlaceSearchSheet.PickTarget
    let onConfirm: (Place) -> Void
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var resolving = false

    init(target: PlaceSearchSheet.PickTarget, onConfirm: @escaping (Place) -> Void) {
        self.target = target
        self.onConfirm = onConfirm
        let c = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
        _center = State(initialValue: c)
        _camera = State(initialValue: .camera(MapCamera(centerCoordinate: c, distance: 350)))
    }

    var body: some View {
        ZStack {
            Map(position: $camera) { UserAnnotation() }
                .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .including([.restaurant, .cafe])))
                .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
            Image(systemName: "mappin")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.restriction)
                .offset(y: -20)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text(target.title.isEmpty ? "Placez le repère sur le point voulu" : target.title)
                    .font(.headline)
                Text("Déplacez la carte pour placer le repère sur l'entrée exacte (porte, accès livreur).")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    Task { await confirm() }
                } label: {
                    HStack {
                        if resolving { ProgressView() }
                        Text("Valider ce point d'accès")
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial)
        }
        .navigationTitle("Point d'accès")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func confirm() async {
        resolving = true; defer { resolving = false }
        var place = await model.search.reverseGeocode(center)
        if !target.title.isEmpty {
            place.title = target.title
            if !target.subtitle.isEmpty { place.subtitle = target.subtitle }
        }
        place.accessPointConfirmed = true
        onConfirm(place)
    }
}
