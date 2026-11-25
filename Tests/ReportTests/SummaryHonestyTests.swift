import Attribution
import Companies
import Domains
import Flows
import Foundation
import PCAPNG
import Pipeline
import Report
import Storage
import Summary
import Testing
import TestSupport

private typealias Expected = SummaryCorpus.Expected

/// the failed equalities between the summary and the quality report, as numbers only; empty when all hold
private func check(_ summary: CaptureSummary, _ report: QualityReport) -> [String] {
    var failures: [String] = []
    let all443 = summary.apps + (summary.appleApps.map { [$0] } ?? [])
    for reason in UnnamedReason.allCases {
        let s = all443.reduce(0) { $0 + ($1.unseen[reason]?.bytes ?? 0) }
        let r = report.hostnames.unnamedShare[reason.rawValue]?.numerator
        if s != r { failures.append("\(reason.rawValue) summary \(s) report \(r.map(String.init) ?? "nil")") }
    }
    let appsDenominator = all443.reduce(0) { $0 + $1.coverage.denominator }
    for (name, ratio) in report.hostnames.unnamedShare where ratio.denominator != appsDenominator {
        failures.append("app denominator summary \(appsDenominator) report \(ratio.denominator) (\(name))")
    }
    let all = appsDenominator + (summary.system?.coverage.denominator ?? 0) + summary.noProcess.bytes
        + summary.excluded.values.reduce(0) { $0 + $1.bytes }
    let port443 = report.hostnames.hostnameCoverageSniOnly.denominator
    if all != port443 { failures.append("port 443 summary \(all) report \(port443)") }
    return failures
}

private func corpusSummary(flows: [Flow], observations: [DomainObservation]) throws -> CaptureSummary {
    let curated = try CuratedList(parsing: SummaryCorpus.curatedTSV, version: "")
    let trackers = try TrackerList(parsing: SummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: SummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: SummaryCorpus.trackerAliasesTSV), version: "")
    return SummaryBuilder.build(flows: flows, index: HostnameIndex(observations, flows: flows),
        classifier: CompanyClassifier(curated: curated, trackers: trackers), apps: try AppTable(parsing: SummaryCorpus.appsTSV))
}

@Test func summaryAgreesWithReportOnTheCorpus() throws {
    let flows = SummaryCorpus.flows()
    let observations = SummaryCorpus.observations()
    let summary = try corpusSummary(flows: flows, observations: observations)
    let report = ReportBuilder.build(flows: flows, domains: observations, pipeline: nil)
    #expect(check(summary, report) == [])
    for (reason, bytes) in Expected.reportUnnamedBytes {
        #expect(report.hostnames.unnamedShare[reason]?.numerator == bytes)
    }
    #expect(report.hostnames.unnamedShare.values.allSatisfy { $0.denominator == Expected.appTrafficPort443Bytes })
    #expect(report.hostnames.hostnameCoverageSniOnly.denominator == Expected.port443Bytes)
}

@Test func summaryAgreesWithReportOnEveryFixtureCapture() async throws {
    guard let fixtures = Fixtures.directory else { return }
    let folder = fixtures.appendingPathComponent("captures", isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "pcapng" }.sorted { $0.path < $1.path }
    var checked = 0
    for file in files {
        let session = CaptureSession(id: UUID(), startedAt: Date(), source: "fixture", watchVersion: "test")
        let pipeline = CapturePipeline(store: nil, session: session, retainFlows: true, retainDomains: true)
        _ = try await pipeline.run(FilePacketSource(url: file))
        await pipeline.stop(reason: .captureStopped)
        let flows = await pipeline.flowsSnapshot()
        let domains = await pipeline.domainsSnapshot()
        let report = ReportBuilder.build(flows: flows, domains: domains, pipeline: nil)
        let summary = SummaryBuilder.build(flows: flows, index: HostnameIndex(domains, flows: flows))
        let failures = check(summary, report)
        print("summary honesty \(file.deletingPathExtension().lastPathComponent): \(failures.isEmpty ? "ok" : failures.joined(separator: "; "))")
        #expect(failures.isEmpty)
        checked += 1
    }
    #expect(checked > 0)
}

@Test func echOuterNameIsUnseenInTheSummaryButNamedInTheReport() throws {
    var flows = SummaryCorpus.flows()
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0xCB00_7102), localPort: 50200,
        remoteAddress: .v4(0xC000_0200 + 200), remotePort: 443)
    var extra = Flow(key: key, interface: "en0", at: SummaryCorpus.t0)
    extra.lastSeen = SummaryCorpus.t0
    extra.tally[ProcessPair("Bobber", 301, nil, nil)] = 3
    extra.ipBytesIn = 100
    extra.ipBytesOut = 23
    flows.append(extra)
    let observations = SummaryCorpus.observations() + [
        DomainObservation(time: SummaryCorpus.t0, source: .sni, hostname: "outer.example.test", flowKey: key, echPresent: true)
    ]
    let summary = try corpusSummary(flows: flows, observations: observations)
    let report = ReportBuilder.build(flows: flows, domains: observations, pipeline: nil)
    for reason in UnnamedReason.allCases {
        let s = (summary.apps + (summary.appleApps.map { [$0] } ?? [])).reduce(0) { $0 + ($1.unseen[reason]?.bytes ?? 0) }
        let r = try #require(report.hostnames.unnamedShare[reason.rawValue]).numerator
        #expect(s == (reason == .echHidden ? r + 123 : r), "\(reason.rawValue) summary \(s) report \(r)")
    }
    let appsDenominator = (summary.apps + (summary.appleApps.map { [$0] } ?? [])).reduce(0) { $0 + $1.coverage.denominator }
    #expect(report.hostnames.unnamedShare.values.allSatisfy { $0.denominator == appsDenominator })
    let all = appsDenominator + (summary.system?.coverage.denominator ?? 0) + summary.noProcess.bytes
        + summary.excluded.values.reduce(0) { $0 + $1.bytes }
    #expect(all == report.hostnames.hostnameCoverageSniOnly.denominator)
}
