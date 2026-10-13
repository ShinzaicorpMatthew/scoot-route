import Foundation
import CoreLocation

/// Importance de chaque critère (0 = ignoré, 1 = prioritaire). Envoyée au serveur, qui la
/// traduit en modèle de coût GraphHopper normalisé (voir server/api/src/profiles.js).
struct RouteWeights: Codable, Equatable {
    var time: Double = 0.5
    var distance: Double = 0.5
    var climb: Double = 0.6
    var slope: Double = 0.6
    var surface: Double = 0.5
    var safety: Double = 0.6

    static let balancedDefault = RouteWeights()
}

enum RidingMode: String, Codable, CaseIterable, Identifiable {
    case eco, normal, sport
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eco: return "Éco"
        case .normal: return "Normal"
        case .sport: return "Sport"
        }
    }
    /// Surconsommation relative (accélérations, vitesse de pointe)
    var consumptionFactor: Double {
        switch self {
        case .eco: return 0.9
        case .normal: return 1.0
        case .sport: return 1.15
        }
    }
}

/// Profil de la trottinette et du livreur (stocké localement uniquement).
struct VehicleProfile: Codable, Equatable {
    var modelName: String = ""
    /// Capacité batterie (Wh). nil = inconnue → valeur par défaut, estimation moins fiable.
    var batteryWh: Double? = nil
    var batteryPercent: Double = 100
    var cruiseSpeedKmh: Double = 20
    var ridingMode: RidingMode = .normal
    var hasRegenerativeBraking: Bool = false
    var riderMassKg: Double = 75
    var scooterMassKg: Double = 16
    var cargoMassKg: Double = 5
    /// Facteur appris à partir des trajets réels (consommation réelle / estimée).
    var calibrationFactor: Double = 1.0
    var calibrationSamples: Int = 0

    static let defaultBatteryWh = 450.0

    var totalMassKg: Double { riderMassKg + scooterMassKg + cargoMassKg }
    var effectiveBatteryWh: Double { batteryWh ?? Self.defaultBatteryWh }
}

enum DistanceUnit: String, Codable, CaseIterable, Identifiable {
    case kilometers, miles
    var id: String { rawValue }
    var label: String { self == .kilometers ? "Kilomètres" : "Miles" }
}

struct AppSettings: Codable, Equatable {
    var defaultProfile: String = "balanced"
    var weights: RouteWeights = .balancedDefault
    var voiceGuidance: Bool = true
    var keepHistory: Bool = true
    var unit: DistanceUnit = .kilometers
}

/// Lieu choisi par l'utilisateur (adresse, point sur la carte ou position GPS).
struct Place: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String = ""
    var latitude: Double
    var longitude: Double
    /// L'utilisateur a confirmé/ajusté la position exacte de l'entrée ou du point d'accès.
    var accessPointConfirmed: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(title: String, subtitle: String = "", coordinate: CLLocationCoordinate2D, accessPointConfirmed: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.accessPointConfirmed = accessPointConfirmed
    }
}

/// Persistance simple en JSON dans UserDefaults.
enum LocalStore {
    static func load<T: Decodable>(_ type: T.Type, key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Identifiant anonyme de l'appareil pour les signalements (aucune donnée personnelle).
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }
}
