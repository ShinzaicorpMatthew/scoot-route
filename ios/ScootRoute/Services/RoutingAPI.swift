import Foundation
import CoreLocation

/// Configuration lue dans Info.plist (valeurs issues de Config/Config.xcconfig).
/// Aucune clé secrète n'est embarquée : le serveur détient les accès.
enum AppConfig {
    private static let overrideKey = "serverURLOverride"

    /// Adresse saisie dans Réglages (prioritaire), sinon celle fixée à la compilation.
    static var apiBaseURL: URL {
        if let saved = SharedStore.defaults.string(forKey: overrideKey), let url = URL(string: saved) {
            return url
        }
        let raw = Bundle.main.object(forInfoDictionaryKey: "ScootAPIBaseURL") as? String ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:8080")!
    }

    /// Enregistre l'adresse du serveur saisie par l'utilisateur (vide = valeur par défaut).
    static func setServerOverride(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if t.isEmpty {
            SharedStore.defaults.removeObject(forKey: overrideKey)
            return
        }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        if let url = URL(string: t), url.host != nil {
            SharedStore.defaults.set(t, forKey: overrideKey)
        }
    }
    static var clientToken: String {
        Bundle.main.object(forInfoDictionaryKey: "ScootClientToken") as? String ?? ""
    }
}

enum APIError: LocalizedError {
    case offline
    case server(code: String, message: String)
    case invalidResponse
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "Pas de connexion réseau. Le calcul d'itinéraire nécessite Internet."
        case let .server(code, message):
            switch code {
            case "out_of_coverage": return message
            case "no_route": return "Aucun itinéraire praticable en trottinette n'a été trouvé entre ces deux points."
            case "engine_unreachable", "engine_timeout": return "Le serveur de calcul est momentanément indisponible. Réessayez."
            case "rate_limited": return "Trop de demandes en peu de temps. Patientez quelques secondes."
            default: return message.isEmpty ? "Erreur serveur" : message
            }
        case .invalidResponse:
            return "Réponse du serveur illisible."
        case let .unreadable(detail):
            return "Réponse du serveur illisible (\(detail)). Envoyez ce message au support."
        }
    }
}

final class RoutingAPI {
    static let shared = RoutingAPI()

    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 25
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    func planRoutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, weights: RouteWeights,
                    maxSpeedKmh: Double, profiles: [String]? = nil, heading: Double? = nil,
                    quick: Bool? = nil) async throws -> RoutePlanResponse {
        let body = RouteRequest(
            from: .init(lat: from.latitude, lon: from.longitude),
            to: .init(lat: to.latitude, lon: to.longitude),
            weights: weights, maxSpeedKmh: maxSpeedKmh, profiles: profiles, heading: heading, quick: quick)
        return try await send(path: "v1/routes", method: "POST", body: body)
    }

    func sendReport(type: String, coordinate: CLLocationCoordinate2D, comment: String) async throws -> ReportCreated {
        let body = ReportRequest(type: type, lat: coordinate.latitude, lon: coordinate.longitude,
                                 comment: comment, deviceId: LocalStore.deviceId)
        return try await send(path: "v1/reports", method: "POST", body: body)
    }

    func myReports() async throws -> [ReportRecord] {
        let list: ReportsList = try await send(path: "v1/reports/mine?device_id=\(LocalStore.deviceId)", method: "GET", body: Optional<String>.none)
        return list.reports
    }

    func meta() async throws -> ServerMeta {
        try await send(path: "v1/meta", method: "GET", body: Optional<String>.none)
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { key in key.intValue.map { index in "[\(index)]" } ?? key.stringValue }.joined(separator: ".")
    }

    /// Envoie la requête ; si le serveur semble avoir changé d'adresse (PC redémarré, nouveau tunnel),
    /// on récupère la nouvelle adresse par la liaison automatique puis on réessaie une fois.
    private func send<B: Encodable, R: Decodable>(path: String, method: String, body: B?) async throws -> R {
        do {
            return try await sendOnce(path: path, method: method, body: body)
        } catch let error as APIError where Self.suggestsMovedServer(error) {
            if case .updated(_) = await ServerLink.refresh() {
                return try await sendOnce(path: path, method: method, body: body)
            }
            throw error
        }
    }

    private static func suggestsMovedServer(_ error: APIError) -> Bool {
        switch error {
        case let .server(code, _):
            return ["engine_unreachable", "http_404", "http_502", "http_503", "http_530"].contains(code)
        case let .unreadable(detail):
            return detail.hasPrefix("format non JSON")
        default:
            return false
        }
    }

    private func sendOnce<B: Encodable, R: Decodable>(path: String, method: String, body: B?) async throws -> R {
        guard let url = URL(string: path, relativeTo: AppConfig.apiBaseURL.appendingPathComponent("")) else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !AppConfig.clientToken.isEmpty { req.setValue(AppConfig.clientToken, forHTTPHeaderField: "X-Client-Token") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
            throw APIError.offline
        } catch let e as URLError {
            throw APIError.server(code: "engine_unreachable", message: e.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let err = try? decoder.decode(APIErrorBody.self, from: data)
            throw APIError.server(code: err?.error ?? "http_\(http.statusCode)", message: err?.message ?? "Erreur \(http.statusCode)")
        }
        do {
            return try decoder.decode(R.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw APIError.unreadable("champ manquant \(Self.path(ctx.codingPath + [key]))")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw APIError.unreadable("valeur vide \(Self.path(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw APIError.unreadable("type inattendu \(Self.path(ctx.codingPath))")
        } catch {
            let start = String(data: data.prefix(60), encoding: .utf8) ?? ""
            throw APIError.unreadable("format non JSON : \(start)")
        }
    }
}
