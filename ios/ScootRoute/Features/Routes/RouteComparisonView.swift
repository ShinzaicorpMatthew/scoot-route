import SwiftUI
import Charts

/// Fiches comparables des itinéraires (rapide / éco / équilibré / alternatives).
struct RouteComparisonView: View {
    let plan: RoutePlanResponse
    let onDetail: (PlannedRoute) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(plan.routes) { route in
                        RouteCard(route: route,
                                  estimate: model.estimate(route),
                                  selected: route.id == model.selectedRoute?.id)
                            .onTapGesture { model.selectedRouteID = route.id }
                            .onLongPressGesture { onDetail(route) }
                    }
                }
                .padding(.horizontal, 2)
            }
            if let selected = model.selectedRoute {
                batteryAdvice(for: selected)
                HStack {
                    DataFreshnessView(meta: plan.meta)
                    Spacer()
                    Button("Détails") { onDetail(selected) }
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func batteryAdvice(for route: PlannedRoute) -> some View {
        let est = model.estimate(route)
        if est.risk != .comfortable {
            HStack(alignment: .top) {
                Image(systemName: "battery.25percent").foregroundStyle(Theme.color(for: est.risk))
                VStack(alignment: .leading, spacing: 4) {
                    Text(est.risk == .insufficient ? "Autonomie probablement insuffisante" : "Autonomie juste")
                        .font(.footnote.weight(.semibold))
                    if let eco = model.leastEnergyRoute, eco.id != route.id {
                        Button("Prendre « \(eco.label) » (\(Int(model.estimate(eco).energyWh.rounded())) Wh)") {
                            model.selectedRouteID = eco.id
                        }
                        .font(.footnote)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.color(for: est.risk).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct RouteCard: View {
    let route: PlannedRoute
    let estimate: BatteryEstimate
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(route.label).font(.headline)
                if route.isRecommended {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        .accessibilityLabel("Recommandé")
                }
                Spacer(minLength: 0)
            }
            if let twins = route.alsoMatches, !twins.isEmpty {
                Text("= " + twins.map(profileName).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(Fmt.duration(route.durationS)).font(.title2.bold())
            Text(Fmt.distance(route.distanceM)).font(.subheadline).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                metric("arrow.up.right", Fmt.meters(route.ascentM))
                metric("arrow.down.right", Fmt.meters(route.descentM))
            }
            HStack(spacing: 10) {
                metric("triangle", Fmt.percent(route.maxSlopeUpPct), color: route.maxSlopeUpPct >= 8 ? Theme.difficulty : .primary)
                metric("bicycle", Fmt.percent(route.shares.cycleInfraPct), color: Theme.cycle)
            }
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.color(for: estimate.risk))
                Text("\(Int(estimate.energyWh.rounded())) Wh · \(Int(max(0, estimate.arrivalPercent).rounded())) % à l'arrivée")
            }
            .font(.caption)
            if route.warnings.contains(where: { $0.level == .restriction }) {
                Label("Restriction", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.restriction)
            } else if !route.warnings.isEmpty {
                Label("\(route.warnings.count) difficulté(s)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.difficulty)
            }
            Circle().fill(Theme.color(forReliability: route.reliability.level)).frame(width: 8, height: 8)
                .overlay(alignment: .leading) {
                    Text(route.reliability.labelFR).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize().offset(x: 12)
                }
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .background(selected ? Theme.route.opacity(0.14) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.route : .clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func metric(_ icon: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func profileName(_ id: String) -> String {
        switch id {
        case "fast": return "Rapide"
        case "eco": return "Éco"
        case "balanced": return "Équilibré"
        default: return id
        }
    }
}

/// Distingue clairement données périodiques et données en direct.
struct DataFreshnessView: View {
    let meta: PlanMeta?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let date = Fmt.isoDate(meta?.map?.dataDate ?? meta?.map?.importDate) {
                Text("Carte OSM du \(date) · non temps réel")
            } else {
                Text("Date des données cartographiques inconnue")
            }
            if meta?.works?.available == true, let fetched = Fmt.isoDate(meta?.works?.fetchedAt) {
                Text("Chantiers Métropole relevés le \(fetched)")
            } else {
                Text("Données chantiers indisponibles")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// Détail d'un itinéraire : profil altimétrique, voies empruntées, alertes, fiabilité.
struct RouteDetailView: View {
    let route: PlannedRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Profil altimétrique") {
                    ElevationChart(samples: route.elevationSamples)
                        .frame(height: 160)
                    LabeledContent("Dénivelé positif", value: Fmt.meters(route.ascentM))
                    LabeledContent("Dénivelé négatif", value: Fmt.meters(route.descentM))
                    LabeledContent("Pente max. en montée", value: Fmt.percent(route.maxSlopeUpPct, decimals: 1))
                    LabeledContent("Pente max. en descente", value: Fmt.percent(route.maxSlopeDownPct, decimals: 1))
                    Text("Source d'altitude : \(route.reliability.elevationSource)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Batterie (estimation)") {
                    let est = model.estimate(route)
                    LabeledContent("Consommation", value: "\(Int(est.energyWh.rounded())) Wh")
                    LabeledContent("Batterie à l'arrivée", value: "\(Int(max(0, est.arrivalPercent).rounded())) %")
                    if est.usesDefaultCapacity {
                        Text("Capacité de batterie non renseignée : valeur par défaut de \(Int(VehicleProfile.defaultBatteryWh)) Wh utilisée (Profil).")
                            .font(.caption).foregroundStyle(Theme.difficulty)
                    }
                    Text(est.isCalibrated ? "Estimation ajustée sur vos trajets réels." : "Approximation : elle s'affine quand vous saisissez la batterie à l'arrivée.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Voies empruntées") {
                    ForEach(route.roadTypes, id: \.roadClass) { t in
                        LabeledContent(t.label, value: Fmt.percent(t.pct))
                    }
                    LabeledContent("Pistes / bandes cyclables", value: Fmt.percent(route.shares.cycleInfraPct))
                    LabeledContent("Non revêtu", value: Fmt.percent(route.shares.unpavedPct, decimals: 1))
                    LabeledContent("Pavés", value: Fmt.percent(route.shares.cobblesPct, decimals: 1))
                    LabeledContent("Revêtement inconnu", value: Fmt.percent(route.shares.unknownSurfacePct))
                }
                if !route.warnings.isEmpty || !route.works.isEmpty {
                    Section("Points d'attention") {
                        ForEach(route.warnings, id: \.self) { w in
                            Label(w.text, systemImage: w.level == .restriction ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(w.level == .restriction ? Theme.restriction : Theme.difficulty)
                        }
                        ForEach(route.works, id: \.self) { w in
                            Text("🚧 \(w.label) — à \(Fmt.distance(w.fromM)) du départ").font(.footnote)
                        }
                    }
                }
                Section("Fiabilité des données : \(route.reliability.score)/100") {
                    if route.reliability.reasons.isEmpty {
                        Text("Données complètes sur ce trajet.").font(.footnote)
                    }
                    ForEach(route.reliability.reasons, id: \.self) { Text($0).font(.footnote) }
                    Text("Les chantiers proviennent de l'open data de la Métropole de Lyon et la carte d'OpenStreetMap : ces sources sont mises à jour périodiquement, pas en temps réel. Vérifiez la signalisation sur place.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Instructions") {
                    ForEach(Array(route.instructions.enumerated()), id: \.offset) { _, ins in
                        HStack {
                            Image(systemName: Maneuver.symbol(for: ins.sign)).frame(width: 24)
                            Text(ins.text)
                            Spacer()
                            if ins.distanceM > 0 { Text(Fmt.distance(ins.distanceM)).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                }
            }
            .navigationTitle(route.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choisir") { model.selectedRouteID = route.id; dismiss() }
                }
            }
        }
    }
}

struct ElevationChart: View {
    let samples: [ElevationSample]

    var body: some View {
        if samples.count < 2 {
            Text("Profil indisponible").foregroundStyle(.secondary)
        } else {
            let minZ = samples.map(\.altitude).min() ?? 0
            let maxZ = samples.map(\.altitude).max() ?? 0
            Chart(samples) { s in
                AreaMark(x: .value("Distance", s.distance / 1000),
                         yStart: .value("Base", minZ - 5),
                         yEnd: .value("Altitude", s.altitude))
                    .foregroundStyle(Theme.route.opacity(0.25))
                LineMark(x: .value("Distance", s.distance / 1000), y: .value("Altitude", s.altitude))
                    .foregroundStyle(Theme.route)
            }
            .chartYScale(domain: (minZ - 5)...(maxZ + 5))
            .chartXAxisLabel("km")
            .chartYAxisLabel("m")
        }
    }
}
