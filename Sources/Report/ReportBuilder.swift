import Attribution
import Domains
import Flows
import Foundation

// pure logic: no clock, no files, no processes. results do not depend on input order.
public enum ReportBuilder {
    public static func build(
        flows: [Flow], domains: [DomainObservation], pipeline: PipelineSnapshot?,
        options: ReportOptions = ReportOptions()
    ) -> QualityReport {
        func bytes(_ f: Flow) -> Int { f.ipBytesIn + f.ipBytesOut }
        func packets(_ f: Flow) -> Int { f.packetsIn + f.packetsOut }

        let totalBytes = flows.reduce(0) { $0 + bytes($1) }
        let totalPackets = flows.reduce(0) { $0 + packets($1) }

        var byInterface: [String: Int] = [:]
        for f in flows { byInterface[f.interface, default: 0] += bytes(f) }

        var attributed = 0, noProcess = 0, mixed = 0
        var port443 = 0, sni443 = 0
        var processes: [String: (flows: Int, bytes: Int)] = [:]
        var categoryTotals: [TrafficCategory: (flows: Int, packets: Int, bytes: Int)] = [:]
        var ruleBytes: [String: Int] = [:]
        var moved: [TrafficCategory: Int] = [.deviceLink: 0, .localNetwork: 0]
        var systemProcesses: [String: (flows: Int, bytes: Int)] = [:]
        var deviceLinkProcesses: [String: (flows: Int, bytes: Int)] = [:]
        for f in flows {
            let b = bytes(f)
            let result = Attributor.attribute(f.tally)
            if result.primary != .unknown { attributed += b }
            // tally alone, before any category rule
            if f.tally.keys.allSatisfy({ $0 == .none }) { noProcess += b }
            if result.mixed { mixed += b }
            if f.key.remotePort == 443 {
                port443 += b
                if let name = f.serverName, !name.isEmpty { sni443 += b }
            }

            let c = Classifier.classify(f)
            var t = categoryTotals[c.category, default: (0, 0, 0)]
            t.flows += 1
            t.packets += packets(f)
            t.bytes += b
            categoryTotals[c.category] = t
            ruleBytes[c.rule, default: 0] += b
            if c.category == .deviceLink || c.category == .localNetwork, result.primary != .unknown {
                moved[c.category, default: 0] += b
            }
            // names for the system share are needed even without detail, to find the largest one
            if c.category == .system {
                var line = systemProcesses[processName(result.primary), default: (0, 0)]
                line.flows += 1
                line.bytes += b
                systemProcesses[processName(result.primary)] = line
            } else if c.category == .deviceLink {
                let name = result.topRow?.processName.map(ProcessNames.displayName) ?? "(no process info)"
                var line = deviceLinkProcesses[name, default: (0, 0)]
                line.flows += 1
                line.bytes += b
                deviceLinkProcesses[name] = line
            }

            if options.detail {
                var line = processes[processName(result.primary), default: (0, 0)]
                line.flows += 1
                line.bytes += b
                processes[processName(result.primary)] = line
            }
        }

        var checks: [QualityReport.Check] = []
        func check(_ name: String, _ expected: Int, _ actual: Int) {
            checks.append(.init(name: name, expected: expected, actual: actual, ok: expected == actual))
        }
        if let p = pipeline {
            check("packetsRead", p.packets, p.decoded + p.skipped + p.malformed)
            check("decodedAccounted", p.decoded, totalPackets + p.droppedNoPort)
        }
        check("categoryBytes", totalBytes, categoryTotals.values.reduce(0) { $0 + $1.bytes })
        check("interfaceBytes", totalBytes, byInterface.values.reduce(0, +))
        // expected = flow count, actual = flows whose lastSeen is not before firstSeen
        check("flowTimes", flows.count, flows.filter { $0.lastSeen >= $0.firstSeen }.count)

        func sortedLines(_ m: [String: (flows: Int, bytes: Int)]) -> [QualityReport.ProcessLine] {
            m.map { QualityReport.ProcessLine(name: $0.key, flows: $0.value.flows, ipBytes: $0.value.bytes) }
                .sorted { $0.ipBytes != $1.ipBytes ? $0.ipBytes > $1.ipBytes : $0.name < $1.name }
        }
        let systemLines = sortedLines(systemProcesses)

        var detail: QualityReport.Detail?
        if options.detail {
            detail = .init(
                topProcesses: Array(sortedLines(processes).prefix(20)),
                systemProcesses: Array(systemLines.prefix(20)),
                deviceLinkProcesses: Array(sortedLines(deviceLinkProcesses).prefix(20)),
                systemTopProcess: systemLines.first?.name)
        }

        var byCategory: [String: QualityReport.CategoryLine] = [:]
        for cat in TrafficCategory.allCases {
            let t = categoryTotals[cat] ?? (0, 0, 0)
            byCategory[cat.rawValue] = .init(
                flows: t.flows, packets: t.packets, ipBytes: t.bytes,
                share: Ratio(numerator: t.bytes, denominator: totalBytes))
        }
        let phoneBytes = categoryTotals.filter { $0.key.isPhoneTraffic }.values.reduce(0) { $0 + $1.bytes }
        let unknownBytes = categoryTotals[.unknown]?.bytes ?? 0
        let categories = QualityReport.Categories(
            byCategory: byCategory, rules: ruleBytes,
            movedOutOfAppBytes: Dictionary(uniqueKeysWithValues: moved.map { ($0.key.rawValue, $0.value) }),
            phoneTrafficShare: Ratio(numerator: phoneBytes, denominator: totalBytes),
            unknownShare: Ratio(numerator: unknownBytes, denominator: totalBytes),
            systemTopProcessShare: Ratio(
                numerator: systemLines.first?.ipBytes ?? 0, denominator: categoryTotals[.system]?.bytes ?? 0))

        return QualityReport(
            reportVersion: 1, watchVersion: options.watchVersion,
            totals: .init(flows: flows.count, packets: totalPackets, ipBytes: totalBytes),
            byInterface: byInterface,
            attribution: .init(
                attributedShare: Ratio(numerator: attributed, denominator: totalBytes),
                noProcessShare: Ratio(numerator: noProcess, denominator: totalBytes),
                mixedFlowShare: Ratio(numerator: mixed, denominator: totalBytes)),
            hostnames: .init(hostnameCoverageSniOnly: Ratio(numerator: sni443, denominator: port443)),
            reconciliation: .init(ok: checks.allSatisfy(\.ok), checks: checks),
            detail: detail, categories: categories)
    }

    private static func processName(_ a: AppAttribution) -> String {
        switch a {
        case .app(let name, _): return ProcessNames.displayName(name)
        case .onBehalfOf(let app, _): return ProcessNames.displayName(app)
        case .system(let name): return ProcessNames.displayName(name)
        case .unknown: return "(no process info)"
        }
    }
}
