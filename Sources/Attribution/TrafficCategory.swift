import Flows

/// what a flow is, decided once from its tally, process names and remote address
public enum TrafficCategory: String, Codable, CaseIterable, Sendable {
    case app, helper, system, deviceLink, localNetwork, unknown

    /// the user-facing label
    public var label: String {
        switch self {
        case .app: return "From app"
        case .helper: return "Helper for an app"
        case .system: return "iOS system"
        case .deviceLink: return "USB link to this Mac"
        case .localNetwork: return "Local network only"
        case .unknown: return "No process info"
        }
    }

    /// `app` + `helper`: traffic an app caused, directly or through a helper
    public var isAppTraffic: Bool { self == .app || self == .helper }

    /// counts as phone traffic: everything except the Mac link and local-only chatter
    public var isPhoneTraffic: Bool {
        switch self {
        case .app, .helper, .system, .unknown: return true
        case .deviceLink, .localNetwork: return false
        }
    }
}

public struct Classification: Equatable, Sendable {
    public let category: TrafficCategory
    public let rule: String

    public init(category: TrafficCategory, rule: String) {
        self.category = category
        self.rule = rule
    }
}

/// rule names as printed in the report
public enum ClassifierRule {
    public static let deviceLinkProcess = "deviceLink.process"
    public static let appProcess = "app.process"
    public static let helperEproc = "helper.eproc"
    public static let deviceLinkLinkLocal = "deviceLink.linkLocal"
    public static let localNetworkAddress = "localNetwork.address"
    public static let systemProcess = "system.process"
    public static let unknownNoProcess = "unknown.noProcess"
}

public enum Classifier {
    private static let deviceLinkLookup: Set<String> =
        Set(deviceLinkProcesses).union(deviceLinkProcesses.map(ProcessNames.cut))

    /// precedence, first match wins: deviceLink.process, app or helper (an app-tagged flow is never moved),
    /// deviceLink.linkLocal, localNetwork.address, system, unknown
    public static func classify(_ flow: Flow) -> Classification {
        let result = Attributor.attribute(flow.tally)
        let top = result.topRow

        if let name = top?.processName, deviceLinkLookup.contains(ProcessNames.cut(name)) {
            return Classification(category: .deviceLink, rule: ClassifierRule.deviceLinkProcess)
        }
        switch result.primary {
        case .app:
            if let p = top?.processName, let e = top?.effectiveName, p != e {
                return Classification(category: .helper, rule: ClassifierRule.helperEproc)
            }
            return Classification(category: .app, rule: ClassifierRule.appProcess)
        case .onBehalfOf:
            return Classification(category: .helper, rule: ClassifierRule.helperEproc)
        case .system, .unknown:
            break
        }
        if flow.key.localAddress.isLinkLocal && flow.key.remoteAddress.isLinkLocal {
            return Classification(category: .deviceLink, rule: ClassifierRule.deviceLinkLinkLocal)
        }
        if flow.key.remoteAddress.isLocalOnly {
            return Classification(category: .localNetwork, rule: ClassifierRule.localNetworkAddress)
        }
        if case .system = result.primary {
            return Classification(category: .system, rule: ClassifierRule.systemProcess)
        }
        return Classification(category: .unknown, rule: ClassifierRule.unknownNoProcess)
    }

    /// the biggest row of the winning group, chosen the way `Attributor.attribute` picks it
}
