import Flows
import Foundation
import PCAPNG
import Pipeline
import Storage
import Testing
import TestSupport

@testable import Report

// every band file in Tests/Expected whose capture exists in the fixtures folder must pass the ratchet.
// returns the scenario names it checked; empty when there is no fixtures folder.
private func checkBands(expected: URL, fixtures: URL?) async throws -> [(scenario: String, regressions: [Regression])] {
    guard let fixtures else { return [] }
    var out: [(String, [Regression])] = []
    let files = (try? FileManager.default.contentsOfDirectory(at: expected, includingPropertiesForKeys: nil)) ?? []
    for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
        let bands = try BandsFile.load(file)
        let capture = fixtures.appendingPathComponent("captures/\(bands.scenario).pcapng")
        guard FileManager.default.fileExists(atPath: capture.path) else { continue }
        let session = CaptureSession(id: UUID(), startedAt: Date(), source: "fixture", watchVersion: "test")
        let pipeline = CapturePipeline(store: nil, session: session, retainFlows: true, retainDomains: true)
        let stats = try await pipeline.run(FilePacketSource(url: capture))
        await pipeline.stop(reason: .captureStopped)
        let snapshot = PipelineSnapshot(
            packets: stats.packets, decoded: stats.decoded, skipped: stats.skipped,
            malformed: stats.malformed, droppedNoPort: stats.droppedNoPort)
        let report = ReportBuilder.build(
            flows: await pipeline.flowsSnapshot(), domains: await pipeline.domainsSnapshot(), pipeline: snapshot)
        out.append((bands.scenario, Ratchet.check(report: report, bands: bands)))
    }
    return out
}

private func expectedFolder() throws -> URL {
    let root = try #require(RepoGuard.repoRoot())
    return root.appendingPathComponent("Tests/Expected", isDirectory: true)
}

@Test func fixtureBandsHold() async throws {
    let results = try await checkBands(expected: expectedFolder(), fixtures: Fixtures.directory)
    for r in results {
        print("bands \(r.scenario): \(r.regressions.isEmpty ? "ok" : r.regressions.map(\.description).joined(separator: "; "))")
        #expect(r.regressions.isEmpty)
    }
}

@Test func fixtureBandsSkipWithoutFixtures() async throws {
    // no fixtures folder: nothing is checked and nothing fails
    #expect(try await checkBands(expected: expectedFolder(), fixtures: nil).isEmpty)
}

@Test func fixtureBandsRunOnATemporaryFolder() async throws {
    // the same runner on a synthetic capture: bands made from it pass
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixbands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let captures = root.appendingPathComponent("captures"), expected = root.appendingPathComponent("expected")
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
    try Data(SyntheticCorpus.mixed().bytes).write(to: captures.appendingPathComponent("synthetic.pcapng"))

    let session = CaptureSession(id: UUID(), startedAt: Date(), source: "x", watchVersion: "test")
    let pipeline = CapturePipeline(store: nil, session: session, retainFlows: true, retainDomains: true)
    _ = try await pipeline.run(DataPacketSource(SyntheticCorpus.mixed().bytes))
    await pipeline.stop(reason: .captureStopped)
    let report = ReportBuilder.build(
        flows: await pipeline.flowsSnapshot(), domains: await pipeline.domainsSnapshot(), pipeline: nil)

    let bands = Bands.make(from: report, scenario: "synthetic", baselineLabel: "test")
    try Data(bands.json().utf8).write(to: expected.appendingPathComponent("synthetic.json"))
    let results = try await checkBands(expected: expected, fixtures: root)
    #expect(results.map(\.scenario) == ["synthetic"])
    // (the synthetic capture is under 10,000 bytes, so its bands are informational)
    #expect(results[0].regressions.isEmpty)
}
