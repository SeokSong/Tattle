import Attribution
import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Pipeline
import Storage
import Testing
import TestSupport

@testable import Report

// runs the synthetic corpus through the whole pipeline and the report builder, and compares with the
// hand-computed answers in SyntheticCorpus.Expected. later problems add category and hostname numbers here.

private final class CollectingStore: FlowStore, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [DomainObservation] = []
    var domains: [DomainObservation] { lock.withLock { collected } }

    func beginSession(_ s: CaptureSession) throws {}
    func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws {
        lock.withLock { collected += domains }
    }
    func endSession(id: UUID, at: Date, reason: String) throws {}
    func recordSessionStats(id: UUID, _ stats: SessionStats) throws {}
}

private struct Result {
    var report: QualityReport
    var flows: [Flow]
    var stats: PipelineStats
    var domains: [DomainObservation]
}

private func run(_ bytes: [UInt8]) async throws -> Result {
    let store = CollectingStore()
    let session = CaptureSession(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startedAt: Date(timeIntervalSince1970: Double(SyntheticCorpus.start)), source: "synthetic", watchVersion: "test")
    let pipeline = CapturePipeline(store: store, session: session, retainFlows: true)
    let stats = try await pipeline.run(DataPacketSource(bytes))
    await pipeline.stop(reason: .captureStopped)
    let flows = await pipeline.flowsSnapshot()
    let p = PipelineSnapshot(
        packets: stats.packets, decoded: stats.decoded, skipped: stats.skipped,
        malformed: stats.malformed, droppedNoPort: stats.droppedNoPort)
    let report = ReportBuilder.build(
        flows: flows, domains: store.domains, pipeline: p, options: ReportOptions(watchVersion: "test"))
    return Result(report: report, flows: flows, stats: await pipeline.stats, domains: store.domains)
}

@Test func goldenTotals() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let r = try await run(bytes)
    #expect(r.report.totals.flows == expected.flowCount)
    #expect(r.report.totals.packets == expected.flowPackets)
    #expect(r.report.totals.ipBytes == expected.ipBytes)
    #expect(r.report.byInterface == expected.byInterface)
    #expect(r.stats.packets == expected.packetsRead)
    #expect(r.stats.decoded == expected.decoded)
    #expect(r.stats.skipped == expected.skipped)
    #expect(r.stats.malformed == expected.malformed)
    #expect(r.stats.droppedNoPort == expected.droppedNoPort)
    // the per-flow numbers, so a total cannot hide two errors that cancel
    for e in expected.flows {
        let flow = r.flows.first { $0.key.remoteAddress == e.remote && $0.key.remotePort == e.remotePort }
        guard let flow else { Issue.record("flow \(e.label) missing"); continue }
        #expect(flow.packetsIn + flow.packetsOut == e.packets, "\(e.label) packets")
        #expect(flow.ipBytesIn + flow.ipBytesOut == e.ipBytes, "\(e.label) bytes")
        #expect(flow.interface == e.interface, "\(e.label) interface")
        #expect(flow.serverName == e.serverName, "\(e.label) server name")
        #expect(flow.startedMidstream == e.startedMidstream, "\(e.label) midstream")
        #expect(flow.echSeen == e.echSeen, "\(e.label) ech")
    }
}

@Test func goldenAttribution() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let a = try await run(bytes).report.attribution
    // F5 has no process on any packet
    #expect(a.noProcessShare == Ratio(numerator: expected.flow("F5").ipBytes, denominator: expected.ipBytes))
    #expect(a.noProcessShare == Ratio(numerator: expected.noProcessBytes, denominator: expected.ipBytes))
    // everything else has a process
    #expect(a.attributedShare == Ratio(numerator: expected.ipBytes - expected.flow("F5").ipBytes, denominator: expected.ipBytes))
    #expect(a.attributedShare == Ratio(numerator: expected.attributedBytes, denominator: expected.ipBytes))
    #expect(a.mixedFlowShare == Ratio(numerator: expected.mixedBytes, denominator: expected.ipBytes))
}

@Test func goldenSniOnlyCoverage() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let h = try await run(bytes).report.hostnames
    // F1 and F3 have a name; F7 counts too, because the M1 view takes any serverName, outer ECH name included
    let named = ["F1", "F3", "F7"].map { expected.flow($0).ipBytes }.reduce(0, +)
    #expect(h.hostnameCoverageSniOnly == Ratio(numerator: named, denominator: expected.port443Bytes))
    #expect(h.hostnameCoverageSniOnly == Ratio(numerator: expected.sniNamedBytes, denominator: expected.port443Bytes))
}

