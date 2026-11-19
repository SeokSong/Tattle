import Domains
import Flows
import Foundation
import PacketDecoder

// pure read-time resolver: no I/O, no clock, no network. nothing it infers is stored.
// dns evidence comes from the same capture only.

public enum HostnameSource: String, Codable, Sendable {
    case sni, dns, sameAddress

    /// the label for a detail view or tooltip. a dns name is never presented as an observed name: on shared
    /// addresses (cdn) the answer often names another service than the connection asked for
    public var label: String {
        switch self {
        case .sni: return "Seen in connection"
        case .dns: return "From DNS (may be another service on the same server)"
        case .sameAddress: return "Same server as another connection of this app (may be another service)"
        }
    }

    /// the label for a table cell
    public var shortLabel: String {
        switch self {
        case .sni: return "Seen in connection"
        case .dns: return "From DNS, may differ"
        case .sameAddress: return "Same server as another connection, may differ"
        }
    }
}

/// why a flow has no hostname; first match wins (see `HostnameIndex.unnamedReason(for:)`)
public enum UnnamedReason: String, Codable, CaseIterable, Sendable {
    /// the hello carried encrypted_client_hello; any sni seen is the public outer name and is not used
    case echHidden
    /// the connection began before the capture: a tcp flow whose first packet had no syn, or a udp (quic) flow
    /// whose first payload was a short header
    case startedBeforeCapture
    /// udp flow with no server name found and no sign that it began before the capture
    case noHandshakeUDP
    /// anything else with no sni and no dns match
    case noDNSMatch
}

extension UnnamedReason {
    /// the text shown where a name would be, in the app and the command line
    public var label: String {
        switch self {
        case .echHidden: return "Name hidden by the app (ECH)"
        case .startedBeforeCapture: return "Connection started before capture"
        case .noHandshakeUDP, .noDNSMatch: return "No name found"
        }
    }
}

/// a flow's name, or the reason it has none
public enum HostnameOutcome: Equatable, Sendable {
    case named(ResolvedHostname)
    case unnamed(UnnamedReason)
}

public struct ResolvedHostname: Equatable, Sendable {
    public let name: String
    public let source: HostnameSource
    /// seconds from the dns answer to the flow's first packet; nil for sni
    public let dnsAgeSeconds: Double?
    /// the connection's hello carried encrypted_client_hello, so an sni name is the public outer name
    public let echPresent: Bool

    public init(name: String, source: HostnameSource, dnsAgeSeconds: Double?, echPresent: Bool) {
        self.name = name
        self.source = source
        self.dnsAgeSeconds = dnsAgeSeconds
        self.echPresent = echPresent
    }
}

/// built once from a session's observations; each lookup is a dictionary hit plus a binary search
public struct HostnameIndex: Sendable {
    /// per address, newest first, equal times by smaller hostname
    let dnsByAddress: [IPAddress: [DomainObservation]]
    let sniByFlow: [FlowKey: DomainObservation]
    /// sni names of the capture's own flows (not ech), per remote address and app display name
    let sniByAddressApp: [AddressApp: [SameAddressName]]

    struct AddressApp: Hashable {
        let address: IPAddress
        let app: String
    }

    struct SameAddressName {
        let flowID: UUID
        let time: Date
        let name: String
    }

    /// `flows` feeds the same-address hint only; without it that step finds nothing
    public init(_ observations: [DomainObservation], flows: [Flow] = []) {
        var dns: [IPAddress: [DomainObservation]] = [:]
        var sni: [FlowKey: DomainObservation] = [:]
        for d in observations {
            switch d.source {
            case .dns:
                for address in Set(d.addresses) { dns[address, default: []].append(d) }
            case .sni:
                guard let key = d.flowKey else { continue }
                // earliest observation wins; hostname breaks ties
                if let old = sni[key], !DNSRule.newerFirst(old, d) { sni[key] = d } else if sni[key] == nil {
                    sni[key] = d
                }
            }
        }
        for address in Array(dns.keys) { dns[address]?.sort(by: DNSRule.newerFirst) }
        dnsByAddress = dns
        sniByFlow = sni
        var byAddress: [AddressApp: [SameAddressName]] = [:]
        for f in flows where !f.echSeen {
            guard let name = f.serverName ?? sni[f.key]?.hostname, let app = DNSRule.appName(for: f) else { continue }
            let key = AddressApp(address: f.key.remoteAddress, app: ProcessNames.displayName(app))
            byAddress[key, default: []].append(SameAddressName(flowID: f.id, time: f.firstSeen, name: name))
        }
        sniByAddressApp = byAddress
    }

    /// sni first (the flow's own server name, else the observation for its key), then dns, then the
    /// same-address hint
    public func resolve(_ flow: Flow) -> ResolvedHostname? {
        let observed = sniByFlow[flow.key]
        if let name = flow.serverName ?? observed?.hostname {
            return ResolvedHostname(
                name: name, source: .sni, dnsAgeSeconds: nil,
                echPresent: flow.echSeen || (observed?.echPresent ?? false))
        }
        return resolveWithoutSNI(flow) ?? resolveSameAddress(flow)
    }

    /// the name used for a flow, or the one reason it has none. order: ech, sni, dns, same address, then the
    /// reasons in order. an ech flow never counts as named, even when a dns answer matches
    public func outcome(for flow: Flow) -> HostnameOutcome {
        if flow.echSeen { return .unnamed(.echHidden) }
        if let named = resolve(flow) { return .named(named) }
        if flow.startedMidstream { return .unnamed(.startedBeforeCapture) }
        return .unnamed(flow.key.transport == .udp ? .noHandshakeUDP : .noDNSMatch)
    }

    /// nil when the flow has a name. shared by the report and the screens
    public func unnamedReason(for flow: Flow) -> UnnamedReason? {
        if case .unnamed(let reason) = outcome(for: flow) { return reason }
        return nil
    }

    /// the dns step only
    public func resolveWithoutSNI(_ flow: Flow) -> ResolvedHostname? {
        guard let answers = dnsByAddress[flow.key.remoteAddress] else { return nil }
        let appName = DNSRule.appName(for: flow)
        // first index whose time is not after the flow start (array is newest first)
        var lo = 0, hi = answers.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if answers[mid].time > flow.firstSeen { lo = mid + 1 } else { hi = mid }
        }
        for d in answers[lo...] {
            if let age = DNSRule.age(of: d, for: flow, appName: appName) {
                return ResolvedHostname(name: d.hostname, source: .dns, dnsAgeSeconds: age, echPresent: flow.echSeen)
            }
        }
        return nil
    }

    /// the same-address step only: the sni name of another flow of this capture with the same remote address
    /// and the same app. the nearest flow in time wins; equal distances go to the smaller name. a hint: the
    /// address may serve several services
    public func resolveSameAddress(_ flow: Flow) -> ResolvedHostname? {
        guard let app = DNSRule.appName(for: flow),
            let candidates = sniByAddressApp[AddressApp(address: flow.key.remoteAddress, app: ProcessNames.displayName(app))]
        else { return nil }
        var best: SameAddressName?
        var bestDistance = Double.infinity
        for c in candidates where c.flowID != flow.id {
            let distance = abs(c.time.timeIntervalSince(flow.firstSeen))
            if distance < bestDistance || (distance == bestDistance && c.name < (best?.name ?? "")) {
                best = c
                bestDistance = distance
            }
        }
        guard let best else { return nil }
        return ResolvedHostname(name: best.name, source: .sameAddress, dnsAgeSeconds: nil, echPresent: false)
    }
}
