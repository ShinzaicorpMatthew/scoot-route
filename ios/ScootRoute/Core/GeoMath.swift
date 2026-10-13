import Foundation
import CoreLocation

enum GeoMath {
    static let earthRadius = 6_371_008.8

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    static func cumulativeDistances(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        guard !coords.isEmpty else { return [] }
        var out = [0.0]
        out.reserveCapacity(coords.count)
        for i in 1..<coords.count { out.append(out[i - 1] + distance(coords[i - 1], coords[i])) }
        return out
    }

    struct Projection {
        /// Index du premier point du segment sur lequel on se projette
        let segmentIndex: Int
        /// Position 0…1 sur ce segment
        let fraction: Double
        /// Distance (m) entre la position et la ligne
        let distanceFromLine: Double
        /// Distance parcourue (m) depuis le début de la ligne jusqu'au projeté
        let distanceAlong: Double
    }

    /// Projette `p` sur les segments [range] de la polyligne (projection équirectangulaire locale).
    static func project(_ p: CLLocationCoordinate2D, on coords: [CLLocationCoordinate2D],
                        cumulative: [Double], range: Range<Int>? = nil) -> Projection? {
        guard coords.count >= 2 else { return nil }
        let lastSeg = coords.count - 2
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(lastSeg + 1, range?.upperBound ?? lastSeg + 1)
        guard lo < hi else { return nil }
        let r = lo..<hi
        let kx = 111_320 * cos(p.latitude * .pi / 180), ky = 110_540.0
        var best: Projection?
        for i in r {
            let ax = (coords[i].longitude - p.longitude) * kx, ay = (coords[i].latitude - p.latitude) * ky
            let bx = (coords[i + 1].longitude - p.longitude) * kx, by = (coords[i + 1].latitude - p.latitude) * ky
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0
            t = min(1, max(0, t))
            let d = hypot(ax + t * dx, ay + t * dy)
            if best == nil || d < best!.distanceFromLine {
                let segLen = cumulative[i + 1] - cumulative[i]
                best = Projection(segmentIndex: i, fraction: t, distanceFromLine: d,
                                  distanceAlong: cumulative[i] + t * segLen)
            }
        }
        return best
    }

    /// Point situé à `meters` mètres de `from` dans la direction `bearing` (degrés).
    static func offset(_ from: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let rad = bearing * .pi / 180
        let dLat = meters * cos(rad) / 111_320
        let dLon = meters * sin(rad) / (111_320 * cos(from.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: from.latitude + dLat, longitude: from.longitude + dLon)
    }

    /// Cap (degrés, 0 = nord) entre deux points.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}
