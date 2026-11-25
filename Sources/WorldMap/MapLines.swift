import Foundation

/// one line on the map: from the start point to one head office. connections to companies based at the same place
/// share the line, and every repeat makes it brighter and thicker (owner, 2026-11-25), so a busy capture stays
/// readable instead of drawing the same line again and again
public struct MapLine: Sendable, Equatable, Identifiable {
    /// the head office's place, rounded to about 1 km: two companies in the same city block share a line
    public let id: String
    public let to: GeoPoint
    /// the city shown for the place
    public let city: String
    /// the country, as the head-office data names it; decides the North America view (owner's globe rule)
    public let country: String
    /// the companies based here that were contacted, sorted
    public private(set) var companies: [String]
    /// connections that went to a company here
    public private(set) var count: Int
    /// when the first connection to this place was seen, in the order of `add` calls (0, 1, 2 ...)
    public let order: Int

    mutating func add(company: String) {
        count += 1
        if !companies.contains(company) {
            companies.append(company)
            companies.sort()
        }
    }

    init(id: String, to: GeoPoint, city: String, country: String, company: String, order: Int) {
        self.id = id
        self.to = to
        self.city = city
        self.country = country
        self.companies = [company]
        self.count = 1
        self.order = order
    }

    /// 0 for a single connection, 1 at 32 connections or more; grows with the logarithm, so the first repeats show
    public var level: Double { min(1, log2(Double(count)) / 5) }
    /// how opaque the line is drawn: 0.35 to 1
    public var opacity: Double { 0.35 + 0.65 * level }
    /// how wide the line is drawn, in points: 1 to 3
    public var width: Double { 1 + 2 * level }
}

/// every line of one map, plus the connections that cannot be drawn (no company, or no known head office)
public struct MapLines: Sendable, Equatable {
    public private(set) var lines: [MapLine] = []
    /// connections with no company or whose company has no known head office: shown as a count under the map
    public private(set) var notDrawn = 0
    private var index: [String: Int] = [:]

    public init() {}

    /// the line id for a place: the same rounding `add` uses
    public static func key(_ p: GeoPoint) -> String {
        String(format: "%.2f,%.2f", p.latitude, p.longitude)
    }

    /// one connection to a company based at `place`; nil place means it cannot be drawn
    public mutating func add(company: String?, place: GeoPoint?, city: String = "", country: String = "") {
        guard let company, let place else {
            notDrawn += 1
            return
        }
        let key = Self.key(place)
        if let i = index[key] {
            lines[i].add(company: company)
        } else {
            index[key] = lines.count
            lines.append(MapLine(id: key, to: place, city: city, country: country, company: company, order: lines.count))
        }
    }

    /// lines ordered from the nearest head office to the farthest, for the Summary's replay (owner, 2026-11-25)
    public func nearestFirst(from start: GeoPoint) -> [MapLine] {
        lines.sorted {
            let (a, b) = (Geo.distanceKm(start, $0.to), Geo.distanceKm(start, $1.to))
            return a != b ? a < b : $0.id < $1.id
        }
    }
}
