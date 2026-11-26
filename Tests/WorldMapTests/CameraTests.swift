import Foundation
import Testing
import WorldMap

// the owner's camera rules (2026-11-25), on made-up companies at real cities' coordinates

private let start = GeoPoint(latitude: 39.8, longitude: -98.6)

private func lines(_ places: [(String, Double, Double, String)]) -> MapLines {
    var map = MapLines()
    for (name, lat, lon, country) in places { map.add(company: name, place: GeoPoint(latitude: lat, longitude: lon), country: country) }
    return map
}

@Test func cameraStartsOnTheUserWithTheUSInView() {
    let camera = CameraDirector.target(start: start, lines: [])
    #expect(camera.zoom == CameraDirector.closestZoom)
    // looked at from a little south, the start still in the middle's longitude and still in view up close
    #expect(camera.centre.latitude < start.latitude && start.latitude - camera.centre.latitude <= CameraDirector.tilt)
    #expect(abs(camera.centre.longitude - start.longitude) < 1e-9)
    #expect(sin(Geo.angle(camera.centre, start)) * camera.zoom < 0.5)
}

@Test func cameraZoomsOutToFitNorthAmericanLines() throws {
    let near = CameraDirector.target(start: start, lines: lines([("Adlantic", 39.1, -94.6, "United States")]).lines)
    // Anchorage is farther than the starting view shows, so the camera zooms out to fit it
    let wider = CameraDirector.target(start: start, lines: lines([("Adlantic", 39.1, -94.6, "United States"),
                                                                  ("Trackwise", 61.2, -149.9, "United States")]).lines)
    #expect(near.zoom > wider.zoom)
    // still the North America view: not the whole globe
    #expect(wider.zoom > CameraDirector.worldZoom)
    // every point is inside the view at that zoom: its angle from the centre fits in the view's half-width
    for p in [start, GeoPoint(latitude: 61.2, longitude: -149.9)] {
        #expect(sin(Geo.angle(wider.centre, p)) * wider.zoom < 0.5)
    }
    // Canada and Mexico keep the North America view
    let continent = lines([("Northco", 43.65, -79.38, "Canada"), ("Southco", 19.43, -99.13, "Mexico")]).lines
    #expect(!CameraDirector.isWorldView(continent))
}

@Test func aHeadOfficeOutsideNorthAmericaShowsTheWholeGlobe() {
    let map = lines([("Adlantic", 37.4, -122.1, "United States"), ("Pixelbeam", 51.5, -0.1, "United Kingdom")])
    #expect(CameraDirector.isWorldView(map.lines))
    let camera = CameraDirector.target(start: start, lines: map.lines)
    #expect(camera.zoom == CameraDirector.worldZoom)
    // the same lines give the same view: nothing turns on its own
    #expect(CameraDirector.target(start: start, lines: map.lines) == camera)
}

@Test func countryDecidesAndTheBoxIsOnlyTheFallback() {
    // Honolulu is in the United States though far out in the Pacific
    #expect(!CameraDirector.isWorldView(lines([("Islandco", 21.3, -157.9, "United States")]).lines))
    // with no country, a place in Europe is outside the box
    #expect(CameraDirector.isWorldView(lines([("Nowhere", 48.9, 2.35, "")]).lines))
    #expect(!CameraDirector.isWorldView(lines([("Nowhere", 40.7, -74.0, "")]).lines))
}

@Test func cameraGlidesAndTakesTheShortWayRound() {
    let a = GlobeCamera(centre: GeoPoint(latitude: 0, longitude: 170), zoom: 2)
    let b = GlobeCamera(centre: GeoPoint(latitude: 0, longitude: -170), zoom: 0.5)
    let half = CameraDirector.step(from: a, to: b, seconds: 0.6, halfLife: 0.6)
    // halfway in one half-life, going east across the date line (20 degrees, not 340)
    #expect(abs(half.centre.longitude - 180) < 1e-6 || abs(half.centre.longitude + 180) < 1e-6)
    // zoom halfway on a log scale: the square root of 2 * 0.5 = 1
    #expect(abs(half.zoom - 1) < 1e-9)
    // no time, no move; a long time, arrived
    #expect(CameraDirector.step(from: a, to: b, seconds: 0) == a)
    let done = CameraDirector.step(from: a, to: b, seconds: 60)
    #expect(abs(done.zoom - 0.5) < 1e-6 && abs(done.centre.longitude + 170) < 1e-6)
}

