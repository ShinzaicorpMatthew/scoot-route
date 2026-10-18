import Foundation
import CoreLocation
import MapKit
import UIKit
import Vision

/// Résultat complet de l'analyse d'une offre (gardé pour l'onglet Offre).
struct OfferAnalysis: Codable, Equatable {
    var date = Date()
    var parsed: ParsedOffer
    var pickup: Place?
    var dropoff: Place?
    var legs: [OfferLeg]?
    var evaluation: OfferEvaluation?
    var notes: [String] = []

    static let storeKey = "lastOfferAnalysis"

    /// Texte du raccourci : verdict, ou ce qu'il manque.
    var summary: String {
        if let evaluation { return evaluation.summary }
        if parsed.priceEur == nil { return "Prix non lu sur la capture. Ouvrez Scoot Route › Offre pour le saisir." }
        return "Adresses et distance introuvables sur la capture. Ouvrez Scoot Route › Offre pour les compléter."
    }
}

enum OfferError: LocalizedError {
    case badImage
    var errorDescription: String? { "Image illisible." }
}

/// Lecture du texte d'une capture d'écran, entièrement sur l'iPhone (Vision).
enum OfferOCR {
    static func recognizeLines(in data: Data) async throws -> [String] {
        guard let image = UIImage(data: data)?.cgImage else { throw OfferError.badImage }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let observations = request.results ?? []
            // De haut en bas (Vision : origine en bas à gauche), puis de gauche à droite
            return observations
                .sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY
                        : $0.boundingBox.minX < $1.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
        }.value
    }
}

/// Lit l'offre, localise restaurant et client, calcule les trajets trottinette et la rentabilité.
struct OfferAnalyzer {
    var vehicle: VehicleProfile
    var settings: AppSettings
    var offerSettings: OfferSettings
    var api: RoutingAPI = .shared

    /// Profil enregistré sur l'iPhone (utilisé par le raccourci, hors de l'app).
    static func fromStoredPreferences() -> OfferAnalyzer {
        OfferAnalyzer(
            vehicle: LocalStore.load(VehicleProfile.self, key: "vehicle", default: VehicleProfile()),
            settings: LocalStore.load(AppSettings.self, key: "settings", default: AppSettings()),
            offerSettings: LocalStore.load(OfferSettings.self, key: "offerSettings", default: OfferSettings()))
    }

    /// Ce que contenait la capture : une offre de course, ou l'écran batterie de l'app de la trottinette.
    enum ScreenshotResult {
        case offer(OfferAnalysis)
        case battery(BatteryReading, VehicleProfile)
        case unreadable(OfferAnalysis)
    }

    /// Une seule action pour les deux usages : on détecte automatiquement le type d'écran.
    func analyzeScreenshot(imageData: Data, origin: CLLocationCoordinate2D?) async throws -> ScreenshotResult {
        let lines = try await OfferOCR.recognizeLines(in: imageData)
        let parsed = OfferParser.parse(lines: lines)
        if parsed.isUsable {
            return .offer(await analyze(parsed: parsed, origin: origin))
        }
        if let reading = BatteryScreenParser.parse(lines: lines, nominalVoltage: vehicle.nominalVoltage),
           reading.effectivePercent != nil {
            return .battery(reading, Self.apply(reading, to: vehicle))
        }
        return .unreadable(OfferAnalysis(parsed: parsed))
    }

    static func apply(_ reading: BatteryReading, to vehicle: VehicleProfile) -> VehicleProfile {
        var v = vehicle
        if let p = reading.effectivePercent { v.batteryPercent = min(100, max(0, p)) }
        v.lastBatteryVoltage = reading.voltage
        v.lastBatteryReadingDate = Date()
        return v
    }

