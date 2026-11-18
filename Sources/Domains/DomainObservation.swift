import Flows
import Foundation
import PCAPNG
import PacketDecoder

public struct DomainObservation: Sendable {
    public enum Source: String, Sendable { case dns, sni }

    public let time: Date
    public let source: Source
    /// lowercased, no trailing dot
    public let hostname: String
    /// dns only, in order
    public let cnameChain: [String]
    /// dns only
    public let addresses: [IPAddress]
    /// dns only, smallest in the chain
    public let ttl: UInt32?
    /// sni only
    public let flowKey: FlowKey?
    /// sni only: the hello carried the encrypted_client_hello extension, so the name is the public outer name
    public let echPresent: Bool
    public let process: PCAPNGProcess?
    public let effectiveProcess: PCAPNGProcess?

    public init(
        time: Date, source: Source, hostname: String, cnameChain: [String] = [],
        addresses: [IPAddress] = [], ttl: UInt32? = nil, flowKey: FlowKey? = nil,
        echPresent: Bool = false, process: PCAPNGProcess? = nil, effectiveProcess: PCAPNGProcess? = nil
    ) {
        self.time = time
        self.source = source
        self.hostname = hostname
        self.cnameChain = cnameChain
        self.addresses = addresses
        self.ttl = ttl
        self.flowKey = flowKey
        self.echPresent = echPresent
        self.process = process
        self.effectiveProcess = effectiveProcess
    }
}
