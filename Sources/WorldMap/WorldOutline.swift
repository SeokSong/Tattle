import Companies
import Foundation

/// why the outline failed to load: a line number only
public enum WorldOutlineError: Error, Equatable, Sendable {
    case fileMissing
    case badPoint(line: Int)
    case tooShort(line: Int)
}

/// the land and country borders drawn on the globe (Natural Earth 1:110m, public domain), from
/// Resources/land.txt and borders.txt: one ring or line per text line, "lon,lat lon,lat ..."
public struct WorldOutline: Sendable {
    public let land: [[GeoPoint]]
    public let borders: [[GeoPoint]]

    public init(land: String, borders: String) throws(WorldOutlineError) {
        self.land = try Self.parse(land)
        self.borders = try Self.parse(borders)
    }

    static func parse(_ text: String) throws(WorldOutlineError) -> [[GeoPoint]] {
        var out: [[GeoPoint]] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            var points: [GeoPoint] = []
            for pair in line.split(separator: " ") {
                let n = pair.split(separator: ",")
                guard n.count == 2, let lon = Double(n[0]), let lat = Double(n[1]), (-180...180).contains(lon), (-90...90).contains(lat) else {
                    throw .badPoint(line: i + 1)
                }
                points.append(GeoPoint(latitude: lat, longitude: lon))
            }
            guard points.count >= 2 else { throw .tooShort(line: i + 1) }
            out.append(points)
        }
        return out
    }

    static let bundleName = "Tattle_WorldMap.bundle"

    public static func loadBundled() throws -> WorldOutline {
        guard let land = DatasetManifest.resourceURL("land.txt", inBundleNamed: bundleName),
              let borders = DatasetManifest.resourceURL("borders.txt", inBundleNamed: bundleName) else { throw WorldOutlineError.fileMissing }
        return try WorldOutline(land: String(contentsOf: land, encoding: .utf8), borders: String(contentsOf: borders, encoding: .utf8))
    }

    /// loaded once; empty when the files cannot be read, so the map shows lines on a plain globe instead of failing
    public static let bundled: WorldOutline = (try? loadBundled()) ?? WorldOutline(empty: ())

    private init(empty: Void) {
        land = []
        borders = []
    }
}
