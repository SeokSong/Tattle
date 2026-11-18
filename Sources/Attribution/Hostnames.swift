import Domains
import Flows
import Foundation
import PacketDecoder

// pure read-time resolver: no I/O, no clock, no network. nothing it infers is stored.
// dns evidence comes from the same capture only.

public enum HostnameSource: String, Codable, Sendable { case sni, dns }

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

    public init(_ observations: [DomainObservation]) {
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
    }

    /// sni first (the flow's own server name, else the observation for its key), then dns
    public func resolve(_ flow: Flow) -> ResolvedHostname? {
        let observed = sniByFlow[flow.key]
        if let name = flow.serverName ?? observed?.hostname {
            return ResolvedHostname(
                name: name, source: .sni, dnsAgeSeconds: nil,
                echPresent: flow.echSeen || (observed?.echPresent ?? false))
        }
        return resolveWithoutSNI(flow)
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
}
