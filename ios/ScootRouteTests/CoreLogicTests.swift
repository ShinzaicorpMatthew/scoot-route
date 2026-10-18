import XCTest
import CoreLocation
@testable import ScootRoute

/// Itinéraire SYNTHÉTIQUE, utilisé uniquement pour tester la logique de navigation.
private func makeRoute(points: Int = 21, stepDeg: Double = 0.0005, elevations: [Double]? = nil,
                       segments: [RouteSegment] = []) throws -> PlannedRoute {
    let geometry = (0..<points).map { [4.832 + Double($0) * stepDeg, 45.7578] }
    let total = GeoMath.cumulativeDistances(geometry.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }).last!
    let profile = (elevations ?? Array(repeating: 170, count: points)).enumerated()
        .map { [total * Double($0.offset) / Double(points - 1), $0.element] }
    let json: [String: Any] = [
        "id": "eco", "profile": "eco", "label": "Éco",
        "distance_m": total, "duration_s": 300, "ascent_m": 0, "descent_m": 0,
        "max_slope_up_pct": 0, "max_slope_down_pct": 0, "cost": 1,
        "shares": ["cycle_infra_pct": 0, "unpaved_pct": 0, "cobbles_pct": 0, "unknown_surface_pct": 0,
                   "access_uncertain_m": 0, "works_m": 0],
        "road_types": [], "works": [], "warnings": [],
        "reliability": ["level": "high", "score": 90, "reasons": [], "elevation_source": "IGN RGE ALTI"],
        "geometry": geometry, "elevation_profile": profile,
        "instructions": [
            ["text": "Continuez", "street": "", "sign": 0, "distance_m": total / 2, "duration_s": 150,
             "point_index": 0, "end_index": 10, "exit_number": NSNull()],
            ["text": "Tournez à droite", "street": "Rue B", "sign": 2, "distance_m": total / 2, "duration_s": 150,
             "point_index": 10, "end_index": points - 1, "exit_number": NSNull()],
            ["text": "Arrivée", "street": "", "sign": 4, "distance_m": 0, "duration_s": 0,
             "point_index": points - 1, "end_index": points - 1, "exit_number": NSNull()],
        ],
        "segments": [],
        "badges": ["recommended"],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PlannedRoute.self, from: data)
}

final class RouteDecodingTests: XCTestCase {
    func testDecodesServerPayload() throws {
        let route = try makeRoute()
        XCTAssertEqual(route.coordinates.count, 21)
        XCTAssertEqual(route.instructions[1].sign, 2)
        XCTAssertTrue(route.isRecommended)
        XCTAssertEqual(route.reroutingProfile, "eco")
    }
}

final class RouteProgressTrackerTests: XCTestCase {
    func testProgressAndNextManeuver() throws {
        let route = try makeRoute()
        var tracker = RouteProgressTracker(route: route)
        let p = route.coordinates[4]
        let state = tracker.update(location: p, horizontalAccuracy: 5)
        XCTAssertEqual(state.nextInstructionIndex, 1)
        XCTAssertEqual(state.distanceToNextManeuver, tracker.cumulative[10] - tracker.cumulative[4], accuracy: 2)
        XCTAssertFalse(state.isOffRoute)
        XCTAssertFalse(state.hasArrived)
    }

    func testOffRouteNeedsSeveralConfirmations() throws {
        let route = try makeRoute()
        var tracker = RouteProgressTracker(route: route)
        let far = CLLocationCoordinate2D(latitude: 45.7590, longitude: 4.836) // ~130 m au nord
        XCTAssertFalse(tracker.update(location: far, horizontalAccuracy: 8).isOffRoute)
        XCTAssertFalse(tracker.update(location: far, horizontalAccuracy: 8).isOffRoute)
        XCTAssertTrue(tracker.update(location: far, horizontalAccuracy: 8).isOffRoute)
    }

    func testImpreciseFixesDoNotTriggerReroute() throws {
        let route = try makeRoute()
        var tracker = RouteProgressTracker(route: route)
        let far = CLLocationCoordinate2D(latitude: 45.7590, longitude: 4.836)
        for _ in 0..<5 { XCTAssertFalse(tracker.update(location: far, horizontalAccuracy: 120).isOffRoute) }
    }

