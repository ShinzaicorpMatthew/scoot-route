import Foundation
import CoreLocation
import SwiftData
import Observation

/// État global de l'application.
@MainActor
@Observable
final class AppModel {
    enum Field: String, Identifiable { case origin, restaurant, customer; var id: String { rawValue } }
    enum Tab: Hashable { case route, offer, history, reports, settings }

    var selectedTab: Tab = .route

    // MARK: Offres de course
    var lastOffer: OfferAnalysis?
    var isAnalyzingOffer = false
    var offerSettings: OfferSettings {
        didSet { LocalStore.save(offerSettings, key: "offerSettings") }
    }

    let location = LocationService()
    let search = SearchService()
    let network = NetworkMonitor()

    /// nil = position GPS actuelle
    var origin: Place?
    var restaurant: Place?
    var customer: Place?
    /// Commande récupérée : la prochaine étape devient le client
    var pickedUp = false
    /// Mode préparation : trajet restaurant → client calculé à l'avance
    var preparing = false

    var plan: RoutePlanResponse?
    var selectedRouteID: String?
    var isPlanning = false
    var errorMessage: String?
    var navigation: NavigationEngine?
    var serverMeta: ServerMeta?

    var vehicle: VehicleProfile {
        didSet { LocalStore.save(vehicle, key: "vehicle") }
    }
    var settings: AppSettings {
        didSet { LocalStore.save(settings, key: "settings"); Fmt.unit = settings.unit }
    }

    init() {
        SharedStore.migrateIfNeeded()   // réglages partagés avec la veille des offres
        vehicle = LocalStore.load(VehicleProfile.self, key: "vehicle", default: VehicleProfile())
        settings = LocalStore.load(AppSettings.self, key: "settings", default: AppSettings())
        offerSettings = LocalStore.load(OfferSettings.self, key: "offerSettings", default: OfferSettings())
        lastOffer = LocalStore.load(OfferAnalysis?.self, key: OfferAnalysis.storeKey, default: nil)
        Fmt.unit = settings.unit
    }

    // MARK: Analyse d'offre

    private var offerAnalyzer: OfferAnalyzer {
        OfferAnalyzer(vehicle: vehicle, settings: settings, offerSettings: offerSettings)
    }

    func reloadLastOffer() {
        lastOffer = LocalStore.load(OfferAnalysis?.self, key: OfferAnalysis.storeKey, default: nil)
        // Le raccourci a pu enregistrer un nouveau niveau de batterie
        let stored = LocalStore.load(VehicleProfile.self, key: "vehicle", default: vehicle)
        if stored != vehicle { vehicle = stored }
        refineWatchedOfferIfNeeded()
    }

    /// Offre lue par la veille sans trajet trottinette (serveur trop lent, position inconnue) :
    /// à l'ouverture de l'app, on calcule le vrai trajet avec la position actuelle.
    private func refineWatchedOfferIfNeeded() {
        guard let offer = lastOffer, offer.via == "watch", !isAnalyzingOffer,
              offer.evaluation?.source != .scooterRoute,
              Date().timeIntervalSince(offer.date) < 15 * 60 else { return }
        Task { await reanalyzeOffer(offer.parsed, keepPlaces: false) }
    }

    var batteryMessage: String?

    /// Capture d'écran de l'app de la trottinette (Dualtron…) : on lit le niveau de batterie.
    func readBatteryScreenshot(_ data: Data) async {
        batteryMessage = nil
        do {
            let lines = try await OfferOCR.recognizeLines(in: data)
            guard let reading = BatteryScreenParser.parse(lines: lines, nominalVoltage: vehicle.nominalVoltage),
                  reading.effectivePercent != nil else {
                batteryMessage = "Aucun pourcentage ni tension de batterie trouvé sur cette capture."
                return
            }
            vehicle = OfferAnalyzer.apply(reading, to: vehicle)
            batteryMessage = OfferAnalyzer.batterySummary(reading, vehicle: vehicle)
        } catch {
            batteryMessage = error.localizedDescription
        }
    }

