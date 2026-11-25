import Foundation
import Testing
import WorldMap

// made-up places and companies only; distances are worked out by hand from the haversine formula

private let equator0 = GeoPoint(latitude: 0, longitude: 0)

@Test func distanceIsAlongTheSurface() {
    // a quarter of the way round the Earth: pi/2 * 6371 = 10,007.5 km
    #expect(abs(Geo.distanceKm(equator0, GeoPoint(latitude: 0, longitude: 90)) - 10_007.5) < 0.5)
    #expect(abs(Geo.distanceKm(equator0, GeoPoint(latitude: 90, longitude: 0)) - 10_007.5) < 0.5)
    // one degree of longitude on the equator: 6371 * pi / 180 = 111.19 km
    #expect(abs(Geo.distanceKm(equator0, GeoPoint(latitude: 0, longitude: 1)) - 111.19) < 0.01)
    #expect(Geo.distanceKm(equator0, equator0) == 0)
}

@Test func greatCircleStartsAndEndsOnTheTwoPlaces() {
    let a = GeoPoint(latitude: 38.8, longitude: -104.8), b = GeoPoint(latitude: 51.5, longitude: -0.1)
    let path = Geo.greatCircle(from: a, to: b, steps: 10)
    #expect(path.count == 11 && path.first == a && path.last == b)
    // every step is the same length: the path is the shortest way, cut evenly
    let steps = zip(path, path.dropFirst()).map { Geo.distanceKm($0, $1) }
    let total = Geo.distanceKm(a, b)
    #expect(steps.allSatisfy { abs($0 - total / 10) < 0.5 })
    // the shortest way from the Rockies to London bends north over Canada and Greenland
    #expect(path.map(\.latitude).max()! > 55)
}

@Test func greatCircleCopesWithOppositePoints() {
    let path = Geo.greatCircle(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: 180), steps: 8)
    #expect(path.first == GeoPoint(latitude: 0, longitude: 0))
    #expect(abs(path.last!.longitude) == 180)
    #expect(path.allSatisfy { !$0.latitude.isNaN && !$0.longitude.isNaN })
}

@Test func projectionPutsTheCentreInTheMiddleAndHidesTheFarSide() throws {
    let globe = Orthographic(centre: GeoPoint(latitude: 40, longitude: -100), radius: 100, originX: 300, originY: 200)
    let middle = try #require(globe.project(GeoPoint(latitude: 40, longitude: -100)))
    #expect(abs(middle.x - 300) < 1e-9 && abs(middle.y - 200) < 1e-9)
    // north is up: a point further north is higher on screen (smaller y)
    #expect(try #require(globe.project(GeoPoint(latitude: 50, longitude: -100))).y < 200)
    // east is right
    #expect(try #require(globe.project(GeoPoint(latitude: 40, longitude: -90))).x > 300)
    // the opposite side of the Earth is hidden
    #expect(globe.project(GeoPoint(latitude: -40, longitude: 80)) == nil)
    // every visible point is inside the disc
    for lat in stride(from: -80.0, through: 80, by: 20) {
        for lon in stride(from: -180.0, through: 180, by: 30) {
            if let p = globe.project(GeoPoint(latitude: lat, longitude: lon)) {
                #expect(((p.x - 300) * (p.x - 300) + (p.y - 200) * (p.y - 200)).squareRoot() <= 100 + 1e-9)
            }
        }
    }
}

@Test func unprojectUndoesProject() throws {
    let globe = Orthographic(centre: GeoPoint(latitude: 30, longitude: 20), radius: 250, originX: 400, originY: 300)
    for place in [GeoPoint(latitude: 45, longitude: 10), GeoPoint(latitude: 10, longitude: 60), GeoPoint(latitude: -20, longitude: 0)] {
        let p = try #require(globe.project(place))
        let back = try #require(globe.unproject(x: p.x, y: p.y))
        #expect(abs(back.latitude - place.latitude) < 1e-6 && abs(back.longitude - place.longitude) < 1e-6)
    }
    #expect(globe.unproject(x: 400 + 251, y: 300) == nil)
}

