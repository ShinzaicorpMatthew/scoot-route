import Foundation

/// Niveau de batterie lu sur une capture d'écran de l'app de la trottinette (Dualtron / Minimotors…).
struct BatteryReading: Codable, Equatable {
    var percent: Double?
    var voltage: Double?
    /// Pourcentage retenu : celui affiché, sinon estimé à partir de la tension
    var effectivePercent: Double?
    var estimatedFromVoltage: Bool = false
}

enum BatteryScreenParser {
    /// - Parameter nominalVoltage: tension nominale de la batterie (ex. 52, 60, 72 V), pour estimer le % depuis la tension
    static func parse(lines: [String], nominalVoltage: Double?) -> BatteryReading? {
        let text = lines.filter { !$0.contains("€") && !$0.contains(":") }   // pas les prix ni l'heure
        let percents = values(in: text, pattern: #"(\d{1,3}(?:[.,]\d)?)\s*%"#).filter { $0 >= 0 && $0 <= 100 }
        let volts = values(in: text, pattern: #"(\d{2,3}(?:[.,]\d{1,2})?)\s*V\b"#).filter { $0 >= 20 && $0 <= 120 }
        guard !percents.isEmpty || !volts.isEmpty else { return nil }

        var reading = BatteryReading()
        // Le niveau de batterie est en général le pourcentage le plus visible ; on évite les 100 % d'interface
        reading.percent = percents.first { $0 < 100 } ?? percents.first
        reading.voltage = volts.max()
        if let p = reading.percent {
            reading.effectivePercent = p
        } else if let v = reading.voltage, let nominal = nominalVoltage ?? guessNominal(from: v) {
            reading.effectivePercent = percent(fromVoltage: v, nominal: nominal)
            reading.estimatedFromVoltage = true
        }
        return reading
    }

    /// Estimation à vide pour une batterie lithium-ion (approximative : la tension baisse sous charge).
    static func percent(fromVoltage v: Double, nominal: Double) -> Double {
        let cells = Double(cellCount(nominal: nominal))
        let perCell = v / cells
        let curve: [(Double, Double)] = [(3.30, 0), (3.50, 8), (3.60, 18), (3.70, 33), (3.80, 50),
                                         (3.90, 65), (4.00, 78), (4.10, 90), (4.20, 100)]
        if perCell <= curve[0].0 { return 0 }
        if perCell >= curve[curve.count - 1].0 { return 100 }
        for i in 1..<curve.count where perCell <= curve[i].0 {
            let (v0, p0) = curve[i - 1], (v1, p1) = curve[i]
            return (p0 + (p1 - p0) * (perCell - v0) / (v1 - v0)).rounded()
        }
        return 100
    }

    /// Nombre d'éléments en série selon la tension nominale annoncée (conventions du marché).
    static func cellCount(nominal: Double) -> Int {
        let table: [(Double, Int)] = [(36, 10), (48, 13), (52, 14), (60, 16), (72, 20), (84, 22)]
        if let match = table.first(where: { abs($0.0 - nominal) < 1 }) { return match.1 }
        return max(1, Int((nominal / 3.7).rounded()))
    }

    /// Tensions nominales courantes des trottinettes (36 à 84 V) : celle qui correspond à la mesure.
    static func guessNominal(from v: Double) -> Double? {
        let candidates: [Double] = [36, 48, 52, 60, 72, 84]
        return candidates.first { nominal in
            let cells = Double(cellCount(nominal: nominal))
            return v >= cells * 3.2 && v <= cells * 4.25
        }
    }

    private static func values(in lines: [String], pattern: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [Double] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for m in regex.matches(in: line, range: range) {
                if let r = Range(m.range(at: 1), in: line),
                   let v = Double(line[r].replacingOccurrences(of: ",", with: ".")) { out.append(v) }
            }
        }
        return out
    }
}
