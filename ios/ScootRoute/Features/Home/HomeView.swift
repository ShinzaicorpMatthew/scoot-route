import SwiftUI
import MapKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(SearchService.lyonRegion))
    @State private var editingField: AppModel.Field?
    @State private var detailRoute: PlannedRoute?

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
                if let o = model.origin, !model.preparing {
                    Marker("Départ", systemImage: "smallcircle.filled.circle", coordinate: o.coordinate).tint(.gray)
                }
                if let r = model.restaurant {
                    Marker(r.title, systemImage: "fork.knife", coordinate: r.coordinate).tint(.orange)
                }
                if let c = model.customer {
                    Marker(c.title, systemImage: "house.fill", coordinate: c.coordinate).tint(Theme.route)
                }
                if let plan = model.plan {
                    ForEach(plan.routes.filter { $0.id != model.selectedRoute?.id }) { r in
                        MapPolyline(coordinates: r.coordinates)
                            .stroke(Theme.alternative, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let selected = model.selectedRoute {
                        RouteOverlay(route: selected)
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                AddressPanel(editingField: $editingField)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer()
                bottomPanel
            }
        }
        .sheet(item: $editingField) { field in
            PlaceSearchSheet(field: field)
                .environment(model)
        }
        .sheet(item: $detailRoute) { route in
            RouteDetailView(route: route)
                .environment(model)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: model.plan?.routes.first?.id) { _, _ in
            if let route = model.selectedRoute { fit(route.coordinates) }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.restriction.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            }
            if !model.network.isConnected {
                Label("Hors ligne", systemImage: "wifi.slash")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
            }

            if let plan = model.plan {
                RouteComparisonView(plan: plan, onDetail: { detailRoute = $0 })
                Button {
                    model.startNavigation()
                } label: {
                    Label("Démarrer la navigation", systemImage: "location.north.line.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.preparing)
                if model.preparing {
                    Text("Mode préparation : trajet restaurant → client calculé à l'avance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await model.planRoute() }
                } label: {
                    HStack {
                        if model.isPlanning { ProgressView().tint(.white) }
                        Text(model.isPlanning ? "Calcul en cours…" : "Calculer mon trajet")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPlanning || model.currentDestination == nil)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func fit(_ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        let padX = rect.size.width * 0.25, padY = rect.size.height * 0.6
        rect = rect.insetBy(dx: -padX, dy: -padY)
        withAnimation { camera = .rect(rect) }
    }
}

/// Tracé de l'itinéraire sélectionné : bleu, avec en surimpression le vert (pistes cyclables),
/// l'orange (difficultés) et le rouge (restrictions / chantiers).
struct RouteOverlay: MapContent {
    let route: PlannedRoute

    var body: some MapContent {
        let coords = route.coordinates
        MapPolyline(coordinates: coords)
            .stroke(Theme.route, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        ForEach(Array(route.segments.enumerated()), id: \.offset) { _, seg in
            if seg.kind != .normal, seg.fromIndex < seg.toIndex, seg.toIndex < coords.count {
                MapPolyline(coordinates: Array(coords[seg.fromIndex...seg.toIndex]))
                    .stroke(Theme.color(for: seg.kind), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
    }
}

/// Champs Départ / Restaurant / Client.
struct AddressPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var editingField: AppModel.Field?

    var body: some View {
        VStack(spacing: 0) {
            row(.origin, icon: "location.fill", color: .gray,
                title: model.preparing ? (model.restaurant?.title ?? "Restaurant")
                    : (model.origin?.title ?? "Ma position (GPS)"),
                placeholder: "Départ")
            Divider().padding(.leading, 44)
            row(.restaurant, icon: "fork.knife", color: .orange,
                title: model.restaurant?.title, placeholder: "Restaurant (facultatif)",
                done: model.pickedUp)
            Divider().padding(.leading, 44)
            row(.customer, icon: "house.fill", color: Theme.route,
                title: model.customer?.title, placeholder: "Adresse du client")
            if model.restaurant != nil && model.customer != nil {
                Divider()
                Toggle(isOn: Binding(get: { model.preparing }, set: { model.preparing = $0; model.plan = nil })) {
                    Label("Préparer resto → client", systemImage: "list.bullet.clipboard")
                        .font(.subheadline)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ field: AppModel.Field, icon: String, color: Color, title: String?, placeholder: String, done: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .foregroundStyle(done ? .green : color)
                .frame(width: 20)
            Button { editingField = field } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title ?? placeholder)
                        .foregroundStyle(title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if let p = model.place(for: field), !p.accessPointConfirmed, field != .origin {
                        Text("Point d'accès à vérifier")
                            .font(.caption2)
                            .foregroundStyle(Theme.difficulty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.place(for: field) != nil {
                Button { model.set(nil, for: field) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
    }
}