    func testArrival() throws {
        let route = try makeRoute()
        var tracker = RouteProgressTracker(route: route)
        XCTAssertTrue(tracker.update(location: route.coordinates.last!, horizontalAccuracy: 5).hasArrived)
    }

    func testSnappedPositionAndBearing() throws {
        let route = try makeRoute()
        var tracker = RouteProgressTracker(route: route)
        // 8 m au nord du tracé (orienté vers l'est) : la position est « aimantée » dessus
        let near = CLLocationCoordinate2D(latitude: 45.7578 + 0.00007, longitude: 4.8343)
        let state = tracker.update(location: near, horizontalAccuracy: 5)
        XCTAssertEqual(state.snappedLatitude ?? 0, 45.7578, accuracy: 0.00001)
        XCTAssertEqual(state.routeBearing, 90, accuracy: 1)
        let moved = GeoMath.offset(near, meters: 100, bearing: 0)
        XCTAssertEqual(GeoMath.distance(near, moved), 100, accuracy: 1)
    }

    func testRemainingAscentIgnoresDescents() {
        let profile = [170, 180, 170, 185, 185].enumerated().map { ElevationSample(distance: Double($0.offset) * 100, altitude: Double($0.element)) }
        XCTAssertEqual(RouteProgressTracker.remainingAscent(profile: profile, from: 0), 25, accuracy: 0.01)
        XCTAssertEqual(RouteProgressTracker.remainingAscent(profile: profile, from: 150), 15, accuracy: 0.01)
    }
}

final class BatteryEstimatorTests: XCTestCase {
    func testFlatConsumptionIsRealistic() {
        let v = VehicleProfile(batteryWh: 474, batteryPercent: 100, cruiseSpeedKmh: 20)
        let est = BatteryEstimator.estimate(distanceM: 1000, durationS: 180, ascentM: 0, descentM: 0, vehicle: v)
        // Les trottinettes urbaines consomment typiquement 8 à 20 Wh/km
        XCTAssertGreaterThan(est.energyWh, 7)
        XCTAssertLessThan(est.energyWh, 20)
    }

    func testClimbCostsEnergyAndDescentDoesNotCompensate() {
        let v = VehicleProfile(batteryWh: 474, hasRegenerativeBraking: false)
        let flat = BatteryEstimator.estimate(distanceM: 3000, durationS: 600, ascentM: 0, descentM: 0, vehicle: v)
        let hill = BatteryEstimator.estimate(distanceM: 3000, durationS: 600, ascentM: 60, descentM: 60, vehicle: v)
        // 60 m × ~96 kg ≈ 15,7 Wh mécaniques, ~21 Wh à la batterie
        XCTAssertGreaterThan(hill.energyWh - flat.energyWh, 15)
    }

    func testRegenIsModest() {
        var v = VehicleProfile(batteryWh: 474)
        let without = BatteryEstimator.estimate(distanceM: 3000, durationS: 600, ascentM: 60, descentM: 60, vehicle: v)
        v.hasRegenerativeBraking = true
        let with = BatteryEstimator.estimate(distanceM: 3000, durationS: 600, ascentM: 60, descentM: 60, vehicle: v)
        XCTAssertLessThan(with.energyWh, without.energyWh)
        XCTAssertGreaterThan(with.energyWh, without.energyWh * 0.85)
    }

    func testRiskLevels() {
        let v = VehicleProfile(batteryWh: 300, batteryPercent: 8)
        let est = BatteryEstimator.estimate(distanceM: 5000, durationS: 900, ascentM: 40, descentM: 0, vehicle: v)
        XCTAssertEqual(est.risk, .insufficient)
    }

    func testCalibrationMovesTowardObservation() {
        let v = VehicleProfile(batteryWh: 500)
        // estimation 50 Wh, réel 14 % de 500 Wh = 70 Wh → ratio observé 1,4 ; moyenne 50/50 → 1,2
        let updated = BatteryEstimator.calibrate(vehicle: v, estimatedWh: 50, startPercent: 80, endPercent: 66)
        XCTAssertEqual(updated.calibrationSamples, 1)
        XCTAssertEqual(updated.calibrationFactor, 1.2, accuracy: 0.001)
    }

