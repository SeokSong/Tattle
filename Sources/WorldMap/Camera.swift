import Foundation

/// where the globe is looked at from: the point in the middle and how close
public struct GlobeCamera: Sendable, Equatable {
    public var centre: GeoPoint
    /// the globe's radius as a share of the view's smaller side: 0.42 shows the whole globe, larger is closer
    public var zoom: Double

    public init(centre: GeoPoint, zoom: Double) {
        self.centre = centre
        self.zoom = zoom
    }
}

/// the camera rules (owner, 2026-11-25): start on the user, zoom out to fit each line, stay on North America;
/// once a head office is outside North America, zoom far out and spin the globe slowly. pure, so it is tested
/// without drawing
public enum CameraDirector {
    /// the whole globe in view, a little smaller than the view so the glow and rising lines fit
    public static let worldZoom = 0.42
    /// the closest the camera goes: about 1,300 km across the middle of the view
    public static let closestZoom = 2.5
    /// at most this many degrees south of the middle the camera looks from, so lines that rise off the globe show their curve
    public static let tilt = 12.0
    /// how fast the globe turns in the world view, degrees of longitude per second (a full turn in two minutes)
    public static let spinPerSecond = 3.0

    /// countries that keep the North America view; the head-office data names them this way (Wikidata and the pins)
    static let northAmerica: Set<String> = ["United States", "Canada", "Mexico", "United States of America"]

    /// whether a line keeps the North America view. by country when the data has one, else by a box round the
    /// continent (Alaska to Panama, Pacific to Newfoundland)
    public static func inNorthAmerica(_ line: MapLine) -> Bool {
        if !line.country.isEmpty { return northAmerica.contains(line.country) }
        return (7...84).contains(line.to.latitude) && (-170 ... -50).contains(line.to.longitude)
    }

    /// true once any line goes outside North America: the camera then shows the whole globe and spins
    public static func isWorldView(_ lines: [MapLine]) -> Bool { lines.contains { !inNorthAmerica($0) } }

    /// where the camera should be. `seconds` is the time since the world view began, and turns the globe in it;
    /// `spin: false` holds the world view still (the Summary, once its replay ends)
    public static func target(start: GeoPoint, lines: [MapLine], seconds: Double = 0, spin: Bool = true) -> GlobeCamera {
        if isWorldView(lines) {
            // facing the side of the globe with the most head offices, then turning slowly from there
            let lon = bestLongitude(lines.map(\.to), keeping: start) + (spin ? seconds * spinPerSecond : 0)
            return GlobeCamera(centre: GeoPoint(latitude: 20, longitude: wrap(lon)), zoom: worldZoom)
        }
        // North America: the start and every line in view. the zoom is fitted round the middle of the points; the
        // 1.3 leaves room round them and for the rising arcs
        let points = [start] + lines.map(\.to)
        let middle = centroid(points)
        let far = points.map { Geo.angle(middle, $0) }.max() ?? 0
        let fitted = far < 1e-6 ? closestZoom : 0.5 / (sin(min(far, .pi / 2)) * 1.3)
        let zoom = max(worldZoom, min(closestZoom, fitted))
        // then looked at from a little south so the arcs show their curve: a quarter of the view's half-width, at
        // most `tilt` degrees, so close up the start never leaves the view
        let halfWidth = asin(min(1, 0.5 / zoom)) * 180 / .pi
        let centre = GeoPoint(latitude: max(-80, middle.latitude - min(tilt, halfWidth / 4)), longitude: middle.longitude)
        return GlobeCamera(centre: centre, zoom: zoom)
    }

    /// how long after the last connection the live world view keeps following before the slow spin takes over
    public static let quietSeconds = 8.0
    /// how far back connections count for following: the camera aims between the start and these head offices
    public static let followSeconds = 3.0

    /// the live world view while connections arrive (owner, 2026-11-25: a spinning globe turned away from new pings,
    /// "follow the connections smoothly"): the whole globe, turned so the start and the head offices pinged recently
    /// are in view. nil when nothing was pinged recently
    public static func follow(start: GeoPoint, recent: [GeoPoint]) -> GlobeCamera? {
        guard !recent.isEmpty else { return nil }
        let middle = centroid([start] + recent)
        return GlobeCamera(centre: GeoPoint(latitude: max(-10, min(45, middle.latitude)), longitude: middle.longitude), zoom: worldZoom)
    }

