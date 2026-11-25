import SwiftUI

/// colours of the globe. the owner chose Night from three rendered previews (2026-11-25): it looks the same in light
/// and dark mode and the lines stand out most
public struct GlobeStyle: Sendable {
    public var space: Color
    public var ocean: Color
    /// the ocean where the light falls (upper left) and on the far edge
    public var oceanLit: Color
    public var oceanShade: Color
    public var land: Color
    public var coast: Color
    public var border: Color
    public var line: Color
    public var office: Color
    public var start: Color

    public static let night = GlobeStyle(
        space: Color(red: 0.05, green: 0.06, blue: 0.09), ocean: Color(red: 0.08, green: 0.12, blue: 0.20),
        oceanLit: Color(red: 0.14, green: 0.20, blue: 0.31), oceanShade: Color(red: 0.03, green: 0.05, blue: 0.09),
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

    /// how high a line rises at its middle, in globe radii: longer lines rise higher, like flight paths
    static func arcHeight(_ from: GeoPoint, _ to: GeoPoint) -> Double {
        min(0.18, 0.04 + 0.2 * Geo.angle(from, to) / .pi)
    }

    public var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let globe = Orthographic(centre: centre, radius: side * zoom, originX: size.width / 2, originY: size.height / 2)
            let r = globe.radius
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.space))
            let disc = CGRect(x: globe.originX - r, y: globe.originY - r, width: 2 * r, height: 2 * r)
            func points(_ piece: [(x: Double, y: Double)]) -> [CGPoint] { piece.map { CGPoint(x: $0.x, y: $0.y) } }

            // atmosphere: a soft glow just outside the globe's edge
            ctx.fill(Path(ellipseIn: disc.insetBy(dx: -r * 0.08, dy: -r * 0.08)), with: .radialGradient(
                Gradient(stops: [.init(color: style.start.opacity(0.22), location: 0.9), .init(color: style.start.opacity(0), location: 1)]),
                center: CGPoint(x: disc.midX, y: disc.midY), startRadius: 0, endRadius: r * 1.08))

            ctx.drawLayer { globeLayer in
                globeLayer.clip(to: Path(ellipseIn: disc))
                // ocean, lit from the upper left so the globe looks round
                globeLayer.fill(Path(ellipseIn: disc), with: .radialGradient(
                    Gradient(colors: [style.oceanLit, style.ocean, style.oceanShade]),
                    center: CGPoint(x: disc.midX - r * 0.35, y: disc.midY - r * 0.4), startRadius: 0, endRadius: r * 1.5))
                // a faint grid every 15 degrees
                var grid = Path()
                for lat in stride(from: -75.0, through: 75, by: 15) {
                    let ring = stride(from: -180.0, through: 180, by: 3).map { GeoPoint(latitude: lat, longitude: $0) }
                    for piece in globe.visiblePieces(ring) { grid.addLines(points(piece)) }
                }
                for lon in stride(from: -180.0, to: 180, by: 15) {
                    let meridian = stride(from: -90.0, through: 90, by: 3).map { GeoPoint(latitude: $0, longitude: lon) }
                    for piece in globe.visiblePieces(meridian) { grid.addLines(points(piece)) }
                }
                globeLayer.stroke(grid, with: .color(style.border.opacity(0.18)), lineWidth: 0.5)

                // land: each ring filled, with far-side points pushed onto the rim so a shape crossing the edge stays closed
                var land = Path(), coast = Path()
                for ring in outline.land {
                    guard ring.contains(where: { globe.project($0) != nil }) else { continue }
                    land.addLines(ring.map(globe.projectOntoRim).map { CGPoint(x: $0.x, y: $0.y) })
                    land.closeSubpath()
                    for piece in globe.visiblePieces(ring) { coast.addLines(points(piece)) }
                }
                globeLayer.fill(land, with: .color(style.land))
                globeLayer.stroke(coast, with: .color(style.coast.opacity(0.7)), lineWidth: 0.6)
                var borders = Path()
                for line in outline.borders {
                    for piece in globe.visiblePieces(line) { borders.addLines(points(piece)) }
                }
                globeLayer.stroke(borders, with: .color(style.border.opacity(0.45)), lineWidth: 0.35)
                // shade the land too: darker towards the far edge
                globeLayer.fill(Path(ellipseIn: disc), with: .radialGradient(
                    Gradient(colors: [.clear, .clear, .black.opacity(0.35)]),
                    center: CGPoint(x: disc.midX - r * 0.35, y: disc.midY - r * 0.4), startRadius: 0, endRadius: r * 1.6))
            }

            // lines: arcs that rise off the surface, with a soft glow under each; brighter and thicker with repeats
            var arcs: [(path: Path, line: MapLine)] = []
            if let start {
                for line in lines {
                    let shown = max(0, min(1, progress[line.id] ?? 1))
                    guard shown > 0 else { continue }
                    let ground = Geo.greatCircle(from: start, to: line.to, steps: 64)
                    let cut = Int((Double(ground.count - 1) * shown).rounded())
                    let peak = Self.arcHeight(start, line.to)
                    var path = Path(), pen = false
                    for (i, p) in ground[0...cut].enumerated() {
                        let f = Double(i) / Double(ground.count - 1)
                        if let s = globe.project(p, height: peak * sin(.pi * f)) {
                            pen ? path.addLine(to: CGPoint(x: s.x, y: s.y)) : path.move(to: CGPoint(x: s.x, y: s.y))
                            pen = true
                        } else { pen = false }
                    }
                    arcs.append((path, line))
                }
            }
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 4))
                for arc in arcs {
                    glow.stroke(arc.path, with: .color(style.line.opacity(0.5 * arc.line.opacity)),
                                style: StrokeStyle(lineWidth: arc.line.width * 3, lineCap: .round))
                }
            }
            for arc in arcs {
                ctx.stroke(arc.path, with: .color(style.line.opacity(arc.line.opacity)), style: StrokeStyle(lineWidth: arc.line.width, lineCap: .round))
            }

            // head offices: a glowing dot, larger with more connections
            for line in lines where (progress[line.id] ?? 1) >= 1 || start == nil {
                guard let s = globe.project(line.to) else { continue }
                let dot = 2 + 2 * line.level, halo = dot * 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - halo, y: s.y - halo, width: 2 * halo, height: 2 * halo)), with: .radialGradient(
                    Gradient(colors: [style.office.opacity(0.45 * line.opacity), style.office.opacity(0)]),
                    center: CGPoint(x: s.x, y: s.y), startRadius: 0, endRadius: halo))
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - dot, y: s.y - dot, width: 2 * dot, height: 2 * dot)),
                         with: .color(style.office.opacity(0.6 + 0.4 * line.level)))
            }
            if let start, let s = globe.project(start) {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 16, y: s.y - 16, width: 32, height: 32)), with: .radialGradient(
                    Gradient(colors: [style.start.opacity(0.5), style.start.opacity(0)]), center: CGPoint(x: s.x, y: s.y), startRadius: 0, endRadius: 16))
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 4, y: s.y - 4, width: 8, height: 8)), with: .color(style.start))
            }
        }
    }
}