@Test func replayDrawsNearestFirstThenStops() {
    let map = lines([("Far", -33.9, 151.2, "Australia"), ("Near", 39.1, -94.6, "United States"), ("Middle", 40.7, -74.0, "United States")])
    let replay = Replay(lines: map, start: start)
    #expect(replay.order.map { $0.companies[0] } == ["Near", "Middle", "Far"])
    // at the start nothing is drawn; the nearest begins first
    let p0 = replay.progress(at: 0)
    #expect(p0.values.allSatisfy { $0 == 0 })
    let p1 = replay.progress(at: Replay.gapSeconds)
    #expect(p1[replay.order[0].id]! > 0 && p1[replay.order[1].id]! == 0)
    // the camera stays on North America until the far line starts, then shows the world
    #expect(!CameraDirector.isWorldView(replay.started(at: Replay.gapSeconds * 1.5)))
    #expect(CameraDirector.isWorldView(replay.started(at: Replay.gapSeconds * 2)))
    // all drawn when the replay ends
    #expect(replay.progress(at: replay.duration).values.allSatisfy { $0 == 1 })
    #expect(Replay(lines: MapLines(), start: start).duration == 0)
}

@Test func worldViewFacesWhereMostHeadOfficesAre() {
    // four in Europe, one in the US: the world view faces Europe's side, so most lines are on the near side
    let map = lines([("A", 51.5, -0.1, "United Kingdom"), ("B", 48.9, 2.35, "France"), ("C", 52.5, 13.4, "Germany"),
                     ("D", 59.3, 18.1, "Sweden"), ("E", 37.4, -122.1, "United States")])
    let camera = CameraDirector.target(start: start, lines: map.lines)
    let eye = camera.centre
    let near = map.lines.filter { Geo.angle(eye, $0.to) < .pi / 2 }.count
    #expect(near >= 5 - 1)
    #expect(Geo.angle(eye, GeoPoint(latitude: 51.5, longitude: -0.1)) < .pi / 2)
}

@Test func worldViewKeepsTheStartInView() {
    // one head office far away (Tel Aviv): the view turns towards it but keeps the start well inside the globe
    let map = lines([("Far", 32.1, 34.8, "Israel")])
    let camera = CameraDirector.target(start: start, lines: map.lines)
    #expect(Geo.angle(camera.centre, start) < 62 * .pi / 180)
}

@Test func liveWorldViewFollowsTheLatestConnections() throws {
    // a ping to London, then pings to Seattle: the camera turns back to show Seattle and the start
    let seattle = GeoPoint(latitude: 47.6, longitude: -122.3), london = GeoPoint(latitude: 51.5, longitude: -0.1)
    let toSeattle = try #require(CameraDirector.follow(start: start, recent: [seattle]))
    #expect(toSeattle.zoom == CameraDirector.worldZoom)
    #expect(Geo.angle(toSeattle.centre, seattle) < .pi / 4 && Geo.angle(toSeattle.centre, start) < .pi / 4)
    let toLondon = try #require(CameraDirector.follow(start: start, recent: [london]))
    #expect(Geo.angle(toLondon.centre, london) < .pi / 2 && Geo.angle(toLondon.centre, start) < .pi / 2)
    // nothing recent: nothing to follow
    #expect(CameraDirector.follow(start: start, recent: []) == nil)
}

@Test func theStartingViewShowsTheContiguousUS() {
    // from the middle of the US, both coasts are in the starting view, so the first lines are on screen at once
    let camera = CameraDirector.target(start: start, lines: [])
    for coast in [GeoPoint(latitude: 37.8, longitude: -122.4), GeoPoint(latitude: 40.7, longitude: -74.0)] {
        #expect(sin(Geo.angle(camera.centre, coast)) * camera.zoom < 0.5)
    }
}
