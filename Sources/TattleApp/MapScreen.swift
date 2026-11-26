import SwiftUI
import WorldMap

/// the live map: observes the feed, so the Live screen's tables do not redraw with every spark
struct LiveMap: View {
    @ObservedObject var feed: MapFeed
    let start: MapStart
    var mode: MapPanel.Mode = .live

    var body: some View {
        MapPanel(mode: mode, lines: feed.live, start: start, firstSeen: feed.firstSeen, events: feed.events,
                 notDrawnText: MapText.notDrawn(feed.live.notDrawn), controlsText: mode == .live ? MapText.liveControls : nil)
    }
}

/// the Map screen: follows the capture while one runs, otherwise shows the Summary; the user can turn and zoom it
/// (owner, 2026-11-25: interaction only here)
struct MapScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isCapturing ? "Map · this capture" : "Map · everything in the Summary").font(.headline).foregroundStyle(.secondary)
            if model.isCapturing {
                LiveMap(feed: model.mapFeed, start: model.mapStart, mode: .interactive)
            } else {
                let map = model.summaryMap
                MapPanel(mode: .interactive, lines: map.lines, start: model.mapStart,
                         notDrawnText: MapText.notDrawnApps(map.notDrawn), unit: ("app", "apps"))
            }
            Text("Drag to turn the globe, pinch or use the buttons to zoom, point at a head office to see its companies.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { if !model.isCapturing { model.refreshSummary() } }
    }
}
