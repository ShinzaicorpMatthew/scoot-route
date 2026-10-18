import Foundation
import CryptoKit

/// Liaison automatique : retrouve la nouvelle adresse du serveur après un redémarrage du PC.
/// Le serveur publie son adresse, signée avec le code de liaison, sur un canal ntfy.sh ;
/// l'app lit ce canal et n'accepte l'adresse que si la signature correspond au code.
enum ServerLink {
    static let codeKey = "pairingCode"
    static let lastSyncKey = "pairingLastSync"
    static let ntfyBase = "https://ntfy.sh"

    static var code: String? {
        get {
            let c = UserDefaults.standard.string(forKey: codeKey) ?? ""
            return normalize(c).count >= 8 ? c : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: codeKey) }
    }

    static var lastSync: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }.filter { $0.isASCII }
    }

    static func topic(for code: String) -> String {
        let hash = SHA256.hash(data: Data(normalize(code).utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "scootroute-" + hex.prefix(24)
    }

    static func signature(code: String, url: String, ts: Int) -> String {
        let key = SymmetricKey(data: Data(normalize(code).utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(url)|\(ts)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private struct NtfyMessage: Decodable { let event: String; let message: String? }
    private struct Published: Decodable { let url: String; let ts: Int; let sig: String }

    enum LinkResult: Equatable { case updated(String), unchanged, notFound, noCode }

    /// Cherche la dernière adresse publiée et met à jour l'app si elle a changé.
    @discardableResult
    static func refresh(timeout: TimeInterval = 6) async -> LinkResult {
        guard let code else { return .noCode }
        guard let url = URL(string: "\(ntfyBase)/\(topic(for: code))/json?poll=1&since=latest") else { return .notFound }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let reply = try? await URLSession.shared.data(for: request) else { return .notFound }
        let (data, response) = reply
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return .notFound }

        // Réponse : un objet JSON par ligne ; on garde le dernier message valide et bien signé
        let decoder = JSONDecoder()
        let candidates = text.split(separator: "\n").compactMap { line -> Published? in
            guard let msg = try? decoder.decode(NtfyMessage.self, from: Data(line.utf8)),
                  msg.event == "message", let body = msg.message,
                  let pub = try? decoder.decode(Published.self, from: Data(body.utf8)) else { return nil }
            return pub
        }
        guard let pub = candidates.last(where: { isValid($0, code: code) }) else { return .notFound }
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        if AppConfig.apiBaseURL.absoluteString == pub.url { return .unchanged }
        AppConfig.setServerOverride(pub.url)
        return .updated(pub.url)
    }

    private static func isValid(_ pub: Published, code: String) -> Bool {
        guard pub.url.hasPrefix("https://"), pub.url.hasSuffix(".trycloudflare.com") else { return false }
        // Message de moins de 7 jours (le serveur republie toutes les 30 min)
        guard abs(Date().timeIntervalSince1970 - Double(pub.ts)) < 7 * 86_400 else { return false }
        return signature(code: code, url: pub.url, ts: pub.ts) == pub.sig.lowercased()
    }
}