    func testNoCalibrationWithoutKnownCapacity() {
        let v = VehicleProfile(batteryWh: nil)
        XCTAssertEqual(BatteryEstimator.calibrate(vehicle: v, estimatedWh: 50, startPercent: 80, endPercent: 60), v)
    }
}

final class AddressTextParserTests: XCTestCase {
    func testAppleMapsLink() {
        let r = AddressTextParser.parse("https://maps.apple.com/?daddr=45.7640,4.8357&q=Client")
        XCTAssertEqual(r, .coordinate(CLLocationCoordinate2D(latitude: 45.7640, longitude: 4.8357), label: "Client"))
    }

    func testGoogleMapsAtLink() {
        let r = AddressTextParser.parse("https://www.google.com/maps/place/Lyon/@45.7578,4.8320,17z")
        XCTAssertEqual(r, .coordinate(CLLocationCoordinate2D(latitude: 45.7578, longitude: 4.8320), label: nil))
    }

    func testGeoURI() {
        XCTAssertEqual(AddressTextParser.parse("geo:45.75,4.85"),
                       .coordinate(CLLocationCoordinate2D(latitude: 45.75, longitude: 4.85), label: nil))
    }

    func testPlainCoordinates() {
        XCTAssertEqual(AddressTextParser.parse("45.7698, 4.8302"),
                       .coordinate(CLLocationCoordinate2D(latitude: 45.7698, longitude: 4.8302), label: nil))
    }

    func testCopiedDeliveryTextIsCleaned() {
        let text = """
        Livrer à : Jean
        12 rue de la République
        69002 Lyon
        06 12 34 56 78
        Code 4521B
        """
        XCTAssertEqual(AddressTextParser.parse(text), .address("12 rue de la République, 69002 Lyon"))
    }

    func testEmptyText() {
        XCTAssertNil(AddressTextParser.parse("   "))
    }
}

final class FormatterTests: XCTestCase {
    func testDistances() {
        Fmt.unit = .kilometers
        XCTAssertEqual(Fmt.distance(42), "40 m")
        XCTAssertEqual(Fmt.distance(1534), "1,5 km")
        XCTAssertEqual(Fmt.spokenDistance(148), "dans 150 mètres")
    }

    func testDurations() {
        XCTAssertEqual(Fmt.duration(20), "< 1 min")
        XCTAssertEqual(Fmt.duration(600), "10 min")
        XCTAssertEqual(Fmt.duration(3900), "1 h 05")
    }
}

final class OfferParserTests: XCTestCase {
    func testTypicalOfferScreen() {
        let lines = ["16:42", "Livraison", "6,85 €", "Total estimé (inclus les frais)", "22 min (4,1 km) au total",
                     "Burger King", "12 Rue de la République, 69002 Lyon", "Livraison",
                     "Rue Duguesclin, 69006 Lyon", "Accepter"]
        let o = OfferParser.parse(lines: lines)
        XCTAssertEqual(o.priceEur, 6.85)
        XCTAssertEqual(o.announcedDistanceKm, 4.1)
        XCTAssertEqual(o.announcedDurationMin, 22)
        XCTAssertEqual(o.pickupText, "Burger King, 12 Rue de la République, 69002 Lyon")
        XCTAssertEqual(o.dropoffText, "Rue Duguesclin, 69006 Lyon")
    }

    func testBonusIsNotTakenAsPrice() {
        let o = OfferParser.parse(lines: ["€7.20", "+1,00 € inclus", "18 min", "3,2 km", "Pitaya Thaï Street Food", "Cours Lafayette"])
        XCTAssertEqual(o.priceEur, 7.2)
        XCTAssertEqual(o.pickupText, "Pitaya Thaï Street Food")
        XCTAssertEqual(o.dropoffText, "Cours Lafayette")
    }

    func testNoPrice() {
        XCTAssertFalse(OfferParser.parse(lines: ["Bonjour", "Aucune offre"]).isUsable)
    }
}

final class ProfitabilityTests: XCTestCase {
    private let vehicle = VehicleProfile(batteryWh: 474, batteryPercent: 80, cruiseSpeedKmh: 20)

