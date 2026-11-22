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
    public var relation: LabelRelation

    public var isMatched: Bool { source != .none }
}
