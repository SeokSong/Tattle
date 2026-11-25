import SwiftUI

/// colours of the globe. the owner chose Night from three rendered previews (2026-11-25): it looks the same in light
/// and dark mode and the lines stand out most
public struct GlobeStyle: Sendable {
    public var space: Color
    public var ocean: Color
    public var land: Color
    public var coast: Color
    public var border: Color
    public var line: Color
    public var office: Color
    public var start: Color

    public static let night = GlobeStyle(
        space: Color(red: 0.05, green: 0.06, blue: 0.09), ocean: Color(red: 0.08, green: 0.12, blue: 0.20),
        land: Color(red: 0.19, green: 0.23, blue: 0.29), coast: Color(red: 0.36, green: 0.42, blue: 0.50),
        border: Color(red: 0.30, green: 0.35, blue: 0.42), line: Color(red: 1.0, green: 0.62, blue: 0.20),
        office: Color(red: 1.0, green: 0.78, blue: 0.45), start: Color(red: 0.40, green: 0.80, blue: 1.0))
}

/// the globe with its lines. pure drawing: the camera (centre and zoom) and the lines come from outside, so the
/// Live screen, the Summary and the Map screen all draw the same way
public struct GlobeView: View {
    public var centre: GeoPoint
    /// the globe's radius as a share of the smaller side of the view: 0.45 shows the whole globe, larger zooms in
    public var zoom: Double
    public var lines: [MapLine]
    /// where every line starts; nil draws dots only (no location and, by design, no default either)
    public var start: GeoPoint?
    /// how much of each line is drawn, 0 to 1, by line id (for drawing lines in); missing means fully drawn
    public var progress: [String: Double]
    public var style: GlobeStyle
    public var outline: WorldOutline

    public init(centre: GeoPoint, zoom: Double, lines: [MapLine], start: GeoPoint?, progress: [String: Double] = [:],
                style: GlobeStyle = .night, outline: WorldOutline = .bundled) {
        self.centre = centre
        self.zoom = zoom
        self.lines = lines
        self.start = start
        self.progress = progress
        self.style = style
        self.outline = outline
    }

    public var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let globe = Orthographic(centre: centre, radius: side * zoom, originX: size.width / 2, originY: size.height / 2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.space))
            let disc = CGRect(x: globe.originX - globe.radius, y: globe.originY - globe.radius, width: 2 * globe.radius, height: 2 * globe.radius)
            ctx.fill(Path(ellipseIn: disc), with: .color(style.ocean))
            ctx.clip(to: Path(ellipseIn: disc))

            // land: each ring filled, with far-side points pushed onto the rim so a shape crossing the edge stays closed
            var land = Path(), coast = Path()
            for ring in outline.land {
                let points = ring.map(globe.projectOntoRim)
                guard ring.contains(where: { globe.project($0) != nil }) else { continue }
                land.addLines(points.map { CGPoint(x: $0.x, y: $0.y) })
                land.closeSubpath()
                for piece in globe.visiblePieces(ring) { coast.addLines(piece.map { CGPoint(x: $0.x, y: $0.y) }) }
            }
            ctx.fill(land, with: .color(style.land))
            ctx.stroke(coast, with: .color(style.coast), lineWidth: 0.6)
            var borders = Path()
            for line in outline.borders {
                for piece in globe.visiblePieces(line) { borders.addLines(piece.map { CGPoint(x: $0.x, y: $0.y) }) }
            }
            ctx.stroke(borders, with: .color(style.border), lineWidth: 0.4)

            // lines from the start point, brighter and thicker with more connections; dots at the head offices
            for line in lines {
                let shown = max(0, min(1, progress[line.id] ?? 1))
                if let start, shown > 0 {
                    let path = Geo.greatCircle(from: start, to: line.to)
                    let cut = Int((Double(path.count - 1) * shown).rounded())
                    var p = Path()
                    for piece in globe.visiblePieces(Array(path[0...cut])) { p.addLines(piece.map { CGPoint(x: $0.x, y: $0.y) }) }
                    ctx.stroke(p, with: .color(style.line.opacity(line.opacity)), style: StrokeStyle(lineWidth: line.width, lineCap: .round))
                }
                if shown >= 1 || start == nil, let s = globe.project(line.to) {
                    let r = 2 + 2 * line.level
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(style.office.opacity(0.5 + 0.5 * line.level)))
                }
            }
            if let start, let s = globe.project(start) {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 4, y: s.y - 4, width: 8, height: 8)), with: .color(style.start))
                ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)), with: .color(style.start.opacity(0.5)), lineWidth: 1)
            }
        }
    }
}