    func testGoodOffer() {
        // 8 € pour ~19 min (11 min de route + 8 min d'arrêts) et 3,5 km
        let legs = [OfferLeg(distanceM: 1000, durationS: 180, ascentM: 0, descentM: 0),
                    OfferLeg(distanceM: 2500, durationS: 480, ascentM: 5, descentM: 5)]
        let e = ProfitabilityEvaluator.evaluate(priceEur: 8, legs: legs, announcedKm: nil, announcedMin: nil,
                                                settings: OfferSettings(), vehicle: vehicle)!
        XCTAssertEqual(e.verdict, .good)
        XCTAssertEqual(e.totalMinutes, 19, accuracy: 0.01)
        XCTAssertEqual(e.eurPerKm, 8 / 3.5, accuracy: 0.01)
        XCTAssertEqual(e.source, .scooterRoute)
    }

    func testBadOffer() {
        let legs = [OfferLeg(distanceM: 6000, durationS: 1300, ascentM: 90, descentM: 10)]
        let e = ProfitabilityEvaluator.evaluate(priceEur: 4, legs: legs, announcedKm: nil, announcedMin: nil,
                                                settings: OfferSettings(), vehicle: vehicle)!
        XCTAssertEqual(e.verdict, .bad)
        XCTAssertTrue(e.reasons.contains { $0.contains("Montées") })
    }

    func testFallbackOnAnnouncedValues() {
        let e = ProfitabilityEvaluator.evaluate(priceEur: 6, legs: nil, announcedKm: 4, announcedMin: 20,
                                                settings: OfferSettings(), vehicle: vehicle)!
        XCTAssertEqual(e.source, .announced)
        XCTAssertEqual(e.totalMinutes, 23, accuracy: 0.01) // 20 min + 3 min de remise
        XCTAssertNil(ProfitabilityEvaluator.evaluate(priceEur: 6, legs: nil, announcedKm: nil, announcedMin: nil,
                                                     settings: OfferSettings(), vehicle: vehicle))
    }

    func testEmptyBatteryMakesOfferBad() {
        let low = VehicleProfile(batteryWh: 300, batteryPercent: 4)
        let legs = [OfferLeg(distanceM: 3000, durationS: 600, ascentM: 0, descentM: 0)]
        let e = ProfitabilityEvaluator.evaluate(priceEur: 15, legs: legs, announcedKm: nil, announcedMin: nil,
                                                settings: OfferSettings(), vehicle: low)!
        XCTAssertEqual(e.verdict, .bad)
    }
}

final class BatteryScreenParserTests: XCTestCase {
    func testPercentShown() {
        let r = BatteryScreenParser.parse(lines: ["DUALTRON", "Batterie", "78 %", "54.3 V", "0 km/h"], nominalVoltage: 52)
        XCTAssertEqual(r?.effectivePercent, 78)
        XCTAssertEqual(r?.voltage, 54.3)
        XCTAssertEqual(r?.estimatedFromVoltage, false)
    }

    func testPercentFromVoltage() {
        // 14 éléments (52 V) à 3,8 V par élément ≈ 50 %
        let r = BatteryScreenParser.parse(lines: ["Voltage", "53,2V"], nominalVoltage: 52)
        XCTAssertEqual(r?.effectivePercent, 50)
        XCTAssertEqual(r?.estimatedFromVoltage, true)
        XCTAssertEqual(BatteryScreenParser.percent(fromVoltage: 67.2, nominal: 60), 100)
        XCTAssertEqual(BatteryScreenParser.cellCount(nominal: 60), 16)
    }

    func testOfferScreenIsNotABatteryScreen() {
        XCTAssertNil(BatteryScreenParser.parse(lines: ["6,85 €", "22 min", "Burger King"], nominalVoltage: nil))
    }
}

final class ServerLinkTests: XCTestCase {
    /// Valeurs calculées par le serveur Node (test de compatibilité entre les deux côtés).
    func testMatchesServerImplementation() {
        XCTAssertEqual(ServerLink.normalize("abcd-efgh jklm"), "ABCDEFGHJKLM")
        XCTAssertEqual(ServerLink.topic(for: "ABCD-EFGH-JKLM"), "scootroute-3f63d25fcb898ecfd6c2e232")
        XCTAssertEqual(ServerLink.signature(code: "ABCD-EFGH-JKLM", url: "https://new-url.trycloudflare.com", ts: 1760000000),
                       "ced60a549e2683acad5657912e43ab14a15d970f8347fb6641e97b26339c26c1")
    }
}
