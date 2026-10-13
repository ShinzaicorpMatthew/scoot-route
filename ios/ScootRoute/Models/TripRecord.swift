import Foundation
import SwiftData

/// Trajet réellement effectué (stocké uniquement sur l'iPhone).
@Model
final class TripRecord {
    var date: Date
    var fromTitle: String
    var toTitle: String
    var profileLabel: String
    var plannedDistanceM: Double
    var plannedDurationS: Double
    var traveledDistanceM: Double
    var actualDurationS: Double
    var ascentM: Double
    var descentM: Double
    var estimatedWh: Double
    var batteryStartPercent: Double?
    var batteryEndPercent: Double?
    var rerouteCount: Int

    init(date: Date = .now, fromTitle: String, toTitle: String, profileLabel: String,
         plannedDistanceM: Double, plannedDurationS: Double, traveledDistanceM: Double,
         actualDurationS: Double, ascentM: Double, descentM: Double, estimatedWh: Double,
         batteryStartPercent: Double?, batteryEndPercent: Double? = nil, rerouteCount: Int) {
        self.date = date
        self.fromTitle = fromTitle
        self.toTitle = toTitle
        self.profileLabel = profileLabel
        self.plannedDistanceM = plannedDistanceM
        self.plannedDurationS = plannedDurationS
        self.traveledDistanceM = traveledDistanceM
        self.actualDurationS = actualDurationS
        self.ascentM = ascentM
        self.descentM = descentM
        self.estimatedWh = estimatedWh
        self.batteryStartPercent = batteryStartPercent
        self.batteryEndPercent = batteryEndPercent
        self.rerouteCount = rerouteCount
    }
}
