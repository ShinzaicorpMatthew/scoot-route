import Foundation
import MapKit
import Observation

/// Recherche et autocomplétion d'adresses via MapKit (gratuit, sans clé, traité par Apple).
@MainActor
@Observable
final class SearchService: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    /// Biais géographique : métropole de Lyon
    static let lyonRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.7578, longitude: 4.8320),
        span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.45))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.lyonRegion
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near location: CLLocation?) {
        if let location {
            completer.region = MKCoordinateRegion(center: location.coordinate,
                                                  latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        if query.trimmingCharacters(in: .whitespaces).count < 3 {
            suggestions = []
            completer.cancel()
        } else {
            isSearching = true
            completer.queryFragment = query
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = completer.region
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw SearchError.notFound }
        return Self.place(from: item, fallbackTitle: completion.title)
    }

    /// Géocode une adresse libre (texte collé ou partagé).
    func geocode(_ text: String) async throws -> Place {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = Self.lyonRegion
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw SearchError.notFound }
        return Self.place(from: item, fallbackTitle: text)
    }

    /// Adresse approximative d'un point choisi sur la carte.
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> Place {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let title = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return Place(title: title.isEmpty ? "Point sur la carte" : title,
                     subtitle: placemark?.locality ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                     coordinate: coordinate, accessPointConfirmed: true)
    }

    private static func place(from item: MKMapItem, fallbackTitle: String) -> Place {
        let pm = item.placemark
        let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let title = item.name ?? (street.isEmpty ? fallbackTitle : street)
        let subtitle = [street == title ? nil : street, pm.postalCode, pm.locality].compactMap { $0 }.joined(separator: " ")
        return Place(title: title, subtitle: subtitle, coordinate: pm.coordinate)
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.suggestions = Array(results.prefix(8))
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.isSearching = false }
    }
}

enum SearchError: LocalizedError {
    case notFound
    var errorDescription: String? { "Adresse introuvable. Précisez la rue et la commune, ou choisissez le point sur la carte." }
}