    func analyzeOffer(imageData: Data) async {
        isAnalyzingOffer = true
        defer { isAnalyzingOffer = false }
        do {
            let result = try await offerAnalyzer.analyze(imageData: imageData, origin: location.location?.coordinate)
            lastOffer = result
            LocalStore.save(result, key: OfferAnalysis.storeKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recalcul après correction manuelle (prix, restaurant, client).
    func reanalyzeOffer(_ parsed: ParsedOffer, keepPlaces: Bool) async {
        isAnalyzingOffer = true
        defer { isAnalyzingOffer = false }
        var result = await offerAnalyzer.analyze(
            parsed: parsed, origin: location.location?.coordinate ?? OfferAnalyzer.lastKnownLocation(),
            pickup: keepPlaces ? lastOffer?.pickup : nil, dropoff: keepPlaces ? lastOffer?.dropoff : nil)
        result.via = lastOffer?.via
        lastOffer = result
        LocalStore.save(result, key: OfferAnalysis.storeKey)
    }

    /// Offre acceptée : on prépare le trajet restaurant puis client.
    func startOfferRoute() async {
        guard let offer = lastOffer else { return }
        resetDelivery()
        restaurant = offer.pickup
        customer = offer.dropoff
        selectedTab = .route
        await planRoute()
    }

    // MARK: Étapes

    var effectiveOrigin: Place? {
        if preparing, let restaurant { return restaurant }
        if let origin { return origin }
        guard let loc = location.location else { return nil }
        return Place(title: "Ma position", coordinate: loc.coordinate)
    }

    var currentDestination: Place? {
        if preparing { return customer }
        if let restaurant, !pickedUp { return restaurant }
        return customer
    }

    var selectedRoute: PlannedRoute? {
        plan?.routes.first { $0.id == selectedRouteID } ?? plan?.routes.first
    }

    func set(_ place: Place?, for field: Field) {
        switch field {
        case .origin: origin = place
        case .restaurant: restaurant = place
        case .customer: customer = place
        }
        plan = nil
    }

    func place(for field: Field) -> Place? {
        switch field {
        case .origin: return origin
        case .restaurant: return restaurant
        case .customer: return customer
        }
    }

    // MARK: Calcul

    func planRoute() async {
        errorMessage = nil
        guard let from = effectiveOrigin else {
            errorMessage = location.isAuthorized
                ? "Position GPS en cours d'acquisition… ou saisissez une adresse de départ."
                : "Autorisez la localisation ou saisissez une adresse de départ."
            return
        }
        guard let to = currentDestination else {
            errorMessage = "Saisissez l'adresse du restaurant ou du client."
            return
        }
        guard network.isConnected else { errorMessage = APIError.offline.errorDescription; return }
        isPlanning = true
        defer { isPlanning = false }
        do {
            let result = try await RoutingAPI.shared.planRoutes(
                from: from.coordinate, to: to.coordinate, weights: settings.weights,
                maxSpeedKmh: vehicle.cruiseSpeedKmh)
            plan = result
            let preferred = result.routes.first { $0.id == settings.defaultProfile || ($0.alsoMatches ?? []).contains(settings.defaultProfile) }
            selectedRouteID = preferred?.id ?? result.recommendedId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func estimate(_ route: PlannedRoute) -> BatteryEstimate {
        BatteryEstimator.estimate(route: route, vehicle: vehicle)
    }

    /// Itinéraire le moins énergivore parmi ceux proposés.
    var leastEnergyRoute: PlannedRoute? {
        plan?.routes.min { estimate($0).energyWh < estimate($1).energyWh }
    }

    // MARK: Navigation

    func startNavigation() {
        guard let route = selectedRoute, let from = effectiveOrigin, let to = currentDestination else { return }
        let engine = NavigationEngine(
            route: route, origin: from, destination: to, weights: settings.weights,
            maxSpeedKmh: vehicle.cruiseSpeedKmh, batteryAtStart: vehicle.batteryPercent,
            voiceEnabled: settings.voiceGuidance)
        engine.isOnline = { [weak self] in self?.network.isConnected ?? false }
        location.startNavigation()
        location.onNavigationUpdate = { [weak engine] loc in engine?.handle(location: loc) }
        engine.start()
        navigation = engine
    }

    /// Termine la navigation, enregistre le trajet et calibre la batterie si le niveau d'arrivée est saisi.
    func finishNavigation(context: ModelContext, batteryEndPercent: Double?) {
        guard let nav = navigation else { return }
        nav.stop()
        location.stopNavigation()
        let route = nav.route
        let est = BatteryEstimator.estimate(route: route, vehicle: vehicle)
        if settings.keepHistory {
            let record = TripRecord(
                fromTitle: nav.origin.title, toTitle: nav.destination.title, profileLabel: route.label,
                plannedDistanceM: route.distanceM, plannedDurationS: route.durationS,
                traveledDistanceM: nav.traveledDistance, actualDurationS: Date().timeIntervalSince(nav.startDate),
                ascentM: route.ascentM, descentM: route.descentM, estimatedWh: est.energyWh,
                batteryStartPercent: nav.batteryAtStart, batteryEndPercent: batteryEndPercent,
                rerouteCount: nav.rerouteCount)
            context.insert(record)
            try? context.save()
        }
        if let end = batteryEndPercent {
            vehicle = BatteryEstimator.calibrate(vehicle: vehicle, estimatedWh: est.energyWh,
                                                 startPercent: nav.batteryAtStart, endPercent: end)
            vehicle.batteryPercent = end
        } else {
            vehicle.batteryPercent = max(0, vehicle.batteryPercent - est.percentUsed)
        }
        if nav.arrived, restaurant != nil, !pickedUp, !preparing, nav.destination == restaurant {
            pickedUp = true
            origin = nil
        }
        navigation = nil
        plan = nil
    }

    func resetDelivery() {
        restaurant = nil
        customer = nil
        origin = nil
        pickedUp = false
        preparing = false
        plan = nil
    }

    // MARK: Import (presse-papiers, partage, lien cartographique)

    func importText(_ text: String, into field: Field = .customer) async {
        guard let parsed = AddressTextParser.parse(text) else {
            errorMessage = "Aucune adresse reconnue dans le texte collé."
            return
        }
        do {
            let place: Place
            switch parsed {
            case let .coordinate(c, label):
                var p = await search.reverseGeocode(c)
                if let label { p.title = label }
                place = p
            case let .address(addr):
                place = try await search.geocode(addr)
            }
            set(place, for: field)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Texte transmis par le raccourci « Itinéraire Scoot Route » (App Intent).
    func consumePendingImport() async {
        guard let text = UserDefaults.standard.string(forKey: PendingImport.key) else { return }
        UserDefaults.standard.removeObject(forKey: PendingImport.key)
        await importText(text, into: .customer)
    }

    func loadServerMeta() async {
        serverMeta = try? await RoutingAPI.shared.meta()
    }
}

enum PendingImport {
    static let key = "pendingImportText"
}
