import Foundation

/// what a domain is for. the category belongs to the domain entry, not to the app. raw values
/// are written into exports, so a rename is a breaking change (a test pins them)
public enum CompanyCategory: String, CaseIterable, Sendable, Codable {
    case advertising
    case analytics
    case social
    case contentDelivery
    case cloudService
    case appleSystem
    case onlineService
    case unclassified

    /// the label shown to users
    public var label: String {
        switch self {
        case .advertising: "Advertising"
        case .analytics: "Analytics"
        case .social: "Social media"
        case .contentDelivery: "Content delivery"
        case .cloudService: "Cloud or app service"
        case .appleSystem: "Apple system"
        case .onlineService: "Online service"
        case .unclassified: "Not matched"
        }
    }

    /// true for the categories that count as "advertising or tracking"
    public var isAdvertisingOrTracking: Bool { self == .advertising || self == .analytics }

    /// categories a curated row may use: everything except unclassified
    public static var curatable: [CompanyCategory] { allCases.filter { $0 != .unclassified } }
}

/// which source named a label. a label always says which source gave the answer
public enum LabelSource: String, CaseIterable, Sendable, Codable {
    case curated
    case trackerList
    case appleOwner
    case none
}

/// how the matching row decided: the rung of the ladder, or no match
public enum LabelRule: String, Sendable, Codable {
    /// a curated row keyed by a hostname below the registrable domain
    case curatedHostname
    /// a curated row keyed by the registrable domain
    case curatedRegistrable
    /// a curated row that marks the private suffix as platform-operated: every host under it is the platform's own
    case curatedOperatedSuffix
    /// a tracker list row keyed by a hostname below the registrable domain
    case trackerHostname
    /// a tracker list row keyed by the registrable domain
    case trackerRegistrable
    /// the owner string from an imported report
    case appleOwner
    case noMatch
}

/// the label's company relative to the app that made the connection. set by a later problem
public enum LabelRelation: String, Sendable, Codable {
    case sameCompanyAsApp
    case other
    case unknown
}

/// one row of the curated list
public struct Company: Sendable, Equatable {
    /// registrable domain, or a hostname under one
    public let domain: String
    public let company: String
    public let parent: String
    public let category: CompanyCategory
    /// short public description of why the row is true; no adjectives
    public let note: String
}

/// the answer for one hostname. `source` names who gave it; `.none` means no source matched
public struct CompanyLabel: Sendable, Equatable {
    public let hostname: String
    public let registrableDomain: String?
    public let company: String?
    public let parent: String?
    public let category: CompanyCategory
    public let source: LabelSource
    public let rule: LabelRule
    public let datasetId: String?
    public let datasetVersion: String?
    public let datasetSHA256: String?
    /// set when the name is under a hosting platform's private suffix (`someone.pages.dev`): the platform
    /// the unknown site is hosted on, never its owner. only on a label with no company
    public let hostingPlatform: String?
    public var relation: LabelRelation

    public var isMatched: Bool { source != .none }

    /// shown on a row for a name no list knows. one sentence for every unknown name
    public static let notIdentifiedText = "Not identified"
    /// shown instead of `notIdentifiedText` when the name is under a hosting platform's suffix
    public static let unknownWebsiteText = "Website we couldn't identify"

    /// the row text for a label with no company: the plain words, or the website words when hosted
    public var unidentifiedText: String { hostingPlatform == nil ? Self.notIdentifiedText : Self.unknownWebsiteText }

    /// the tooltip for a hosted unknown website; nil when the name is not under a platform's suffix
    public var hostedDetail: String? {
        hostingPlatform.map { "Unknown website, hosted on \($0) (a service many sites use)" }
    }
}
