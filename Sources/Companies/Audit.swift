import Foundation

// the accuracy audit of the company classification (milestone 3, OD13). it compares our parent company for a
// domain with two independent references, a tracker entity map and the organisation in the server's tls
// certificate, and counts agreement. pure: reference data comes in as values, nothing is fetched or read from
// disk here, and the printed text holds numbers only. Foundation only

/// one thing we claim: a registrable domain, the parent company we name for it and its category
public struct AuditSubject: Sendable, Equatable, Hashable {
    public let domain: String
    public let parent: String
    public let company: String?
    public let category: CompanyCategory

    public init(domain: String, parent: String, company: String? = nil, category: CompanyCategory) {
        self.domain = domain
        self.parent = parent
        self.company = company
        self.category = category
    }
}

/// what the entity map says about a domain: the entity and every other name it is known by
public struct EntityEntry: Sendable, Equatable {
    public let entity: String
    public let names: [String]

    public init(entity: String, names: [String]) {
        self.entity = entity
        self.names = names
    }
}

/// what a certificate said. a domain with no cached answer is simply absent from the map
public enum CertAnswer: Sendable, Equatable {
    /// the subject has an organisation (an OV or EV certificate)
    case organisation(String)
    /// the certificate has no organisation (a DV certificate): not an answer, so never a disagreement
    case noOrganisation
    /// the fetch failed or timed out
    case failed
}

/// the two references, keyed by lowercase domain
public struct ReferenceMaps: Sendable {
    public var entities: [String: EntityEntry]
    public var certificates: [String: CertAnswer]

    public init(entities: [String: EntityEntry] = [:], certificates: [String: CertAnswer] = [:]) {
        self.entities = entities
        self.certificates = certificates
    }

    /// the domain-to-entity map as the Tracker Radar publishes it (`domain_map.json`): an object keyed by
    /// domain whose values have `entityName`, `aliases` and `displayName`. other keys are ignored
    public static func parseEntityMap(_ data: Data) throws -> [String: EntityEntry] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: EntityEntry] = [:]
        out.reserveCapacity(object.count)
        for (domain, value) in object {
            guard let entry = value as? [String: Any], let entity = entry["entityName"] as? String else { continue }
            var names = [entity]
            if let display = entry["displayName"] as? String { names.append(display) }
            if let aliases = entry["aliases"] as? [String] { names.append(contentsOf: aliases) }
            out[domain.lowercased()] = EntityEntry(entity: entity, names: names)
        }
        return out
    }

    /// the certificate cache: one line per domain, tab separated: domain, `org` and the organisation, or
    /// `none`, or `fail`. a later line replaces an earlier one. unreadable lines are skipped
    public static func parseCertificateCache(_ text: String) -> [String: CertAnswer] {
        var out: [String: CertAnswer] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty else { continue }
            let domain = f[0].lowercased()
            switch f[1] {
            case "org" where f.count >= 3 && !f[2].trimmingCharacters(in: .whitespaces).isEmpty:
                out[domain] = .organisation(f[2].trimmingCharacters(in: .whitespaces))
            case "none": out[domain] = .noOrganisation
            case "fail": out[domain] = .failed
            default: continue
            }
        }
        return out
    }
}

/// public company names as a reference writes them, mapped to the parent name we use ("Google LLC" is
/// Alphabet). the key ignores case, punctuation and legal suffixes, the same way names are compared
public struct ReferenceAliases: Sendable {
    private let byKey: [String: String]

    public static let header = ["referenceName", "parent", "note"]
    public var count: Int { byKey.count }

    public init(pairs: [(name: String, parent: String)] = []) {
        var map: [String: String] = [:]
        for (name, parent) in pairs { map[Audit.normalise(name)] = parent }
        byKey = map
    }

    /// parses `reference-aliases.tsv`: a header line, then name, parent, note. strict about the shape
    public init(parsing text: String) throws {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw ReferenceAliasError.missingHeader
        }
        var pairs: [(name: String, parent: String)] = []
        for (index, line) in lines.enumerated().dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == Self.header.count else { throw ReferenceAliasError.wrongColumnCount(line: index + 1) }
            guard !f.contains(where: { $0.isEmpty }) else { throw ReferenceAliasError.emptyField(line: index + 1) }
            pairs.append((f[0], f[1]))
        }
        self.init(pairs: pairs)
    }

    /// the aliases of the bundled file together with the owner aliases Apple's strings use
    public static func loadBundled(appleOwners: AppleOwnerTable = .bundled) -> ReferenceAliases {
        var pairs = appleOwners.rows.map { (name: $0.owner, parent: $0.parent) }
        if let url = DatasetManifest.resourceURL("reference-aliases.tsv"),
           let text = try? String(contentsOf: url, encoding: .utf8), let table = try? ReferenceAliases(parsing: text) {
            pairs += table.byKey.map { (name: $0.key, parent: $0.value) }
        }
        return ReferenceAliases(pairs: pairs)
    }

    public func parent(forReferenceName name: String) -> String? { byKey[Audit.normalise(name)] }
}

