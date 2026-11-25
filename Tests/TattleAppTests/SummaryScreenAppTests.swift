import Flows
import Foundation
import PacketDecoder
import Storage
import Summary
import Testing
import TestSupport

@testable import TattleApp

private func tempStore() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tattle-app-summary-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("db.sqlite")
}

private func flow(process: String, at time: Date) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0xCB00_7102), localPort: 50000,
        remoteAddress: .v4(0xC000_0201), remotePort: 443)
    var f = Flow(key: key, interface: "en0", at: time)
    f.serverName = "doubleclick.net"
    f.ipBytesIn = 3000
    f.ipBytesOut = 1000
    f.tally[ProcessPair(process, 7, nil, nil)] = 3
    return f
}

private func storeSession(_ store: Store, process: String, daysAgo: Double, now: Date) throws -> UUID {
    let at = now.addingTimeInterval(-daysAgo * 86400)
    let id = UUID()
    try store.beginSession(CaptureSession(id: id, startedAt: at, source: "test", watchVersion: "test"))
    try store.save(flows: [flow(process: process, at: at)], domains: [], session: id)
    try store.endSession(id: id, at: at, reason: "test")
    return id
}

@Test func summaryScreenSidebarStartsWithSummary() {
    #expect(SidebarItem.allCases.first == .summary)
}

@Test func summaryScreenEmptyStoreIsEmpty() throws {
    let path = tempStore()
    _ = try Store(path: path)
    let screen = try SummaryLoader.load(storePath: path, retentionDays: 7, now: Date(), excluding: nil, demo: false)
    #expect(screen.isEmpty)
}

@Test func summaryScreenDemoNeedsNoStore() throws {
    let now = Date()
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("tattle-app-summary-missing-" + UUID().uuidString)
        .appendingPathComponent("db.sqlite")
    let screen = try SummaryLoader.load(storePath: missing, retentionDays: 7, now: now, excluding: nil, demo: true)
    #expect(screen.rows.map(\.title) == SummaryDemo.screen(now: now).rows.map(\.title))
}

@Test func summaryScreenUsesSessionsWithinRetention() throws {
    let path = tempStore()
    let now = Date()
    let store = try Store(path: path)
    let recent = try storeSession(store, process: "Recentapp", daysAgo: 1, now: now)
    _ = try storeSession(store, process: "Oldapp", daysAgo: 10, now: now)
    let screen = try SummaryLoader.load(storePath: path, retentionDays: 7, now: now, excluding: nil, demo: false)
    let titles = screen.rows.map(\.title)
    #expect(titles.contains("Recentapp"))
    #expect(!titles.contains("Oldapp"))
    let excluded = try SummaryLoader.load(storePath: path, retentionDays: 7, now: now, excluding: recent, demo: false)
    #expect(excluded.isEmpty)
}
