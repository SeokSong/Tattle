import Domains
import Flows
import Foundation

public enum AppAttribution: Equatable, Sendable {
    /// packets tagged with an app process
    case app(name: String, pids: Set<UInt32>)
    /// system process with an app as effective process
    case onBehalfOf(app: String, via: String)
    case system(name: String)
    case unknown
}

public struct AttributionResult: Sendable {
    public let primary: AppAttribution
    public let packetsForPrimary: Int
    /// every packet in the tally, including rows with no process info
    public let packetsTotal: Int
    /// more than one non-system app name in the tally
    public let mixed: Bool

    public init(primary: AppAttribution, packetsForPrimary: Int, packetsTotal: Int, mixed: Bool) {
        self.primary = primary
        self.packetsForPrimary = packetsForPrimary
        self.packetsTotal = packetsTotal
        self.mixed = mixed
    }
}

public enum Attributor {
    private struct Group {
        var packets = 0
        var rows: [(pair: ProcessPair, packets: Int)] = []
    }

    public static func attribute(_ tally: [ProcessPair: Int]) -> AttributionResult {
        var total = 0
        var groups: [String: Group] = [:]
        for (pair, count) in tally {
            total += count
            guard pair != .none, let name = pair.effectiveName ?? pair.processName else { continue }
            groups[name, default: Group()].packets += count
            groups[name]?.rows.append((pair, count))
        }
        // largest group wins, name breaks ties so the result is deterministic
        guard let (name, group) = groups.min(by: {
            $0.value.packets != $1.value.packets ? $0.value.packets > $1.value.packets : $0.key < $1.key
        }) else {
            return AttributionResult(primary: .unknown, packetsForPrimary: 0, packetsTotal: total, mixed: false)
        }

        let apps = groups.keys.filter { !isSystemProcess($0) }
        let mixed = apps.count >= 2

        // the biggest row decides how the group is shown
        let top = group.rows.min(by: {
            $0.packets != $1.packets ? $0.packets > $1.packets : rowKey($0.pair) < rowKey($1.pair)
        })!.pair
        let primary: AppAttribution
        if let via = top.processName, top.effectiveName != nil, via != name, isSystemProcess(via) {
            primary = .onBehalfOf(app: name, via: via)
        } else if isSystemProcess(name) {
            primary = .system(name: name)
        } else {
            var pids = Set<UInt32>()
            for row in group.rows {
                if let id = row.pair.effectiveName != nil ? row.pair.effectiveID : row.pair.processID {
                    pids.insert(id)
                }
            }
            primary = .app(name: name, pids: pids)
        }
        return AttributionResult(
            primary: primary, packetsForPrimary: group.packets, packetsTotal: total, mixed: mixed)
    }

    public static func isSystemProcess(_ name: String) -> Bool {
        systemProcessLookup.contains(name)
    }

    public static func supportingDomains(for flow: Flow, in domains: [DomainObservation]) -> [DomainObservation] {
        let appName = DNSRule.appName(for: flow)
        let sni = domains.filter { $0.source == .sni && $0.flowKey == flow.key }
        let dns = domains.filter { d in
            d.source == .dns && d.addresses.contains(flow.key.remoteAddress)
                && DNSRule.age(of: d, for: flow, appName: appName) != nil
        }.sorted(by: DNSRule.newerFirst)
        return sni + dns
    }

    private static func rowKey(_ p: ProcessPair) -> String {
        "\(p.processName ?? "")|\(p.processID ?? 0)|\(p.effectiveName ?? "")|\(p.effectiveID ?? 0)"
    }
}

/// the one DNS-matching rule, used by `supportingDomains` and by the hostname index
enum DNSRule {
    static let defaultTTL: TimeInterval = 300

    /// the flow's app name: the winning app, or the winning system process; nil when unknown
    static func appName(for flow: Flow) -> String? {
        switch Attributor.attribute(flow.tally).primary {
        case .app(let name, _): return name
        case .onBehalfOf(let app, _): return app
        case .system(let name): return name
        case .unknown: return nil
        }
    }

    static func ttl(_ d: DomainObservation) -> TimeInterval {
        d.ttl.map(TimeInterval.init) ?? defaultTTL
    }

    /// an answer with no process matches any flow; a flow with no app matches only such answers
    static func appMatches(_ appName: String?, _ d: DomainObservation) -> Bool {
        guard let answerApp = d.effectiveProcess?.name ?? d.process?.name else { return true }
        guard let appName else { return false }
        return ProcessNames.displayName(appName) == ProcessNames.displayName(answerApp)
    }

    /// seconds between the answer and the flow's first packet when the answer qualifies (address is checked
    /// by the caller): not after the flow, within ttl inclusive, app matches. nil otherwise
    static func age(of d: DomainObservation, for flow: Flow, appName: String?) -> TimeInterval? {
        guard d.time <= flow.firstSeen, appMatches(appName, d) else { return nil }
        let age = flow.firstSeen.timeIntervalSince(d.time)
        return age <= ttl(d) ? age : nil
    }

    /// newest first; equal times go to the smaller hostname
    static func newerFirst(_ a: DomainObservation, _ b: DomainObservation) -> Bool {
        a.time != b.time ? a.time > b.time : a.hostname < b.hostname
    }
}