public enum ReferenceAliasError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
}

public enum AuditOutcome: String, Sendable {
    /// at least one reference names the same company
    case confirmed
    /// no reference agrees and at least one names a different company
    case contradicted
    /// no reference gave an answer
    case unverifiable
}

/// what one reference said about one subject
public enum ReferenceVerdict: String, Sendable {
    case agrees, differs, noAnswer
}

/// local use only: it holds real names when built from real data
public struct AuditRow: Sendable, Equatable {
    public let subject: AuditSubject
    public let entity: ReferenceVerdict
    public let certificate: ReferenceVerdict
    /// the entity the entity map names, when it has one
    public let entityName: String?
    /// the certificate organisation, when there is one
    public let organisation: String?

    public var outcome: AuditOutcome {
        if entity == .agrees || certificate == .agrees { return .confirmed }
        if entity == .differs || certificate == .differs { return .contradicted }
        return .unverifiable
    }
}

/// the counts of one stratum. numbers only
public struct AuditStratum: Sendable, Equatable {
    public let name: String
    public var n = 0
    public var confirmed = 0
    public var contradicted = 0
    public var unverifiable = 0
    /// of `confirmed`: both references agree, only the entity map, only the certificate
    public var confirmedByBoth = 0
    public var confirmedByEntityOnly = 0
    public var confirmedByCertificateOnly = 0
    /// of `confirmed`: the other reference named a different company
    public var confirmedWhileOtherDiffers = 0
    /// rows with an entity map answer, with a certificate organisation
    public var withEntityAnswer = 0
    public var withOrganisation = 0
    /// one-sided 95% upper bound of the contradiction rate among verifiable rows; nil when there are none
    public var upperBound: Double?

    public var verifiable: Int { confirmed + contradicted }
    /// confirmed over verifiable; nil when nothing is verifiable
    public var agreementRate: Double? { verifiable > 0 ? Double(confirmed) / Double(verifiable) : nil }

    public init(name: String) { self.name = name }

    public func text() -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "no value" }
        return [
            "stratum \(name)",
            "  n: \(n)",
            "  confirmed: \(confirmed) (both references: \(confirmedByBoth), entity map only: \(confirmedByEntityOnly), certificate only: \(confirmedByCertificateOnly), other reference differed: \(confirmedWhileOtherDiffers))",
            "  contradicted: \(contradicted)",
            "  unverifiable: \(unverifiable)",
            "  with an entity map answer: \(withEntityAnswer)",
            "  with a certificate organisation: \(withOrganisation)",
            "  agreement among verifiable (\(verifiable)): \(pct(agreementRate))",
            "  contradiction rate, one-sided 95% upper bound: \(pct(upperBound))",
        ].joined(separator: "\n")
    }
}

public enum Audit {
    /// the confidence of the one-sided bound
    public static let confidence = 0.95

    // MARK: names

    private static let legalWords: Set<String> = [
        "inc", "incorporated", "llc", "ltd", "limited", "gmbh", "corp", "corporation", "co", "company", "sa", "ag",
        "plc", "bv", "nv", "pty", "lp", "llp", "srl", "sas", "oy", "ab", "kk", "the", "ulc", "sarl", "spa",
    ]

    /// the form two company names are compared in: lowercase, "&" read as "and", punctuation removed, legal
    /// words at the ends dropped, spaces removed. "Google LLC." and "google" are equal
    public static func normalise(_ name: String) -> String {
        let cleaned = name.lowercased().replacingOccurrences(of: "&", with: " and ").unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        var words = String(cleaned).split(separator: " ").map(String.init)
        while let last = words.last, legalWords.contains(last), words.count > 1 { words.removeLast() }
        while let first = words.first, legalWords.contains(first), words.count > 1 { words.removeFirst() }
        return words.joined()
    }

    /// true when a name a reference gave stands for the same company as the subject
    static func same(_ referenceName: String, as subject: AuditSubject, aliases: ReferenceAliases) -> Bool {
        let ours = Set([normalise(subject.parent)] + (subject.company.map { [normalise($0)] } ?? []))
        if ours.contains(normalise(referenceName)) { return true }
        if let mapped = aliases.parent(forReferenceName: referenceName) { return ours.contains(normalise(mapped)) }
        return false
    }

    // MARK: scoring

    /// the registrable-domain key a reference is looked up by: the subject's domain, then the same name with
    /// leading labels removed one at a time
    private static func keys(for domain: String) -> [String] {
        var labels = domain.lowercased().split(separator: ".").map(String.init)
        var out: [String] = []
        while labels.count >= 2 {
            out.append(labels.joined(separator: "."))
            labels.removeFirst()
        }
        return out
    }

