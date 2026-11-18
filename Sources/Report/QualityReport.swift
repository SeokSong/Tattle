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
        /// M1 view: denominator is all flows with remote port 443 (5.1 narrows it to app traffic)
        public var hostnameCoverageSniOnly: Ratio
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

    public struct Detail: Codable, Sendable, Equatable {
        public var topProcesses: [ProcessLine]
        /// `system` category bytes by process display name
        public var systemProcesses: [ProcessLine]
        /// `deviceLink` category bytes by process display name
        public var deviceLinkProcesses: [ProcessLine]
        public var systemTopProcess: String?

        public init(
            topProcesses: [ProcessLine], systemProcesses: [ProcessLine] = [],
            deviceLinkProcesses: [ProcessLine] = [], systemTopProcess: String? = nil
        ) {
            self.topProcesses = topProcesses
            self.systemProcesses = systemProcesses
            self.deviceLinkProcesses = deviceLinkProcesses
            self.systemTopProcess = systemTopProcess
        }
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

    /// sorted keys, pretty printed: the same report always gives the same bytes
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
