import SwiftUI
import WorldMap

/// the company map as placed in the app (Milestone 4, Part 4): on top of Live and the Summary, and on the Map screen
struct MapPanel: View {
    enum Mode: Equatable {
        /// follows a capture: the camera rules and a spark for every connection
        case live
        /// the Summary: one near-to-far replay, then still
        case replay
        /// the Map screen: drag to turn, pinch or the buttons to zoom, hover a head office for its companies
        case interactive
    }

    let mode: Mode
    let lines: MapLines
    let start: MapStart
    var firstSeen: [String: Date] = [:]
    var events: [(id: String, time: Date)] = []
    /// connections (live) or companies (Summary) that cannot be drawn
    var notDrawnText: String?
    /// what a line's count counts: connections (live) or apps (the Summary)
    var unit = (one: "connection", many: "connections")

    @State private var camera: GlobeCamera?
    @State private var lastFrame: Date?
    @State private var worldSince: Date?
    @State private var replayStarted = Date()
    /// the Map screen: where the user turned the globe to, and the zoom
    @State private var dragFrom: GlobeCamera?
    @State private var hover: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                TimelineView(.animation(paused: mode == .interactive && dragFrom == nil && hover == nil && camera != nil)) { context in
                    let now = context.date
                    let shown = frame(now: now)
                    GlobeView(centre: shown.camera.centre, zoom: shown.camera.zoom, lines: lines.lines, start: start.point,
                              progress: shown.progress, activity: shown.activity)
                        .overlay(alignment: .topLeading) { hoverLabel(size: geo.size, camera: shown.camera) }
                }
                .contentShape(Rectangle())
                .gesture(mode == .interactive ? drag(size: geo.size) : nil)
                .gesture(mode == .interactive ? pinch : nil)
                .onContinuousHover { phase in
                    guard mode == .interactive else { return }
                    if case .active(let p) = phase { hover = p } else { hover = nil }
                }
                .overlay(alignment: .bottomTrailing) {
                    if mode == .interactive { zoomButtons.padding(10) }
                }
                .overlay(alignment: .bottomLeading) {
                    if start.isDefault {
                        Text("Default location").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.55))).foregroundStyle(.white).padding(10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(MapText.notServers)
                if start.isDefault { Text(MapText.defaultStart) }
                if let notDrawnText { Text(notDrawnText) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: lines.lines.count) { _ in if mode == .replay { replayStarted = Date() } }
    }

    /// the camera and the line state for one frame
    private func frame(now: Date) -> (camera: GlobeCamera, progress: [String: Double], activity: [LineActivity]) {
        let dt = lastFrame.map { min(0.1, now.timeIntervalSince($0)) } ?? 0
        var progress: [String: Double] = [:], activity: [LineActivity] = [], target: GlobeCamera
        switch mode {
        case .live:
            progress = firstSeen.mapValues { min(1, max(0, now.timeIntervalSince($0) / 0.4)) }
            activity = events.map { LineActivity(lineID: $0.id, age: now.timeIntervalSince($0.time)) }
            let drawn = lines.lines.filter { (progress[$0.id] ?? 1) > 0 }
            let world = CameraDirector.isWorldView(drawn)
            let since = world ? (worldSince ?? now) : nil
            target = CameraDirector.target(start: start.point, lines: drawn, seconds: since.map { now.timeIntervalSince($0) } ?? 0)
            DispatchQueue.main.async { if world && worldSince == nil { worldSince = now } else if !world { worldSince = nil } }
        case .replay:
            let replay = Replay(lines: lines, start: start.point)
            let t = now.timeIntervalSince(replayStarted)
            progress = replay.progress(at: t)
            target = CameraDirector.target(start: start.point, lines: replay.started(at: t), spin: false)
        case .interactive:
            target = camera ?? CameraDirector.target(start: start.point, lines: lines.lines, spin: false)
        }
        let current = camera ?? target
        let next = mode == .interactive ? target : CameraDirector.step(from: current, to: target, seconds: dt)
        DispatchQueue.main.async {
            camera = next
            lastFrame = now
        }
        return (next, progress, activity)
    }

    // MARK: the Map screen's controls

    private func drag(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragFrom ?? camera ?? CameraDirector.target(start: start.point, lines: lines.lines, spin: false)
                if dragFrom == nil { dragFrom = base }
                // one view-width of drag turns the globe by the angle the view spans
                let radius = min(size.width, size.height) * base.zoom
                let dLon = -value.translation.width / radius * 180 / .pi
                let dLat = value.translation.height / radius * 180 / .pi
                camera = GlobeCamera(centre: GeoPoint(latitude: max(-85, min(85, base.centre.latitude + dLat)),
                                                      longitude: wrap(base.centre.longitude + dLon)), zoom: base.zoom)
            }
            .onEnded { _ in dragFrom = nil }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = dragFrom ?? camera ?? CameraDirector.target(start: start.point, lines: lines.lines, spin: false)
                if dragFrom == nil { dragFrom = base }
                camera = GlobeCamera(centre: base.centre, zoom: clampZoom(base.zoom * scale))
            }
            .onEnded { _ in dragFrom = nil }
    }

    private var zoomButtons: some View {
        HStack(spacing: 6) {
            Button { zoom(by: 1 / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom(by: 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { camera = nil } label: { Image(systemName: "location") }.help("Back to the start")
        }
        .buttonStyle(.bordered)
    }

    private func zoom(by factor: Double) {
        let base = camera ?? CameraDirector.target(start: start.point, lines: lines.lines, spin: false)
        camera = GlobeCamera(centre: base.centre, zoom: clampZoom(base.zoom * factor))
    }

    private func clampZoom(_ z: Double) -> Double { max(CameraDirector.worldZoom, min(8, z)) }

    private func wrap(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 }
        if l < -180 { l += 360 }
        return l
    }

    /// on the Map screen: the city and companies of the head office under the pointer
    @ViewBuilder
    private func hoverLabel(size: CGSize, camera: GlobeCamera) -> some View {
        if mode == .interactive, let hover {
            let globe = Orthographic(centre: camera.centre, radius: min(size.width, size.height) * camera.zoom,
                                     originX: size.width / 2, originY: size.height / 2)
            let near = lines.lines.compactMap { line -> (MapLine, Double, CGPoint)? in
                guard let p = globe.project(line.to) else { return nil }
                let d = hypot(p.x - hover.x, p.y - hover.y)
                return d < 14 ? (line, d, CGPoint(x: p.x, y: p.y)) : nil
            }.min { $0.1 < $1.1 }
            if let (line, _, p) = near {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.city.isEmpty ? "Head office" : line.city).font(.caption.bold())
                    Text(line.companies.joined(separator: ", ")).font(.caption)
                    Text(line.count == 1 ? "1 \(unit.one)" : "\(line.count) \(unit.many)").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                .frame(maxWidth: 260, alignment: .leading)
                .offset(x: min(p.x + 12, size.width - 270), y: max(0, p.y - 20))
                .allowsHitTesting(false)
            }
        }
    }
}
