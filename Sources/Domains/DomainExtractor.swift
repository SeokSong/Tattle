import Flows
import Foundation
import PacketDecoder

// applies the spec's rules to decoded packets: inbound udp from port 53 is dns, outbound payloads go
// through the handshake buffer. the pipeline decides which packets to feed.

public struct DomainExtractor: Sendable {
    public private(set) var buffer: HandshakeBuffer

    public init(buffer: HandshakeBuffer = HandshakeBuffer()) {
        self.buffer = buffer
    }

    public var tlsGaveUp: Int { buffer.tlsGaveUp }
    public var quicGaveUp: Int { buffer.quicGaveUp }

    public mutating func observe(_ packet: DecodedPacket) -> [DomainObservation] {
        let transport = packet.headers.transport
        guard transport == .tcp || transport == .udp,
            let localPort = packet.localPort, let remotePort = packet.remotePort
        else { return [] }
        let range = packet.headers.payload
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= packet.bytes.count else { return [] }
        let payload = packet.bytes[range]

        switch packet.direction {
        case .inbound, .inferredInbound:
            guard transport == .udp, remotePort == 53,
                let o = DNSParser.parse(
                    payload, time: packet.timestamp, process: packet.process,
                    effectiveProcess: packet.effectiveProcess)
            else { return [] }
            return [o]
        case .outbound, .inferredOutbound, .unknown:
            let key = FlowKey(
                transport: transport, localAddress: packet.localAddress, localPort: localPort,
                remoteAddress: packet.remoteAddress, remotePort: remotePort)
            let isQUIC = transport == .udp && remotePort == 443
            guard let name = buffer.add(key: key, payload: payload, isQUIC: isQUIC) else { return [] }
            return [
                DomainObservation(
                    time: packet.timestamp, source: .sni, hostname: name, flowKey: key,
                    process: packet.process, effectiveProcess: packet.effectiveProcess)
            ]
        }
    }

    public mutating func flowClosed(_ key: FlowKey) {
        buffer.forget(key)
    }
}
