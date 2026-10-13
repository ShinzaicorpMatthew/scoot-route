import SwiftUI
import MapKit

/// Navigation plein écran. Conçue pour être lue d'un coup d'œil et guidée à la voix :
/// les actions (signaler, options) ne sont disponibles qu'à l'arrêt.
struct NavigationScreen: View {
    let engine: NavigationEngine
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var camera: MapCameraPosition = .automatic
    @State private var showFinish = false
    @State private var showReport = false
    /// Caméra qui suit le livreur (désactivée quand il déplace la carte à la main)
    @State private var following = true
    @State private var mapHeading: Double = 0
    @State private var lastCameraTarget: CLLocationCoordinate2D?

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                RouteOverlay(route: engine.route)
                if engine.traveledCoordinates.count >= 2 {
                    MapPolyline(coordinates: engine.traveledCoordinates)
                        .stroke(Color(white: 0.62), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                }
                if let turn = engine.nextManeuverCoordinate {
                    Annotation("", coordinate: turn, anchor: .center) {
                        Image(systemName: Maneuver.symbol(for: engine.nextInstruction?.sign ?? 0))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.guidance))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                Marker(engine.destination.title, systemImage: "flag.checkered", coordinate: engine.destination.coordinate)
                    .tint(Theme.restriction)
                if let here = engine.displayCoordinate {
                    Annotation("", coordinate: here, anchor: .center) {
                        NavigationArrow(rotation: engine.displayHeading - mapHeading)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .continuous) { ctx in
                mapHeading = ctx.camera.heading
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                // L'utilisateur a déplacé la carte : on arrête de le suivre jusqu'à « Recentrer »
                if following, let target = lastCameraTarget,
                   GeoMath.distance(ctx.camera.centerCoordinate, target) > 60 {
                    following = false
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                maneuverBanner
                if let banner = engine.banner { statusBanner(banner) }
                Spacer()
                if !following {
                    HStack {
                        Button {
                            following = true
                            followUser()
                        } label: {
                            Label("Recentrer", systemImage: "location.north.line.fill")
                                .font(.headline)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(.regularMaterial, in: Capsule())
                        }
                        Spacer()
                    }
                }
                bottomBar
            }
            .padding(.horizontal, 10)
        }
        .onAppear { followUser() }
        .onChange(of: engine.lastFix) { _, _ in followUser() }
        .onChange(of: engine.arrived) { _, arrived in if arrived { showFinish = true } }
        .sheet(isPresented: $showFinish) {
            FinishTripSheet(engine: engine) { battery in
                showFinish = false
                model.finishNavigation(context: context, batteryEndPercent: battery)
            }
            .presentationDetents([.medium])
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showReport) {
            ReportFormView(initialCoordinate: model.location.location?.coordinate)
                .environment(model)
        }
        .statusBarHidden(false)
    }

    // MARK: Caméra façon GPS

    /// Carte inclinée, orientée dans le sens de marche, la flèche placée en bas de l'écran.
    private func followUser() {
        guard following, let here = engine.displayCoordinate else { return }
        let heading = engine.displayHeading
        let distance: Double = engine.currentSpeedKmh > 18 ? 480 : 340
        let center = GeoMath.offset(here, meters: distance * 0.3, bearing: heading)
        lastCameraTarget = center
        withAnimation(.easeInOut(duration: 0.9)) {
            camera = .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: 55))
        }
    }

    // MARK: Prochaine manœuvre

    private var maneuverBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: Maneuver.symbol(for: engine.nextInstruction?.sign ?? 0))
                    .font(.system(size: 44, weight: .bold))
                    .frame(width: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.distance(engine.progress.distanceToNextManeuver))
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(streetTitle(engine.nextInstruction))
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if let then = engine.followingInstruction, engine.progress.distanceToNextManeuver < 400 {
                HStack(spacing: 8) {
                    Text("Puis").font(.subheadline.weight(.semibold))
                    Image(systemName: Maneuver.symbol(for: then.sign)).font(.subheadline.weight(.bold))
                    if !then.street.isEmpty { Text(then.street).font(.subheadline).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.guidanceDark)
            }
        }
        .foregroundStyle(.white)
        .background(Theme.guidance)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4)
        .accessibilityElement(children: .combine)
    }

    /// Nom de la rue à prendre en grand (plus lisible que la phrase complète).
    private func streetTitle(_ ins: RouteInstruction?) -> String {
        guard let ins else { return "Suivez l'itinéraire" }
        if ins.isArrival { return engine.destination.title }
        return ins.street.isEmpty ? ins.text : ins.street
    }

    @ViewBuilder
    private func statusBanner(_ banner: NavigationEngine.Banner) -> some View {
        switch banner {
        case .rerouting:
            label("Recalcul de l'itinéraire…", icon: "arrow.triangle.2.circlepath", color: Theme.route)
        case let .rerouteFailed(message):
            HStack {
                label(message, icon: "exclamationmark.triangle.fill", color: Theme.restriction)
                if engine.isStopped { Button("Réessayer") { engine.retryReroute() }.buttonStyle(.borderedProminent) }
            }
        case .gpsWeak:
            label("Signal GPS faible : position approximative", icon: "location.slash", color: Theme.difficulty)
        case .offline:
            label("Hors ligne : guidage maintenu, recalcul impossible", icon: "wifi.slash", color: Theme.difficulty)
        case let .hazard(text):
            label(text, icon: "exclamationmark.octagon.fill", color: Theme.restriction)
        }
    }

    private func label(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Barre du bas

    private var bottomBar: some View {
        let est = BatteryEstimator.estimate(
            distanceM: engine.progress.remainingDistance, durationS: engine.progress.remainingDuration,
            ascentM: engine.progress.remainingAscent, descentM: 0, vehicle: model.vehicle)
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                stat(Fmt.eta(after: engine.progress.remainingDuration), "arrivée")
                Spacer()
                stat(Fmt.duration(engine.progress.remainingDuration), "restant")
                Spacer()
                stat(Fmt.distance(engine.progress.remainingDistance), "distance")
                Spacer()
                stat("↑ \(Fmt.meters(engine.progress.remainingAscent))", "à monter")
            }
            HStack {
                Label("\(Int(max(0, model.vehicle.batteryPercent - est.percentUsed).rounded())) % estimés à l'arrivée",
                      systemImage: "battery.75percent")
                    .font(.footnote)
                    .foregroundStyle(Theme.color(for: est.risk))
                Spacer()
                Button {
                    engine.voiceEnabled.toggle()
                } label: {
                    Image(systemName: engine.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .accessibilityLabel(engine.voiceEnabled ? "Couper la voix" : "Activer la voix")
                Button { showReport = true } label: { Image(systemName: "exclamationmark.bubble") }
                    .disabled(!engine.isStopped)
                    .accessibilityLabel("Signaler un problème")
                Button("Terminer", role: .destructive) { showFinish = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.restriction)
            }
            if !engine.isStopped {
                Text("Gardez les yeux sur la route : suivez le guidage vocal et n'interagissez qu'à l'arrêt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.bottom, 4)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.headline.monospacedDigit())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Fin de trajet : saisie facultative de la batterie restante pour affiner les estimations.
struct FinishTripSheet: View {
    let engine: NavigationEngine
    let onDone: (Double?) -> Void
    @Environment(AppModel.self) private var model
    @State private var batteryText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(engine.arrived ? "Vous êtes arrivé : \(engine.destination.title)" : "Arrêter la navigation ?")
                        .font(.headline)
                    LabeledContent("Durée", value: Fmt.duration(Date().timeIntervalSince(engine.startDate)))
                    LabeledContent("Distance parcourue", value: Fmt.distance(engine.traveledDistance))
                }
                Section {
                    TextField("Batterie restante (%)", text: $batteryText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Facultatif. En indiquant le niveau affiché par votre trottinette, les estimations de consommation s'ajustent à votre usage réel.")
                }
                if model.restaurant != nil, !model.pickedUp, engine.destination == model.restaurant {
                    Text("Après validation, l'étape suivante sera l'adresse du client.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Fin du trajet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        let value = Double(batteryText.replacingOccurrences(of: ",", with: "."))
                        onDone(value.map { min(100, max(0, $0)) })
                    }
                }
            }
        }
    }
}


/// Flèche de position façon GPS : pointe dans le sens de marche.
struct NavigationArrow: View {
    let rotation: Double

    var body: some View {
        ZStack {
            Circle().fill(Theme.route.opacity(0.18)).frame(width: 66, height: 66)
            Circle().fill(.white).frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.route)
                .rotationEffect(.degrees(rotation))
        }
        .accessibilityLabel("Votre position")
    }
}
