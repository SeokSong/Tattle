import Foundation

/// a place on the Earth in degrees. latitude -90 (south) to 90, longitude -180 (west) to 180
public struct GeoPoint: Sendable, Equatable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// the point as a unit vector (x towards 0° E on the equator, y towards 90° E, z towards the North Pole)
    var vector: (x: Double, y: Double, z: Double) {
        let la = latitude * .pi / 180, lo = longitude * .pi / 180
        return (cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
    }

    init(vector v: (x: Double, y: Double, z: Double)) {
        let r = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        latitude = asin(max(-1, min(1, v.z / r))) * 180 / .pi
        longitude = atan2(v.y, v.x) * 180 / .pi
    }
}

public enum Geo {
    /// mean Earth radius, km
    public static let earthRadiusKm = 6371.0

    /// the angle between two points seen from the Earth's centre, radians (0 to pi)
    public static func angle(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let (p, q) = (a.vector, b.vector)
        // atan2 of cross and dot stays accurate for very close and nearly opposite points, where acos does not
        let cx = p.y * q.z - p.z * q.y, cy = p.z * q.x - p.x * q.z, cz = p.x * q.y - p.y * q.x
        return atan2((cx * cx + cy * cy + cz * cz).squareRoot(), p.x * q.x + p.y * q.y + p.z * q.z)
    }

    /// distance along the Earth's surface, km
    public static func distanceKm(_ a: GeoPoint, _ b: GeoPoint) -> Double { angle(a, b) * earthRadiusKm }

    /// points along the shortest path over the globe (a great circle), both ends included. `steps` is the number of
    /// pieces; nearly opposite points have no single shortest path and fall back to the path over the North side
    public static func greatCircle(from a: GeoPoint, to b: GeoPoint, steps: Int = 48) -> [GeoPoint] {
        let n = max(1, steps)
        let d = angle(a, b)
        guard d > 1e-9 else { return [a, b] }
        let (p, q) = (a.vector, b.vector)
        let s = sin(d)
        guard s > 1e-6 else {
            // antipodes: go through the pole on the same side as the start's meridian
            let pole = GeoPoint(latitude: 90, longitude: a.longitude)
            return Array(greatCircle(from: a, to: pole, steps: n / 2).dropLast()) + greatCircle(from: pole, to: b, steps: n - n / 2)
        }
        return (0...n).map { i in
            if i == 0 { return a }
            if i == n { return b }
            let f = Double(i) / Double(n)
            let wa = sin((1 - f) * d) / s, wb = sin(f * d) / s
            return GeoPoint(vector: (wa * p.x + wb * q.x, wa * p.y + wb * q.y, wa * p.z + wb * q.z))
        }
    }
}
