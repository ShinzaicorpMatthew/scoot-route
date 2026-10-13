import Foundation

enum Fmt {
    static var unit: DistanceUnit = .kilometers

    static func distance(_ meters: Double) -> String {
        if unit == .miles {
            let miles = meters / 1609.344
            if miles < 0.1 { return "\(Int((meters * 3.28084 / 10).rounded()) * 10) ft" }
            return String(format: "%.1f mi", miles).replacingOccurrences(of: ".", with: ",")
        }
        if meters < 1000 {
            let rounded = meters < 100 ? (meters / 5).rounded() * 5 : (meters / 10).rounded() * 10
            return "\(Int(rounded)) m"
        }
        return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    static func meters(_ m: Double) -> String { "\(Int(m.rounded())) m" }

    static func percent(_ p: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f %%", p).replacingOccurrences(of: ".", with: ",")
    }

    static func eta(after seconds: Double, from now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f.string(from: now.addingTimeInterval(seconds))
    }

    static func isoDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: iso)
        }()
        guard let date else { return String(iso.prefix(10)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Phrase vocale pour une distance (« dans 150 mètres »)
    static func spokenDistance(_ meters: Double) -> String {
        if meters < 1000 {
            let r = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return "dans \(Int(max(10, r))) mètres"
        }
        let km = (meters / 100).rounded() / 10
        return "dans \(String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")) kilomètre\(km >= 2 ? "s" : "")"
    }
}

enum Maneuver {
    /// Symbole SF correspondant au code "sign" de GraphHopper.
    static func symbol(for sign: Int) -> String {
        switch sign {
        case -7: return "arrow.up.left"
        case -3: return "arrow.turn.left.down"
        case -2: return "arrow.turn.up.left"
        case -1: return "arrow.up.left"
        case 0: return "arrow.up"
        case 1: return "arrow.up.right"
        case 2: return "arrow.turn.up.right"
        case 3: return "arrow.turn.right.down"
        case 4: return "flag.checkered"
        case 5: return "mappin.circle"
        case 6: return "arrow.triangle.turn.up.right.circle"
        case 7: return "arrow.up.right"
        default: return "arrow.up"
        }
    }
}
