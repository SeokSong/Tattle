import Attribution
import Companies
import Domains
import Flows
import Foundation

/// a metric printed as numerator, denominator and value; value is absent when the denominator is 0.
/// the same shape as the quality report's `Ratio`, kept here because Summary never imports Report
public struct CoverageRatio: Codable, Equatable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var value: Double? { denominator > 0 ? Double(numerator) / Double(denominator) : nil }

    private enum CodingKeys: String, CodingKey { case numerator, denominator, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        numerator = try c.decode(Int.self, forKey: .numerator)
        denominator = try c.decode(Int.self, forKey: .denominator)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(numerator, forKey: .numerator)
        try c.encode(denominator, forKey: .denominator)
        if let value { try c.encode(value, forKey: .value) }
    }
}

/// how much of a capture's traffic the company sources can name. numbers and keys only: no hostname,
/// no company name and no app name is ever in it, so it can be committed as a band file
public struct CoverageReport: Codable, Equatable, Sendable {
    /// the sources the classifier was allowed to use, by raw name
    public var sources: [String]
    /// the curated list version and checksum when `curated` was used (the checksum is a public dataset hash)
    public var curatedVersion: String?
    public var curatedSHA256: String?
    /// ratios by key: `companyCoverage`, `companyCoverageOfNamedBytes`, `domainCoverage`, `labelSourceShare.<source>`
    public var metrics: [String: CoverageRatio]
    /// plain counts by key: `namedCompanies`, `adTrackCompanies`, `possibleCompanies`, `unmatched.connections`
    public var counts: [String: Int]

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    /// printed as "numerator / denominator = value", the order the owner reads them in
    public func text() -> String {
        var lines = ["Company coverage (sources: \(sources.joined(separator: ", ")))"]
        if let version = curatedVersion { lines.append("curated list \(version)") }
        for key in metrics.keys.sorted() {
            guard let r = metrics[key] else { continue }
            let value = r.value.map { String(format: "%.1f%%", $0 * 100) } ?? "no value"
            lines.append("  \(key): \(r.numerator) / \(r.denominator) = \(value)")
        }
        for key in counts.keys.sorted() { lines.append("  \(key): \(counts[key] ?? 0)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// one registrable domain that was named in a connection but not identified. for local curation
/// guidance only: it holds a name, so it is never part of `CoverageReport`
public struct UnmatchedDomain: Equatable, Sendable {
    public let domain: String
    public let flows: Int
    public let bytes: Int
}

public struct CoverageResult: Sendable {
    public let report: CoverageReport
    /// most bytes first, then name
    public let unmatched: [UnmatchedDomain]
}

public enum Coverage {
    /// the connections the metrics are about: remote port 443, the same base as the quality report's
    /// `hostnameCoverageSniOnly`
    public static let port = 443

    /// computed at read time from flows already saved; never on the packet path. only a name seen in the
    /// connection itself (`sni`, not behind ech) counts as named. a name from a DNS answer or from another
    /// connection is a hint: it adds nothing to a numerator and its flow stays in the denominators.
    /// `sources` is the order the classifier may use; `[.curated]` is the frozen baseline
    public static func build(
        flows: [Flow], index: HostnameIndex, classifier: CompanyClassifier = CompanyClassifier(),
        sources: [LabelSource] = [.curated]
    ) -> CoverageResult {
        var cache = LabelCache(classify: { classifier.classify(hostname: $0, order: sources) })
        var allBytes = 0, namedBytes = 0, matchedBytes = 0, unmatchedConnections = 0
        // confirmed hostnames, grouped by registrable domain (or the name itself when it has none)
        var hostnamesByDomain: [String: Set<String>] = [:]
        var unmatchedByDomain: [String: (flows: Int, bytes: Int)] = [:]
        var confirmedParents = Set<String>(), adTrackParents = Set<String>(), hintedParents = Set<String>()

        for flow in flows where flow.key.remotePort == port {
            let b = flow.ipBytesIn + flow.ipBytesOut
            allBytes += b
            guard let result = FlowLabels.label(for: flow, index: index, cache: &cache) else {
                unmatchedConnections += 1
                continue
            }
            let label = result.label
            if result.isPossible {
                unmatchedConnections += 1
                if label.isMatched, let parent = label.parent ?? label.company { hintedParents.insert(parent) }
                continue
            }
            namedBytes += b
            let key = label.registrableDomain ?? label.hostname
            hostnamesByDomain[key, default: []].insert(label.hostname)
            if label.isMatched {
                matchedBytes += b
                if let parent = label.parent ?? label.company {
                    confirmedParents.insert(parent)
                    if label.category.isAdvertisingOrTracking { adTrackParents.insert(parent) }
                }
            } else {
                unmatchedConnections += 1
                var entry = unmatchedByDomain[key, default: (0, 0)]
                entry.flows += 1
                entry.bytes += b
                unmatchedByDomain[key] = entry
            }
        }

        // a registrable domain is identified only when every confirmed name under it is identified:
        // a half-identified domain stays in the denominator
        func identified(_ names: Set<String>, by source: LabelSource?) -> Bool {
            names.allSatisfy { name in
                if let source { return classifier.label(hostname: name, from: source).isMatched }
                return cache.label(for: name).isMatched
            }
        }
        let domainCount = hostnamesByDomain.count
        let identifiedDomains = hostnamesByDomain.values.filter { identified($0, by: nil) }.count

        var metrics: [String: CoverageRatio] = [
            "companyCoverage": CoverageRatio(numerator: matchedBytes, denominator: allBytes),
            "companyCoverageOfNamedBytes": CoverageRatio(numerator: matchedBytes, denominator: namedBytes),
            "domainCoverage": CoverageRatio(numerator: identifiedDomains, denominator: domainCount),
        ]
        // an imported report's owner string is not in a capture, so that source has no capture share
        for source in sources where source != .appleOwner && source != .none {
            let byThisSource = hostnamesByDomain.values.filter { identified($0, by: source) }.count
            metrics["labelSourceShare.\(source.rawValue)"] =
                CoverageRatio(numerator: byThisSource, denominator: identifiedDomains)
        }

        let counts: [String: Int] = [
            "namedCompanies": confirmedParents.count,
            "adTrackCompanies": adTrackParents.count,
            "possibleCompanies": hintedParents.subtracting(confirmedParents).count,
            "unmatched.connections": unmatchedConnections,
        ]
        let curatedUsed = sources.contains(.curated)
        let report = CoverageReport(
            sources: sources.map(\.rawValue),
            curatedVersion: curatedUsed ? classifier.curated.version : nil,
            curatedSHA256: curatedUsed ? classifier.curated.sha256 : nil,
            metrics: metrics, counts: counts)
        let unmatched = unmatchedByDomain
            .map { UnmatchedDomain(domain: $0.key, flows: $0.value.flows, bytes: $0.value.bytes) }
            .sorted { ($0.bytes, $1.domain) > ($1.bytes, $0.domain) }
        return CoverageResult(report: report, unmatched: unmatched)
    }
}