    static func batterySummary(_ reading: BatteryReading, vehicle: VehicleProfile) -> String {
        let flat = BatteryEstimator.estimate(distanceM: 1000, durationS: 1000 / (max(5, vehicle.cruiseSpeedKmh) / 3.6),
                                             ascentM: 0, descentM: 0, vehicle: vehicle)
        let rangeKm = flat.energyWh > 0 ? vehicle.effectiveBatteryWh * vehicle.batteryPercent / 100 / flat.energyWh : 0
        var text = "🔋 Batterie enregistrée : \(Int(vehicle.batteryPercent.rounded())) %"
        if let v = reading.voltage { text += " (\(String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")) V)" }
        if reading.estimatedFromVoltage { text += ", estimée d'après la tension" }
        text += "\nAutonomie ≈ \(Int(rangeKm)) km sur le plat"
        if vehicle.batteryWh == nil { text += " (capacité non renseignée dans Scoot Route)" }
        return text
    }

    func analyze(imageData: Data, origin: CLLocationCoordinate2D?) async throws -> OfferAnalysis {
        let lines = try await OfferOCR.recognizeLines(in: imageData)
        return await analyze(parsed: OfferParser.parse(lines: lines), origin: origin)
    }

    /// Analyse à partir d'une offre lue (ou corrigée à la main par l'utilisateur).
    func analyze(parsed: ParsedOffer, origin: CLLocationCoordinate2D?,
                 pickup knownPickup: Place? = nil, dropoff knownDropoff: Place? = nil) async -> OfferAnalysis {
        var result = OfferAnalysis(parsed: parsed)
        let near = origin ?? Self.lyonCenter

        async let pickupPlace = Self.resolve(knownPickup, text: parsed.pickupText, near: near)
        async let dropoffPlace = Self.resolve(knownDropoff, text: parsed.dropoffText, near: near)
        let (pickup, dropoff) = await (pickupPlace, dropoffPlace)
        result.pickup = pickup
        result.dropoff = dropoff

        if let pickup, let dropoff {
            async let approach = approachLeg(from: origin, to: pickup.coordinate)
            async let delivery = leg(from: pickup.coordinate, to: dropoff.coordinate)
            let (a, d) = await (approach, delivery)
            if let d {
                result.legs = [a, d].compactMap { $0 }
            } else {
                result.notes.append("Calcul de trajet impossible (serveur injoignable) : estimation de l'offre utilisée")
            }
        } else if parsed.pickupText != nil || parsed.dropoffText != nil {
            result.notes.append("Restaurant ou client non localisé : estimation de l'offre utilisée")
        }

        if let price = parsed.priceEur {
            result.evaluation = ProfitabilityEvaluator.evaluate(
                priceEur: price, legs: result.legs, announcedKm: parsed.announcedDistanceKm,
                announcedMin: parsed.announcedDurationMin, settings: offerSettings, vehicle: vehicle)
        }
        return result
    }

    static let lyonCenter = CLLocationCoordinate2D(latitude: 45.7578, longitude: 4.8320)

    private static func resolve(_ known: Place?, text: String?, near: CLLocationCoordinate2D) async -> Place? {
        if let known { return known }
        return await geocode(text, near: near)
    }

    private func approachLeg(from origin: CLLocationCoordinate2D?, to: CLLocationCoordinate2D) async -> OfferLeg? {
        guard let origin else { return nil }
        return await leg(from: origin, to: to)
    }

    private func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> OfferLeg? {
        guard GeoMath.distance(from, to) > 30 else {
            return OfferLeg(distanceM: GeoMath.distance(from, to), durationS: 20, ascentM: 0, descentM: 0)
        }
        guard let plan = try? await api.planRoutes(
            from: from, to: to, weights: settings.weights, maxSpeedKmh: vehicle.cruiseSpeedKmh,
            profiles: [settings.defaultProfile], quick: true),
              let r = plan.routes.first else { return nil }
        return OfferLeg(distanceM: r.distanceM, durationS: r.durationS, ascentM: r.ascentM, descentM: r.descentM)
    }

    /// Recherche du lieu (nom de restaurant ou rue) autour de la position du livreur.
    static func geocode(_ text: String?, near: CLLocationCoordinate2D) async -> Place? {
        guard let text, text.count >= 3 else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text.contains("Lyon") || text.range(of: #"\b69\d{3}\b"#, options: .regularExpression) != nil
            ? text : "\(text), Lyon"
        request.region = MKCoordinateRegion(center: near, latitudinalMeters: 12_000, longitudinalMeters: 12_000)
        request.resultTypes = [.address, .pointOfInterest]
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        // Résultat aberrant (autre ville) : on l'écarte
        guard GeoMath.distance(coordinate, near) < 25_000 else { return nil }
        return Place(title: item.name ?? text, subtitle: text, coordinate: coordinate)
    }

    /// Dernière position connue (le raccourci tourne sans ouvrir l'app).
    static func lastKnownLocation() -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        if let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 600 { return loc.coordinate }
        let d = UserDefaults.standard
        guard let lat = d.object(forKey: "lastLat") as? Double, let lon = d.object(forKey: "lastLon") as? Double,
              let t = d.object(forKey: "lastLocTime") as? Double, Date().timeIntervalSince1970 - t < 1800 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
