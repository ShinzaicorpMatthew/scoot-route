import Foundation
import CoreLocation

// Modèles renvoyés par l'API Scoot Route (POST /v1/routes).
// Décodés avec keyDecodingStrategy = .convertFromSnakeCase.

struct RoutePlanResponse: Decodable {
    let routes: [PlannedRoute]
    let recommendedId: String
    let meta: PlanMeta?
}

struct PlanMeta: Decodable {
    let map: MapDataInfo?
    let works: WorksDataInfo?
    let generatedAt: String?
}

struct MapDataInfo: Decodable {
    let source: String?
    let dataDate: String?
    let importDate: String?
    let engine: String?
    let live: Bool?
}

struct WorksDataInfo: Decodable {
    let available: Bool?
    let live: Bool?
    let fetchedAt: String?
    let count: Int?
    let error: String?
}

struct PlannedRoute: Decodable, Identifiable, Hashable {
    let id: String
    let profile: String
    let label: String
    let distanceM: Double
    let durationS: Double
    let ascentM: Double
    let descentM: Double
    let maxSlopeUpPct: Double
    let maxSlopeDownPct: Double
    let cost: Double
    let shares: RouteShares
    let roadTypes: [RoadTypeShare]
    let works: [WorksHit]
    let warnings: [RouteWarning]
    let reliability: Reliability
    let geometry: [[Double]]          // [lon, lat]
    let elevationProfile: [[Double]]  // [distance m, altitude m]
    let instructions: [RouteInstruction]
    let segments: [RouteSegment]
    let alsoMatches: [String]?
    let badges: [String]?

    static func == (lhs: PlannedRoute, rhs: PlannedRoute) -> Bool { lhs.id == rhs.id && lhs.distanceM == rhs.distanceM }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(distanceM) }

    var coordinates: [CLLocationCoordinate2D] {
        geometry.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
    }

    var isRecommended: Bool { badges?.contains("recommended") ?? false }

    /// Profil de routage à réutiliser lors d'un recalcul.
    var reroutingProfile: String { ["fast", "eco", "balanced"].contains(profile) ? profile : "balanced" }

    var elevationSamples: [ElevationSample] {
        elevationProfile.compactMap { $0.count >= 2 ? ElevationSample(distance: $0[0], altitude: $0[1]) : nil }
    }
}

struct ElevationSample: Identifiable, Hashable {
    var id: Double { distance }
    let distance: Double
    let altitude: Double
}

struct RouteShares: Decodable, Hashable {
    let cycleInfraPct: Double
    let unpavedPct: Double
    let cobblesPct: Double
    let unknownSurfacePct: Double
    let accessUncertainM: Double
    let worksM: Double
}

struct RoadTypeShare: Decodable, Hashable {
    let roadClass: String
    let label: String
    let pct: Double
}

struct WorksHit: Decodable, Hashable {
    let id: String
    let label: String
    let fromM: Double
    let toM: Double
}

struct RouteWarning: Decodable, Hashable {
    enum Level: String, Decodable { case restriction, difficulty, info }
    let level: Level
    let text: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? c.decode(Level.self, forKey: .level)) ?? .info
        text = try c.decode(String.self, forKey: .text)
    }
    private enum CodingKeys: String, CodingKey { case level, text }
}

struct Reliability: Decodable, Hashable {
    let level: String   // high / medium / low
    let score: Int
    let reasons: [String]
    let elevationSource: String

    var labelFR: String {
        switch level {
        case "high": return "Fiabilité élevée"
        case "medium": return "Fiabilité moyenne"
        default: return "Fiabilité faible"
        }
    }
}

struct RouteInstruction: Decodable, Hashable {
    let text: String
    let street: String
    let sign: Int
    let distanceM: Double
    let durationS: Double
    let pointIndex: Int
    let endIndex: Int
    let exitNumber: Int?

    var isArrival: Bool { sign == 4 }
}

struct RouteSegment: Decodable, Hashable {
    let fromIndex: Int
    let toIndex: Int
    let startM: Double
    let lengthM: Double
    let street: String
    let roadClass: String
    let roadType: String
    let surface: String
    let cycleInfra: Bool
    let unpaved: Bool
    let cobbles: Bool
    let rough: Bool
    let accessUncertain: Bool
    let accessReason: String?
    let worksId: String?
    let ascentM: Double
    let avgSlopePct: Double

    enum Kind { case cycle, normal, difficulty, restriction }

    /// Catégorie d'affichage : vert (piste), orange (difficulté), rouge (restriction).
    var kind: Kind {
        if accessUncertain || worksId != nil { return .restriction }
        if unpaved || cobbles || rough || avgSlopePct >= 7 { return .difficulty }
        if cycleInfra { return .cycle }
        return .normal
    }
}

// MARK: - Requêtes

struct RouteRequest: Encodable {
    struct Point: Encodable { let lat: Double; let lon: Double }
    let from: Point
    let to: Point
    let weights: RouteWeights?
    let maxSpeedKmh: Double?
    let profiles: [String]?
    let heading: Double?
    /// Calcul rapide : un seul itinéraire, sans alternatives (analyse d'offre)
    var quick: Bool? = nil
}

struct ReportRequest: Encodable {
    let type: String
    let lat: Double
    let lon: Double
    let comment: String
    let deviceId: String
}

struct ReportCreated: Decodable { let id: Int; let status: String }

struct ReportRecord: Decodable, Identifiable {
    let id: Int
    let type: String
    let lat: Double
    let lon: Double
    let comment: String?
    let status: String
    let createdAt: String
}

struct ReportsList: Decodable { let reports: [ReportRecord] }

struct ServerMeta: Decodable {
    let map: MapDataInfo?
    let works: WorksDataInfo?
    let elevationSource: String?
}

struct APIErrorBody: Decodable { let error: String?; let message: String? }
