import Foundation

/// Estimation de consommation d'une trottinette électrique.
/// Modèle physique simple (roulement + aérodynamique + montée) corrigé par un facteur
/// appris sur les trajets réels. Les résultats sont des APPROXIMATIONS.
struct BatteryEstimate: Equatable {
    enum Risk: Equatable { case comfortable, tight, insufficient }

    let energyWh: Double
    let percentUsed: Double
    let arrivalPercent: Double
    let risk: Risk
    /// true si la capacité batterie n'est pas renseignée (valeur par défaut utilisée)
    let usesDefaultCapacity: Bool
    let isCalibrated: Bool
}

enum BatteryEstimator {
    // Constantes physiques et hypothèses (documentées dans docs/ARCHITECTURE.md)
    static let gravity = 9.81
    static let rollingResistance = 0.012   // petites roues pneumatiques sur enrobé
    static let airDensity = 1.2
    static let dragArea = 0.55             // CdA d'un usager debout (m²)
    static let drivetrainEfficiency = 0.75 // moteur + contrôleur + batterie
    static let stopAndGoFactor = 1.25      // relances aux feux et intersections urbaines
    static let regenRecovery = 0.10        // part de l'énergie potentielle récupérée en descente

    static func estimate(distanceM: Double, durationS: Double, ascentM: Double, descentM: Double,
                         vehicle: VehicleProfile) -> BatteryEstimate {
        let mass = vehicle.totalMassKg
        let routeSpeed = durationS > 0 ? distanceM / durationS : vehicle.cruiseSpeedKmh / 3.6
        let v = min(routeSpeed, vehicle.cruiseSpeedKmh / 3.6) // m/s

        let rolling = rollingResistance * mass * gravity * distanceM
        let aero = 0.5 * airDensity * dragArea * v * v * distanceM
        let flat = (rolling + aero) * stopAndGoFactor * vehicle.ridingMode.consumptionFactor
        let climb = mass * gravity * max(0, ascentM)
        // Une descente ne compense jamais une montée : seule une récupération modeste est
        // comptée, et uniquement si la trottinette dispose d'un freinage régénératif.
        let regen = vehicle.hasRegenerativeBraking ? regenRecovery * mass * gravity * max(0, descentM) : 0

        var joules = (flat + climb) / drivetrainEfficiency - regen
        joules = max(joules, flat / drivetrainEfficiency * 0.8)
        let wh = joules / 3600 * vehicle.calibrationFactor

        let capacity = vehicle.effectiveBatteryWh
        let used = capacity > 0 ? wh / capacity * 100 : 0
        let arrival = vehicle.batteryPercent - used
        let risk: BatteryEstimate.Risk = arrival < 5 ? .insufficient : arrival < 15 ? .tight : .comfortable
        return BatteryEstimate(energyWh: wh, percentUsed: used, arrivalPercent: arrival, risk: risk,
                               usesDefaultCapacity: vehicle.batteryWh == nil,
                               isCalibrated: vehicle.calibrationSamples > 0)
    }

    static func estimate(route: PlannedRoute, vehicle: VehicleProfile) -> BatteryEstimate {
        estimate(distanceM: route.distanceM, durationS: route.durationS,
                 ascentM: route.ascentM, descentM: route.descentM, vehicle: vehicle)
    }

    /// Met à jour le facteur de calibration à partir d'un trajet réel
    /// (pourcentages de batterie relevés au départ et à l'arrivée).
    static func calibrate(vehicle: VehicleProfile, estimatedWh: Double,
                          startPercent: Double, endPercent: Double) -> VehicleProfile {
        guard estimatedWh > 1, startPercent > endPercent, vehicle.batteryWh != nil else { return vehicle }
        let actualWh = (startPercent - endPercent) / 100 * vehicle.effectiveBatteryWh
        // estimatedWh inclut déjà l'ancien facteur : on raisonne sur le ratio brut
        let rawEstimate = estimatedWh / vehicle.calibrationFactor
        let observed = min(2.0, max(0.5, actualWh / rawEstimate))
        var v = vehicle
        // Moyenne mobile exponentielle (les relevés en % sont imprécis)
        let alpha = vehicle.calibrationSamples == 0 ? 0.5 : 0.25
        v.calibrationFactor = (1 - alpha) * vehicle.calibrationFactor + alpha * observed
        v.calibrationSamples += 1
        return v
    }
}
