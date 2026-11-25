import Foundation

/// the globe as seen from space: an orthographic projection. one projection for every view, so "start at the user,
/// zoom out, spin" is one smooth change of `centre` and `radius`, never a switch between maps (Milestone 4 plan)
public struct Orthographic: Sendable, Equatable {
    /// the point in the middle of the view
    public var centre: GeoPoint
    /// the globe's radius in points; a larger radius is a closer zoom
    public var radius: Double
    /// where the globe's centre sits in the view, in points
    public var originX: Double
    public var originY: Double

    public init(centre: GeoPoint, radius: Double, originX: Double, originY: Double) {
        self.centre = centre
        self.radius = radius
        self.originX = originX
        self.originY = originY
    }

    /// view coordinates (y grows downwards, as on screen), or nil when the point is on the far side of the globe
    public func project(_ p: GeoPoint) -> (x: Double, y: Double)? {
        let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
        let cla = centre.latitude * .pi / 180, clo = centre.longitude * .pi / 180
        let cosc = sin(cla) * sin(la) + cos(cla) * cos(la) * cos(lo - clo)
        guard cosc >= 0 else { return nil }
        let x = radius * cos(la) * sin(lo - clo)
        let y = radius * (cos(cla) * sin(la) - sin(cla) * cos(la) * cos(lo - clo))
        return (originX + x, originY - y)
    }

    /// a point raised `height` globe radii above the surface (0.2 is a fifth of the Earth's radius up). visible when it
    /// is on the near side or sticks out past the globe's edge; used for lines that arc up like flight paths
    public func project(_ p: GeoPoint, height: Double) -> (x: Double, y: Double)? {
        let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
        let cla = centre.latitude * .pi / 180, clo = centre.longitude * .pi / 180
        let k = 1 + max(0, height)
        let depth = k * (sin(cla) * sin(la) + cos(cla) * cos(la) * cos(lo - clo))
        let x = k * cos(la) * sin(lo - clo)
        let y = k * (cos(cla) * sin(la) - sin(cla) * cos(la) * cos(lo - clo))
        guard depth >= 0 || x * x + y * y > 1 else { return nil }
        return (originX + radius * x, originY - radius * y)
    }

    /// like `project`, but a point on the far side is pushed onto the globe's edge. used to fill land: a coastline
    /// that goes behind the globe then follows the rim, so the filled shape stays closed and on the visible side
    public func projectOntoRim(_ p: GeoPoint) -> (x: Double, y: Double) {
        if let s = project(p) { return s }
        let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
        let cla = centre.latitude * .pi / 180, clo = centre.longitude * .pi / 180
        let x = cos(la) * sin(lo - clo)
        let y = cos(cla) * sin(la) - sin(cla) * cos(la) * cos(lo - clo)
        let r = (x * x + y * y).squareRoot()
        guard r > 1e-12 else { return (originX + radius, originY) }
        return (originX + radius * x / r, originY - radius * y / r)
    }

    /// the place under a view point, or nil off the globe (for dragging on the Map screen)
    public func unproject(x: Double, y: Double) -> GeoPoint? {
        let px = (x - originX) / radius, py = (originY - y) / radius
        let rho = (px * px + py * py).squareRoot()
        guard rho <= 1 else { return nil }
        guard rho > 1e-12 else { return centre }
        let c = asin(rho)
        let cla = centre.latitude * .pi / 180, clo = centre.longitude * .pi / 180
        let la = asin(cos(c) * sin(cla) + py * sin(c) * cos(cla) / rho)
        let lo = clo + atan2(px * sin(c), rho * cos(cla) * cos(c) - py * sin(cla) * sin(c))
        var lon = lo * 180 / .pi
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return GeoPoint(latitude: la * 180 / .pi, longitude: lon)
    }

    /// a line as pieces that are on the visible side; a piece ends where the line goes behind the globe
    public func visiblePieces(_ line: [GeoPoint]) -> [[(x: Double, y: Double)]] {
        var pieces: [[(x: Double, y: Double)]] = []
        var current: [(x: Double, y: Double)] = []
        for p in line {
            if let s = project(p) { current.append(s) } else if !current.isEmpty { pieces.append(current); current = [] }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
