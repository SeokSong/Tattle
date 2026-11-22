import Attribution
import Companies
import Flows
import Foundation

/// the company label of one flow and how the name behind it was learned
public struct FlowLabel: Sendable, Equatable {
    public let label: CompanyLabel
    public let evidence: EvidenceKind

    /// true when the label may be wrong because it rests on a hint, not on the connection's own name
    public var isPossible: Bool { evidence == .captureHint }
}

/// memoises the company label per distinct hostname. a value type owned by one refresh: build it,
/// pass it `inout` while building rows, drop it. nothing is stored or shared between refreshes
public struct LabelCache: Sendable {
    private let classify: @Sendable (String) -> CompanyLabel
    private var byHostname: [String: CompanyLabel] = [:]
    /// how many times the classifier was asked; tests read this
    public private(set) var classifications = 0

    public init(classifier: CompanyClassifier = CompanyClassifier()) {
        self.classify = { classifier.classify(hostname: $0) }
    }

    /// a seam for tests: any function from hostname to label
    public init(classify: @escaping @Sendable (String) -> CompanyLabel) {
        self.classify = classify
    }

    public mutating func label(for hostname: String) -> CompanyLabel {
        if let hit = byHostname[hostname] { return hit }
        classifications += 1
        let label = classify(hostname)
        byHostname[hostname] = label
        return label
    }
}

public enum FlowLabels {
    /// nil when the flow has no usable name: the reason it has none is shown instead, as before. an
    /// ech flow is never labelled from the outer name. an unmatched name gives a label with source
    /// `.none` (shown as "Not identified"), never a guess
    public static func label(for flow: Flow, index: HostnameIndex, cache: inout LabelCache) -> FlowLabel? {
        guard case .named(let resolved) = index.outcome(for: flow), !resolved.echPresent else { return nil }
        let evidence: EvidenceKind = resolved.source == .sni ? .captureName : .captureHint
        return FlowLabel(label: cache.label(for: resolved.name), evidence: evidence)
    }
}
