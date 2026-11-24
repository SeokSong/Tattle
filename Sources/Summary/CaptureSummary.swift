import Attribution
import Companies
import Foundation

/// connections and ip bytes (in + out)
public struct TrafficCount: Sendable, Equatable {
    public var connections: Int
    public var bytes: Int

    public init(connections: Int = 0, bytes: Int = 0) {
        self.connections = connections
        self.bytes = bytes
    }
}

/// one parent company an entry contacted, confirmed by a name seen in the connection
public struct CompanyEntry: Sendable, Equatable {
    public let parent: String
    /// the brands seen (the labels' `company`), distinct, sorted with `<`
    public let brands: [String]
    /// the categories seen, distinct, in `CompanyCategory.allCases` order
    public let categories: [CompanyCategory]
    /// the label relation to the entry's company: sameCompanyAsApp, other, or unknown when the entry has no company
    public let relation: LabelRelation
    public let traffic: TrafficCount
    public var isAdvertisingOrTracking: Bool { categories.contains { $0.isAdvertisingOrTracking } }

    public init(parent: String, brands: [String], categories: [CompanyCategory], relation: LabelRelation, traffic: TrafficCount) {
        self.parent = parent
        self.brands = brands
        self.categories = categories
        self.relation = relation
        self.traffic = traffic
    }
}

/// the summary of one app, or of the iOS system entry. port 443 traffic only
public struct CaptureAppSummary: Sendable, Equatable {
    /// the app table's bundle id, "process:<display name>" for an app the table does not know, or "system"
    public let key: String
    public let name: String
    /// the app's parent company; nil when the app table does not know the app
    public let company: String?
    /// own company first, then advertising or tracking, then the rest; ties by parent with `<`
    public let companies: [CompanyEntry]
    /// distinct parents confirmed by a name seen in the connection (the unit of OD3); includes the own company
    public var namedCompanies: Int { companies.count }
    public var adTrackCompanies: Int { companies.filter(\.isAdvertisingOrTracking).count }
    /// parents seen only through a hint (dns or same server), not among `companies`, sorted with `<`
    public let possibleCompanies: [String]
    /// distinct registrable domains per category, for names no source names a company for but the AdGuard list
    /// gives a category (never `unclassified`). never part of any company count
    public let unnamedCategories: [CompanyCategory: Int]
    /// every port 443 byte of the entry is in exactly one of the next four
    public let identified: TrafficCount
    public let notIdentified: TrafficCount
    public let hinted: TrafficCount
    /// every `UnnamedReason` is a key, zero when none
    public let unseen: [UnnamedReason: TrafficCount]
    /// identified bytes over all port 443 bytes of the entry
    public let coverage: CoverageRatio
    public let windowStart: Date
    public let windowEnd: Date

    public init(
        key: String, name: String, company: String?, companies: [CompanyEntry], possibleCompanies: [String],
        unnamedCategories: [CompanyCategory: Int], identified: TrafficCount, notIdentified: TrafficCount,
        hinted: TrafficCount, unseen: [UnnamedReason: TrafficCount], coverage: CoverageRatio,
        windowStart: Date, windowEnd: Date
    ) {
        self.key = key
        self.name = name
        self.company = company
        self.companies = companies
        self.possibleCompanies = possibleCompanies
        self.unnamedCategories = unnamedCategories
        self.identified = identified
        self.notIdentified = notIdentified
        self.hinted = hinted
        self.unseen = unseen
        self.coverage = coverage
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct CaptureSummary: Sendable, Equatable {
    /// sorted by name (`localizedStandardCompare`), then by key
    public let apps: [CaptureAppSummary]
    /// nil when no system traffic went to port 443
    public let system: CaptureAppSummary?
    /// port 443 traffic with no process information (category unknown)
    public let noProcess: TrafficCount
    /// port 443 traffic left out like in the quality report: keys `.deviceLink` and `.localNetwork`, always both
    public let excluded: [TrafficCategory: TrafficCount]
    /// the curated list version and the tracker list version the labels came from
    public let curatedVersion: String
    public let trackerListVersion: String
    public static let systemName = "iOS system"
    public static let systemKey = "system"
    public static let systemCompany = "Apple"

    public init(
        apps: [CaptureAppSummary], system: CaptureAppSummary?, noProcess: TrafficCount,
        excluded: [TrafficCategory: TrafficCount], curatedVersion: String, trackerListVersion: String
    ) {
        self.apps = apps
        self.system = system
        self.noProcess = noProcess
        self.excluded = excluded
        self.curatedVersion = curatedVersion
        self.trackerListVersion = trackerListVersion
    }
}