@Test func farSidePointsGoOntoTheRim() {
    let globe = Orthographic(centre: GeoPoint(latitude: 0, longitude: 0), radius: 100, originX: 0, originY: 0)
    let rim = globe.projectOntoRim(GeoPoint(latitude: 0, longitude: 120))
    #expect(abs((rim.x * rim.x + rim.y * rim.y).squareRoot() - 100) < 1e-9)
    #expect(rim.x > 0)
}

@Test func linesBreakWhereTheyGoBehindTheGlobe() {
    let globe = Orthographic(centre: GeoPoint(latitude: 0, longitude: 0), radius: 100, originX: 0, originY: 0)
    // along the equator from 0 to 179 degrees east: visible up to 90, hidden after
    let line = stride(from: 0.0, through: 179, by: 10).map { GeoPoint(latitude: 0, longitude: $0) }
    let pieces = globe.visiblePieces(line)
    #expect(pieces.count == 1 && pieces[0].count == 10)
}

@Test func repeatsShareALineAndMakeItBrighter() {
    var map = MapLines()
    let springfield = GeoPoint(latitude: 39.8, longitude: -89.6)
    map.add(company: "Adlantic", place: springfield, city: "Springfield")
    let first = map.lines[0]
    #expect(first.count == 1 && first.opacity == 0.35 && first.width == 1)
    for _ in 0..<31 { map.add(company: "Adlantic", place: springfield, city: "Springfield") }
    // another company in the same place shares the line
    map.add(company: "Trackwise", place: GeoPoint(latitude: 39.8001, longitude: -89.6001), city: "Springfield")
    #expect(map.lines.count == 1)
    let busy = map.lines[0]
    #expect(busy.count == 33 && busy.companies == ["Adlantic", "Trackwise"])
    #expect(busy.opacity == 1 && busy.width == 3)
    // brightness only grows
    var last = 0.0
    var grow = MapLines()
    for _ in 0..<40 {
        grow.add(company: "Pixelbeam", place: springfield)
        #expect(grow.lines[0].opacity >= last)
        last = grow.lines[0].opacity
    }
}

@Test func connectionsWithoutAPlaceAreCountedNotDrawn() {
    var map = MapLines()
    map.add(company: nil, place: nil)
    map.add(company: "Adlantic", place: nil)
    #expect(map.lines.isEmpty && map.notDrawn == 2)
}

@Test func replayGoesFromNearestToFarthest() {
    var map = MapLines()
    let start = GeoPoint(latitude: 38.8, longitude: -104.8)
    map.add(company: "Far", place: GeoPoint(latitude: -33.9, longitude: 151.2))
    map.add(company: "Near", place: GeoPoint(latitude: 39.7, longitude: -105.0))
    map.add(company: "Middle", place: GeoPoint(latitude: 40.7, longitude: -74.0))
    #expect(map.nearestFirst(from: start).map { $0.companies[0] } == ["Near", "Middle", "Far"])
    // the live order is untouched: first seen first
    #expect(map.lines.map(\.order) == [0, 1, 2])
}

@Test func bundledOutlineLoads() throws {
    let outline = try WorldOutline.loadBundled()
    #expect(outline.land.count > 100 && outline.borders.count > 300)
}

@Test func outlineRejectsBadLines() {
    #expect(throws: WorldOutlineError.badPoint(line: 2)) { try WorldOutline(land: "0,0 1,1\n0,0 1,north\n", borders: "") }
    #expect(throws: WorldOutlineError.badPoint(line: 1)) { try WorldOutline(land: "0,95 1,1\n", borders: "") }
    #expect(throws: WorldOutlineError.tooShort(line: 1)) { try WorldOutline(land: "", borders: "5,5\n") }
}