@Test func goldenReconciliationOk() async throws {
    let (bytes, _) = SyntheticCorpus.mixed()
    let rec = try await run(bytes).report.reconciliation
    #expect(rec.ok)
    #expect(rec.checks.map(\.name).contains("packetsRead"))
    #expect(rec.checks.allSatisfy { $0.ok })
}

@Test func goldenIsDeterministic() async throws {
    let (bytes, _) = SyntheticCorpus.mixed()
    let a = try await run(bytes).report.json()
    let b = try await run(bytes).report.json()
    #expect(a == b)
    #expect(SyntheticCorpus.mixed().bytes == bytes)
}

@Test func trailerDoesNotChangeResult() async throws {
    let plain = try await run(SyntheticCorpus.mixed().bytes).report.json()
    let trailed = try await run(SyntheticCorpus.withTrailer().bytes).report.json()
    #expect(plain == trailed)
}

// the first fragment has its ports, so it is counted like any packet; a later fragment has none and is dropped
@Test func firstFragmentCountsLaterFragmentIsDropped() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let r = try await run(bytes)
    #expect(r.stats.droppedNoPort == 1)
    #expect(r.stats.skipped == 1)
    // two fragments were read; only the first is in a flow
    let f8 = expected.flow("F8")
    let flow = try #require(r.flows.first { $0.key.remoteAddress == f8.remote && $0.key.remotePort == f8.remotePort })
    #expect(flow.packetsIn + flow.packetsOut == 1)
    #expect(flow.ipBytesIn + flow.ipBytesOut == 124)
    #expect(r.stats.decoded == r.report.totals.packets + r.stats.droppedNoPort)
}

@Test func ipv6FlowIsReported() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let r = try await run(bytes)
    let f6 = expected.flow("F6")
    let flow = try #require(r.flows.first { $0.key.remoteAddress == f6.remote && $0.key.remotePort == 443 })
    #expect(flow.ipBytesIn + flow.ipBytesOut == 1240)
    #expect(flow.packetsIn + flow.packetsOut == 4)
    // the heartbeat flow is IPv6 too
    let f4 = expected.flow("F4")
    #expect(r.flows.contains { $0.key.remoteAddress == f4.remote && $0.ipBytesIn + $0.ipBytesOut == 180 })
}

@Test func goldenCategories() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let c = try await run(bytes).report.categories
    for (name, b) in expected.categoryBytes {
        let line = try #require(c.byCategory[name], "\(name) missing")
        #expect(line.ipBytes == b, "\(name) bytes")
        #expect(line.flows == expected.categoryFlows[name], "\(name) flows")
        #expect(line.packets == expected.categoryPackets[name], "\(name) packets")
        #expect(line.share == Ratio(numerator: b, denominator: expected.ipBytes), "\(name) share")
    }
    #expect(c.rules == expected.ruleBytes)
    #expect(c.movedOutOfAppBytes == expected.movedOutOfAppBytes)
    #expect(c.phoneTrafficShare == Ratio(numerator: expected.phoneTrafficBytes, denominator: expected.ipBytes))
    // no system flow in the corpus: ratio 0 / 0, no value
    #expect(c.systemTopProcessShare == Ratio(numerator: 0, denominator: 0))
    #expect(c.unknownShare == Ratio(numerator: 0, denominator: expected.ipBytes))
}

@Test func categorySharesSumToOne() async throws {
    let (bytes, _) = SyntheticCorpus.mixed()
    let report = try await run(bytes).report
    let shares = report.categories.byCategory.values.compactMap(\.share.value)
    #expect(abs(shares.reduce(0, +) - 1) < 1e-12)
    let check = try #require(report.reconciliation.checks.first { $0.name == "categoryBytes" })
    #expect(check.ok && check.expected == report.totals.ipBytes)
}

@Test func rulesSumToTotal() async throws {
    let (bytes, _) = SyntheticCorpus.mixed()
    let report = try await run(bytes).report
    #expect(report.categories.rules.values.reduce(0, +) == report.totals.ipBytes)
}