    public static func score(_ subject: AuditSubject, references: ReferenceMaps, aliases: ReferenceAliases) -> AuditRow {
        var entityVerdict = ReferenceVerdict.noAnswer
        var entityName: String?
        if let entry = keys(for: subject.domain).lazy.compactMap({ references.entities[$0] }).first {
            entityName = entry.entity
            entityVerdict = entry.names.contains { same($0, as: subject, aliases: aliases) } ? .agrees : .differs
        }
        var certVerdict = ReferenceVerdict.noAnswer
        var organisation: String?
        if case .organisation(let org)? = references.certificates[subject.domain.lowercased()] {
            organisation = org
            certVerdict = same(org, as: subject, aliases: aliases) ? .agrees : .differs
        }
        return AuditRow(subject: subject, entity: entityVerdict, certificate: certVerdict, entityName: entityName, organisation: organisation)
    }

    /// scores each subject once, in domain order. subjects count once per (registrable domain lower-cased, normalised
    /// parent): the first one's category wins, and a later one only fills in a missing company name
    public static func rows(_ subjects: [AuditSubject], references: ReferenceMaps, aliases: ReferenceAliases) -> [AuditRow] {
        var merged: [String: AuditSubject] = [:]
        var order: [String] = []
        for s in subjects {
            let key = s.domain.lowercased() + "\u{0}" + normalise(s.parent)
            if let first = merged[key] {
                if first.company == nil, let company = s.company {
                    merged[key] = AuditSubject(domain: first.domain, parent: first.parent, company: company, category: first.category)
                }
            } else {
                merged[key] = s
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
            .sorted { ($0.domain.lowercased(), $0.parent) < ($1.domain.lowercased(), $1.parent) }
            .map { score($0, references: references, aliases: aliases) }
    }

    public static func summarise(name: String, rows: [AuditRow]) -> AuditStratum {
        var s = AuditStratum(name: name)
        for row in rows {
            s.n += 1
            if row.entityName != nil { s.withEntityAnswer += 1 }
            if row.organisation != nil { s.withOrganisation += 1 }
            switch row.outcome {
            case .confirmed:
                s.confirmed += 1
                switch (row.entity == .agrees, row.certificate == .agrees) {
                case (true, true): s.confirmedByBoth += 1
                case (true, false): s.confirmedByEntityOnly += 1
                default: s.confirmedByCertificateOnly += 1
                }
                if row.entity == .differs || row.certificate == .differs { s.confirmedWhileOtherDiffers += 1 }
            case .contradicted: s.contradicted += 1
            case .unverifiable: s.unverifiable += 1
            }
        }
        if s.verifiable > 0 { s.upperBound = upperBound(failures: s.contradicted, of: s.verifiable) }
        return s
    }

    /// the distinct registrable domains of a set of rows, sorted: what the reference fetcher needs
    public static func domains(_ subjects: [AuditSubject]) -> [String] {
        Set(subjects.map { $0.domain.lowercased() }).sorted()
    }

    // MARK: the bound

    /// the one-sided upper confidence bound (Clopper-Pearson) of a rate with `failures` out of `n`: the p at which
    /// seeing `failures` or fewer has probability 1 - confidence. 0 failures gives 1 - (1 - confidence)^(1/n)
    public static func upperBound(failures k: Int, of n: Int, confidence: Double = Audit.confidence) -> Double {
        precondition(n > 0 && k >= 0 && k <= n)
        if k == n { return 1 }
        let alpha = 1 - confidence
        if k == 0 { return 1 - pow(alpha, 1 / Double(n)) }
        // binomial cdf decreases in p: bisect for cdf(k; n, p) = alpha
        var low = 0.0, high = 1.0
        for _ in 0..<200 {
            let mid = (low + high) / 2
            if binomialCDF(k, n, mid) > alpha { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    static func binomialCDF(_ k: Int, _ n: Int, _ p: Double) -> Double {
        guard p > 0 else { return 1 }
        guard p < 1 else { return k >= n ? 1 : 0 }
        let logP = log(p), logQ = log(1 - p)
        // log of n choose i, built up one term at a time (no gamma function needed)
        var logChoose = 0.0
        var sum = 0.0
        for i in 0...k {
            if i > 0 { logChoose += log(Double(n - i + 1)) - log(Double(i)) }
            sum += exp(logChoose + Double(i) * logP + Double(n - i) * logQ)
        }
        return min(sum, 1)
    }

    // MARK: output

    /// the header and one line per contradicted row for the owner to decide by hand. local use only
    public static func contradictionLines(_ rows: [AuditRow]) -> [String] {
        let header = "domain\tour parent and category\tentity map\tcertificate organisation"
        var seen = Set<AuditSubject>()
        var lines = [header]
        for row in rows where row.outcome == .contradicted && seen.insert(row.subject).inserted {
            lines.append([
                row.subject.domain, "\(row.subject.parent) (\(row.subject.category.rawValue))",
                row.entityName ?? "-", row.organisation ?? "-",
            ].joined(separator: "\t"))
        }
        return lines
    }

    /// numbers only: no domain and no company name
    public static func report(_ strata: [AuditStratum]) -> String {
        (["Company classification audit against two references (entity map, certificate organisation)"]
            + strata.map { $0.text() }).joined(separator: "\n") + "\n"
    }
}
