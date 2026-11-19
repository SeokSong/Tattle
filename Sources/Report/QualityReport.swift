import Foundation

public struct ReportOptions: Sendable {
    /// adds process names to the report; off by default so a report never names anything
    public var detail = false
    public var watchVersion = "dev"

    public init(detail: Bool = false, watchVersion: String = "dev") {
        self.detail = detail
        self.watchVersion = watchVersion
    }
}

/// counters from the pipeline, copied so Report does not import Pipeline
public struct PipelineSnapshot: Sendable, Equatable {
    public var packets: Int, decoded: Int, skipped: Int, malformed: Int, droppedNoPort: Int

    public init(packets: Int, decoded: Int, skipped: Int, malformed: Int, droppedNoPort: Int) {
        self.packets = packets
        self.decoded = decoded
        self.skipped = skipped
        self.malformed = malformed
        self.droppedNoPort = droppedNoPort
    }
}

public struct QualityReport: Codable, Sendable, Equatable {
    public struct Totals: Codable, Sendable, Equatable {
        public var flows: Int
        public var packets: Int
        public var ipBytes: Int
    }

    public struct Attribution: Codable, Sendable, Equatable {
        public var attributedShare: Ratio
        public var noProcessShare: Ratio
        public var mixedFlowShare: Ratio
    }

    public struct Hostnames: Codable, Sendable, Equatable {
        /// M1 view: denominator is all flows with remote port 443, any category, any serverName.
        /// unchanged since M1 so the baseline stays comparable
        public var hostnameCoverageSniOnly: Ratio
        /// 5.1 fields. denominator of all of them: bytes of `appTraffic` (app + helper) flows with remote port 443
        /// observed names only: bytes named by the connection itself (`sni`), so it equals `sniShare`.
        /// hints never count toward it
        public var hostnameCoverage: Ratio
        /// bytes named by the flow's own server name (not ech)
        public var sniShare: Ratio
        /// bytes named only by a dns answer from this session
        public var dnsShare: Ratio
        /// bytes named only by another flow's sni name (same remote address, same app). a hint, never in
        /// `hostnameCoverage`
        public var sameAddressShare: Ratio
        /// `dnsShare` + `sameAddressShare`: bytes whose name is a hint, not observed in the connection
        public var hintShare: Ratio
        /// bytes per `UnnamedReason` raw value; all four keys always present
        public var unnamedShare: [String: Ratio]
        /// flows that started before the capture (tcp without a syn, quic starting with a short header)
        public var midstreamShare: Ratio
        /// flows with `echSeen`
        public var echShare: Ratio
        /// of bytes with an sni name and a dns match, bytes where the dns name equals the sni name
        public var dnsPrecision: Ratio
        /// of bytes with an sni name and a same-address match, bytes where the other flow's name equals the sni name
        public var sameAddressPrecision: Ratio

        public static let empty = Ratio(numerator: 0, denominator: 0)

        public init(
            hostnameCoverageSniOnly: Ratio, hostnameCoverage: Ratio = empty, sniShare: Ratio = empty,
            dnsShare: Ratio = empty, sameAddressShare: Ratio = empty, hintShare: Ratio = empty, unnamedShare: [String: Ratio] = [:], midstreamShare: Ratio = empty,
            echShare: Ratio = empty, dnsPrecision: Ratio = empty,
            sameAddressPrecision: Ratio = empty
        ) {
            self.hostnameCoverageSniOnly = hostnameCoverageSniOnly
            self.hostnameCoverage = hostnameCoverage
            self.sniShare = sniShare
            self.dnsShare = dnsShare
            self.unnamedShare = unnamedShare
            self.midstreamShare = midstreamShare
            self.echShare = echShare
            self.dnsPrecision = dnsPrecision
            self.sameAddressShare = sameAddressShare
            self.hintShare = hintShare
            self.sameAddressPrecision = sameAddressPrecision
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var name: String
        public var expected: Int
        public var actual: Int
        public var ok: Bool
    }

    public struct Reconciliation: Codable, Sendable, Equatable {
        public var ok: Bool
        public var checks: [Check]
    }

    public struct ProcessLine: Codable, Sendable, Equatable {
        public var name: String
        public var flows: Int
        public var ipBytes: Int
    }

    public struct CategoryLine: Codable, Sendable, Equatable {
        public var flows: Int
        public var packets: Int
        public var ipBytes: Int
        /// ipBytes over totals.ipBytes
        public var share: Ratio
    }

    /// traffic categories from `Classifier`; keys are `TrafficCategory` raw values, all six always present
    public struct Categories: Codable, Sendable, Equatable {
        public var byCategory: [String: CategoryLine]
        /// bytes per rule name; only rules that matched a flow appear
        public var rules: [String: Int]
        /// bytes M1 attribution called app, on-behalf-of or system that are now deviceLink or localNetwork
        public var movedOutOfAppBytes: [String: Int]
        /// app + helper + system + unknown bytes over all bytes
        public var phoneTrafficShare: Ratio
        /// the same figure as `byCategory["unknown"].share`, named as in the vocabulary
        public var unknownShare: Ratio
        /// largest single system process bytes over all `system` bytes; the name is only in `detail`
        public var systemTopProcessShare: Ratio

        public static let empty = Categories(
            byCategory: [:], rules: [:], movedOutOfAppBytes: [:],
            phoneTrafficShare: Ratio(numerator: 0, denominator: 0),
            unknownShare: Ratio(numerator: 0, denominator: 0),
            systemTopProcessShare: Ratio(numerator: 0, denominator: 0))
    }

    public struct UnnamedFlowLine: Codable, Sendable, Equatable {
        public var reason: String
        public var port: Int
        public var transport: String
        public var category: String
        public var process: String
        public var ipBytes: Int
    }

    public struct Detail: Codable, Sendable, Equatable {
        public var topProcesses: [ProcessLine]
        /// `system` category bytes by process display name
        public var systemProcesses: [ProcessLine]
        /// `deviceLink` category bytes by process display name
        public var deviceLinkProcesses: [ProcessLine]
        public var systemTopProcess: String?
        /// the 10 largest unnamed app-traffic 443 flows; no address, no hostname
        public var topUnnamed: [UnnamedFlowLine]

        public init(
            topProcesses: [ProcessLine], systemProcesses: [ProcessLine] = [],
            deviceLinkProcesses: [ProcessLine] = [], systemTopProcess: String? = nil,
            topUnnamed: [UnnamedFlowLine] = []
        ) {
            self.topUnnamed = topUnnamed
            self.topProcesses = topProcesses
            self.systemProcesses = systemProcesses
            self.deviceLinkProcesses = deviceLinkProcesses
            self.systemTopProcess = systemTopProcess
        }
    }

    /// session statistics (6.2): numbers only. present when the report was given `SessionStats`
    public struct Session: Codable, Sendable, Equatable {
        public var gapCount: Int
        public var maxGapSeconds: Double
        public var saveFailures: Int
        public var unsavedFlows: Int
        /// nil (key absent) when unknown
        public var kernelDropped: Int?
    }

    public var reportVersion: Int
    public var watchVersion: String
    public var totals: Totals
    public var byInterface: [String: Int]
    public var attribution: Attribution
    public var hostnames: Hostnames
    public var reconciliation: Reconciliation
    public var detail: Detail?
    /// added in 4.2; reportVersion stays 1 because every earlier key is unchanged
    public var categories: Categories = .empty
    /// added in 6.2; absent when no session statistics were given
    public var session: Session?

    /// sorted keys, pretty printed: the same report always gives the same bytes
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
