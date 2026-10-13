import SwiftUI
import MapKit

/// Navigation plein écran. Conçue pour être lue d'un coup d'œil et guidée à la voix :
/// les actions (signaler, options) ne sont disponibles qu'à l'arrêt.
struct NavigationScreen: View {
    let engine: NavigationEngine
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var showFinish = false
    @State private var showReport = false

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
                RouteOverlay(route: engine.route)
                Marker(engine.destination.title, systemImage: "flag.checkered", coordinate: engine.destination.coordinate)
                    .tint(Theme.route)
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapUserLocationButton() }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                maneuverBanner
                if let banner = engine.banner { statusBanner(banner) }
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 10)
        }
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

    // MARK: Prochaine manœuvre

    private var maneuverBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: Maneuver.symbol(for: engine.nextInstruction?.sign ?? 0))
                .font(.system(size: 42, weight: .bold))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.distance(engine.progress.distanceToNextManeuver))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(engine.nextInstruction?.text ?? "Suivez l'itinéraire")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Theme.route.gradient, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4)
        .accessibilityElement(children: .combine)
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
