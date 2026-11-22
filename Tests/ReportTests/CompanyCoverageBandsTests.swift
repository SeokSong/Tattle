import Attribution
import Companies
import Flows
import Foundation
import PCAPNG
import Pipeline
import Storage
import Summary
import Testing
import TestSupport

// every band file in Tests/Expected/companies whose capture exists in the fixtures folder must pass the
// coverage ratchet with the curated-only classifier (the frozen baseline). numbers only are printed.
// skips when TATTLE_FIXTURES is unset

@Test func curatedOnlyCoverageBaselinesHold() async throws {
    guard let fixtures = Fixtures.directory else { return }
    let folder = try #require(RepoGuard.repoRoot()).appendingPathComponent("Tests/Expected/companies", isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    #expect(!files.isEmpty)
    var checked = 0
    for file in files {
        let bands = try CoverageBands.load(file)
        let capture = fixtures.appendingPathComponent("captures/\(bands.scenario).pcapng")
        guard FileManager.default.fileExists(atPath: capture.path) else { continue }
        let session = CaptureSession(id: UUID(), startedAt: Date(), source: "fixture", watchVersion: "test")
        let pipeline = CapturePipeline(store: nil, session: session, retainFlows: true, retainDomains: true)
        _ = try await pipeline.run(FilePacketSource(url: capture))
        await pipeline.stop(reason: .captureStopped)
        let flows = await pipeline.flowsSnapshot()
        let index = HostnameIndex(await pipeline.domainsSnapshot(), flows: flows)
        let result = Coverage.build(flows: flows, index: index, sources: [.curated])
        let regressions = CoverageRatchet.check(report: result.report, bands: bands)
        print("company coverage \(bands.scenario): \(regressions.isEmpty ? "ok" : regressions.map(\.description).joined(separator: "; "))")
        #expect(regressions.isEmpty)
        checked += 1
    }
    #expect(checked > 0)
}
