import Foundation

/// one name the two sources of a pair answered differently for, or that only the second answered.
/// local use only: it holds real names when built from a real report, so it is never printed or committed
public struct AgreementRow: Sendable, Equatable {
    public enum Kind: String, Sendable { case different, onlySecond }
    public let kind: Kind
    public let domain: String
    public let firstParent: String?
    public let firstCategory: CompanyCategory?
    public let secondOwner: String?
    public let secondParent: String?
}

/// how two sources agree over a set of names (milestone 3, OD2). each source classifies every name on its
/// own and never sees the other. counts only: no names. names with an IP address are excluded and counted
public struct AgreementMatrix: Sendable, Equatable {
    public let first: LabelSource
    public let second: LabelSource
    /// names with a name to classify (IP addresses excluded)
    public var domains = 0
    public var ipAddresses = 0
    public var onlyFirst = 0
    public var onlySecond = 0
    public var bothSame = 0
    public var bothDifferent = 0
    public var neither = 0
    /// of `bothSame`: the same only because of an alias row
    public var sameThroughAlias = 0
    /// of `bothDifferent`: the Apple owner is a CDN operator (the precedence exception would skip it)
    public var differentCDNOwner = 0
    /// of `onlySecond`: the Apple owner is a CDN operator
    public var onlySecondCDNOwner = 0

    public init(first: LabelSource, second: LabelSource) {
        self.first = first
        self.second = second
    }

    /// the same counts seen from the other source: only-first and only-second swap, the rest stay
    public var swapped: AgreementMatrix {
        var m = AgreementMatrix(first: second, second: first)
        m.domains = domains
        m.ipAddresses = ipAddresses
        m.onlyFirst = onlySecond
        m.onlySecond = onlyFirst
        m.bothSame = bothSame
        m.bothDifferent = bothDifferent
        m.neither = neither
        m.sameThroughAlias = sameThroughAlias
        m.differentCDNOwner = differentCDNOwner
        m.onlySecondCDNOwner = 0
        return m
    }

    /// numbers only
    public func text() -> String {
        [
            "Agreement of \(first.rawValue) and \(second.rawValue), each classifying on its own",
            "domains with a name: \(domains)",
            "IP addresses excluded: \(ipAddresses)",
            "\(first.rawValue) only: \(onlyFirst)",
            "\(second.rawValue) only: \(onlySecond)",
            "both, same parent: \(bothSame)",
            "both, different parent: \(bothDifferent)",
            "neither: \(neither)",
            "same parent only through an alias: \(sameThroughAlias)",
            "different parent, owner is a CDN operator: \(differentCDNOwner)",
            "\(second.rawValue) only, owner is a CDN operator: \(onlySecondCDNOwner)",
        ].joined(separator: "\n") + "\n"
    }
}

public enum Agreement {
    /// classifies each name with `first` alone and `second` alone and counts the pairs. `observations` is each
    /// distinct name with the owner string Apple gave it, if any. returns the counts and the local rows (every
    /// disagreement, and every name only Apple named)
    public static func measure(
        _ observations: [(domain: String, appleOwner: String?)], classifier: CompanyClassifier,
        first: LabelSource = .curated, second: LabelSource = .appleOwner
    ) -> (matrix: AgreementMatrix, rows: [AgreementRow]) {
        var matrix = AgreementMatrix(first: first, second: second)
        var rows: [AgreementRow] = []
        let aliases = classifier.appleOwners
        func parent(_ label: CompanyLabel, _ source: LabelSource) -> String? {
            source == .appleOwner ? label.company.map(aliases.comparableParent(forOwner:)) : label.parent
        }
        for (domain, owner) in observations {
            guard !isIPAddress(domain) else {
                matrix.ipAddresses += 1
                continue
            }
            matrix.domains += 1
            let a = classifier.label(hostname: domain, from: first, appleOwner: owner)
            let b = classifier.label(hostname: domain, from: second, appleOwner: owner)
            let isCDN = second == .appleOwner && b.isMatched && b.company.map(aliases.isCDNOperator) == true
            switch (a.isMatched, b.isMatched) {
            case (false, false): matrix.neither += 1
            case (true, false): matrix.onlyFirst += 1
            case (false, true):
                matrix.onlySecond += 1
                if isCDN { matrix.onlySecondCDNOwner += 1 }
                rows.append(AgreementRow(
                    kind: .onlySecond, domain: a.hostname, firstParent: nil, firstCategory: nil,
                    secondOwner: b.company, secondParent: parent(b, second)))
            case (true, true):
                let pa = parent(a, first), pb = parent(b, second)
                if let pa, let pb, pa.lowercased() == pb.lowercased() {
                    matrix.bothSame += 1
                    if second == .appleOwner, let owner = b.company,
                       owner.trimmingCharacters(in: .whitespaces).lowercased() != pa.lowercased() { matrix.sameThroughAlias += 1 }
                } else {
                    matrix.bothDifferent += 1
                    if isCDN { matrix.differentCDNOwner += 1 }
                    rows.append(AgreementRow(
                        kind: .different, domain: a.hostname, firstParent: pa, firstCategory: a.category,
                        secondOwner: b.company, secondParent: pb))
                }
            }
        }
        rows.sort { ($0.kind.rawValue, $0.domain) < ($1.kind.rawValue, $1.domain) }
        return (matrix, rows)
    }
}