    /// the live world view when it is quiet: the slow spin, from wherever the camera is
    public static func drift(_ camera: GlobeCamera, seconds dt: Double) -> GlobeCamera {
        GlobeCamera(centre: GeoPoint(latitude: camera.centre.latitude, longitude: wrap(camera.centre.longitude + dt * spinPerSecond)),
                    zoom: worldZoom)
    }

    /// one animation step from `current` towards `target`: eases in so a change of view is a smooth glide, never a
    /// jump. longitude goes the short way round
    public static func step(from current: GlobeCamera, to target: GlobeCamera, seconds dt: Double, halfLife: Double = 0.6) -> GlobeCamera {
        let k = 1 - pow(0.5, max(0, dt) / halfLife)
        var dLon = target.centre.longitude - current.centre.longitude
        while dLon > 180 { dLon -= 360 }
        while dLon < -180 { dLon += 360 }
        let centre = GeoPoint(latitude: current.centre.latitude + (target.centre.latitude - current.centre.latitude) * k,
                              longitude: wrap(current.centre.longitude + dLon * k))
        // zoom eases on a log scale, so zooming out from close up does not rush
        let zoom = exp(log(current.zoom) + (log(target.zoom) - log(current.zoom)) * k)
        return GlobeCamera(centre: centre, zoom: zoom)
    }

    /// the longitude (seen from latitude 20) that shows the most of these places on the near side, among the views
    /// that keep `start` well inside (so the lines' common start never sits on the edge); ties go to the one nearest
    /// the places' middle, so the choice is steady
    static func bestLongitude(_ points: [GeoPoint], keeping start: GeoPoint) -> Double {
        let middle = centroid(points + [start]).longitude
        var best = (count: -1, gap: 0.0, lon: middle)
        for step in 0..<72 {
            let lon = wrap(middle + Double(step) * 5)
            let eye = GeoPoint(latitude: 20, longitude: lon)
            guard Geo.angle(eye, start) < 60 * .pi / 180 else { continue }
            let count = points.filter { Geo.angle(eye, $0) < 80 * .pi / 180 }.count
            let gap = abs(wrap(lon - middle))
            if count > best.count || (count == best.count && gap < best.gap) { best = (count, gap, lon) }
        }
        return best.lon
    }

    /// the middle of several places on the globe (the direction of their average)
    static func centroid(_ points: [GeoPoint]) -> GeoPoint {
        var x = 0.0, y = 0.0, z = 0.0
        for p in points {
            let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
            x += cos(la) * cos(lo)
            y += cos(la) * sin(lo)
            z += sin(la)
        }
        guard x * x + y * y + z * z > 1e-12 else { return points.first ?? GeoPoint(latitude: 0, longitude: 0) }
        return GeoPoint(latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
    }

    static func wrap(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 }
        if l < -180 { l += 360 }
        return l
    }
}

/// the Summary's replay (owner, 2026-11-25): every line drawn once, nearest head office first, then the map holds still
public struct Replay: Sendable {
    /// lines in the order they are drawn
    public let order: [MapLine]
    /// how long one line takes to draw, and the gap before the next one starts
    public static let drawSeconds = 0.8
    public static let gapSeconds = 0.35

    public init(lines: MapLines, start: GeoPoint) {
        order = lines.nearestFirst(from: start)
    }

    /// when the last line is fully drawn
    public var duration: Double {
        order.isEmpty ? 0 : Double(order.count - 1) * Self.gapSeconds + Self.drawSeconds
    }

    /// how much of each line is drawn at `seconds` after the replay began, by line id (0 not started, 1 done)
    public func progress(at seconds: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, line) in order.enumerated() {
            out[line.id] = max(0, min(1, (seconds - Double(i) * Self.gapSeconds) / Self.drawSeconds))
        }
        return out
    }

    /// the lines that have started by `seconds`: the camera fits these, so it widens as farther lines begin
    public func started(at seconds: Double) -> [MapLine] {
        order.enumerated().filter { Double($0.offset) * Self.gapSeconds <= seconds }.map(\.element)
    }
}
