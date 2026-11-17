import Flows
import Foundation

// holds the first outbound payloads of each new connection until the server name is read.
// the only raw bytes kept beyond decoding, in memory only. done entries hold no bytes.

public struct HandshakeBuffer: Sendable {
    private enum Kind: Sendable { case tls, quic }

    private struct Pending: Sendable {
        var kind: Kind
        var packets = 0
        var byteCount = 0
        /// tls: one contiguous stream. quic: one element per datagram
        var chunks: [[UInt8]] = []
    }

    private enum State: Sendable {
        case pending(Pending)
        case done
    }

    public let maxPackets: Int
    public let maxBytes: Int
    private var states: [FlowKey: State] = [:]

    /// buffers that ended without a name (cap, no sni, not a handshake), by kind
    public private(set) var tlsGaveUp = 0
    public private(set) var quicGaveUp = 0

    public init(maxPackets: Int = 5, maxBytes: Int = 16_384) {
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
    }

    public var pendingCount: Int {
        states.values.reduce(0) { count, state in
            if case .pending = state { return count + 1 }
            return count
        }
    }

    /// feeds the payload of an outbound packet. returns a server name once, then nothing more for that key
    public mutating func add(key: FlowKey, payload: ArraySlice<UInt8>, isQUIC: Bool) -> String? {
        guard !payload.isEmpty else { return nil }
        var pending: Pending
        switch states[key] {
        case .done:
            return nil
        case .pending(let p):
            pending = p
        case nil:
            let first = payload[payload.startIndex]
            if !isQUIC, key.transport == .tcp, first == 0x16 {
                pending = Pending(kind: .tls)
            } else if isQUIC, key.transport == .udp, key.remotePort == 443, first & 0xC0 == 0xC0 {
                pending = Pending(kind: .quic)
            } else {
                states[key] = .done
                return nil
            }
        }

        pending.packets += 1
        pending.byteCount += payload.count
        if pending.packets > maxPackets || pending.byteCount > maxBytes {
            return finish(key, pending.kind, found: nil)
        }
        let result: SNIResult
        switch pending.kind {
        case .tls:
            pending.chunks = [(pending.chunks.first ?? []) + payload]
            result = TLSClientHello.serverName(inRecords: pending.chunks[0][...])
        case .quic:
            pending.chunks.append(Array(payload))
            result = QUICInitial.serverName(inDatagrams: pending.chunks.map { $0[...] })
        }
        switch result {
        case .found(let name): return finish(key, pending.kind, found: name)
        case .needMore:
            states[key] = .pending(pending)
            return nil
        case .notHandshake, .noSNI: return finish(key, pending.kind, found: nil)
        }
    }

    /// called when the flow closes
    public mutating func forget(_ key: FlowKey) {
        states[key] = nil
    }

    private mutating func finish(_ key: FlowKey, _ kind: Kind, found: String?) -> String? {
        states[key] = .done
        if found == nil {
            switch kind {
            case .tls: tlsGaveUp += 1
            case .quic: quicGaveUp += 1
            }
        }
        return found
    }
}