@Test func goldenHostnames() async throws {
    let (bytes, expected) = SyntheticCorpus.mixed()
    let r = try await run(bytes)
    let h = r.report.hostnames
    let d = expected.hostnameDenominatorBytes
    // observed names only: sni 6243 of 10065. the dns hint (F6 1240) is in hintShare, not in the headline
    #expect(h.hostnameCoverage == Ratio(numerator: expected.sniBytes, denominator: d))
    #expect(h.hintShare == Ratio(numerator: expected.dnsBytes, denominator: d))
    #expect(h.sniShare == Ratio(numerator: expected.sniBytes, denominator: d))
    #expect(h.dnsShare == Ratio(numerator: expected.dnsBytes, denominator: d))
    #expect(h.unnamedShare.count == 4)
    for (reason, b) in expected.unnamedBytes {
        #expect(h.unnamedShare[reason] == Ratio(numerator: b, denominator: d), "\(reason)")
    }
    #expect(h.midstreamShare == Ratio(numerator: expected.midstreamBytes, denominator: d))
    #expect(h.echShare == Ratio(numerator: expected.echBytes, denominator: d))
    #expect(h.dnsPrecision == Ratio(numerator: expected.dnsPrecisionAgreeBytes, denominator: expected.dnsPrecisionBytes))
    // the denominator is the 443 bytes of app and helper flows; here every 443 flow is app traffic
    #expect(d == expected.port443Bytes)
    // the M1 figure is unchanged
    #expect(h.hostnameCoverageSniOnly == Ratio(numerator: expected.sniNamedBytes, denominator: expected.port443Bytes))
    // per flow: source or reason
    let index = HostnameIndex(r.domains)
    for (label, want) in expected.hostnameOutcome {
        let e = expected.flow(label)
        let flow = try #require(r.flows.first { $0.key.remoteAddress == e.remote && $0.key.remotePort == e.remotePort })
        switch index.outcome(for: flow) {
        case .named(let n): #expect(n.source.rawValue == want, "\(label)")
        case .unnamed(let reason): #expect(reason.rawValue == want, "\(label)")
        }
    }
}

@Test func goldenHints() async throws {
    let (bytes, e) = HintCorpus.build()
    let r = try await run(bytes)
    let h = r.report.hostnames
    let d = e.denominator
    // every flow is app traffic to 443: the denominator is all ip bytes
    #expect(r.report.totals.ipBytes == d)
    #expect(h.sniShare == Ratio(numerator: e.sniBytes, denominator: d))
    #expect(h.dnsShare == Ratio(numerator: 0, denominator: d))
    #expect(h.sameAddressShare == Ratio(numerator: e.sameAddressBytes, denominator: d))
    // the hint is not in the headline figure
    #expect(h.hostnameCoverage == Ratio(numerator: e.sniBytes, denominator: d))
    // hintShare = dns 0 + sameAddress 356 = 356 of 2763
    #expect(h.hintShare == Ratio(numerator: e.sameAddressBytes, denominator: d))
    for (reason, b) in e.unnamedBytes { #expect(h.unnamedShare[reason] == Ratio(numerator: b, denominator: d), "\(reason)") }
    #expect(h.midstreamShare == Ratio(numerator: e.midstreamBytes, denominator: d))
    #expect(h.sameAddressPrecision == Ratio(
        numerator: e.sameAddressPrecisionAgreeBytes, denominator: e.sameAddressPrecisionBytes))
    #expect(h.dnsPrecision == Ratio(numerator: 0, denominator: 0))
    #expect(r.report.reconciliation.ok)
    #expect(r.stats.handshakeGaveUp["shortHeaderFirst"] == e.shortHeaderFirst)
    let index = HostnameIndex(r.domains, flows: r.flows)
    for (label, want) in e.outcome {
        let flow = try #require(r.flows.first {
            $0.key.remoteAddress == .v4(HintCorpus.remote(label)) && $0.ipBytesIn + $0.ipBytesOut == e.bytes[label]
        }, "\(label)")
        switch index.outcome(for: flow) {
        case .named(let n): #expect(n.source.rawValue == want, "\(label)")
        case .unnamed(let reason): #expect(reason.rawValue == want, "\(label)")
        }
        // the quic flows that began with a short header carry the flag
        #expect(flow.startedMidstream == (label == "H2" || label == "H3"), "\(label) midstream")
    }
    let hinted = try #require(r.flows.first { $0.ipBytesIn + $0.ipBytesOut == e.bytes["H2"] })
    #expect(index.resolve(hinted)?.name == "named.tiktok.test")
}

@Test func goldenHostnameReasonsAddUp() async throws {
    let (bytes, _) = SyntheticCorpus.mixed()
    let report = try await run(bytes).report
    let h = report.hostnames
    let sum = [h.sniShare, h.dnsShare, h.sameAddressShare].compactMap(\.value).reduce(0, +) + h.unnamedShare.values.compactMap(\.value).reduce(0, +)
    #expect(abs(sum - 1) < 1e-12)
    let check = try #require(report.reconciliation.checks.first { $0.name == "hostnameReasons" })
    #expect(check.ok && check.expected == 10065)
}
