import Flows
import Foundation

// holds the first outbound payloads of each new connection until the server name is read.
// the only raw bytes kept beyond decoding, in memory only. done entries hold no bytes.

/// why a handshake buffer ended without a server name. numbers only, never payload
public enum GaveUpReason: String, Sendable, CaseIterable {
    /// more than maxPackets / maxBytes buffered, or the quic attempt cap reached after decrypting fine
    case capReached
    /// the bytes were not a ClientHello / client Initial
    case notHandshake
    /// a readable ClientHello with no usable server_name
    case noServerName
    /// quic long header with a version other than v1 / v2 (includes version negotiation)
    case unsupportedVersion
    /// quic Initial that did not decrypt within the attempt cap
    case decryptFailed
    /// udp 443 flow whose first payload byte has the long-header bit clear
    case shortHeaderFirst
}

public struct HandshakeBuffer: Sendable {
    private enum Kind: Sendable { case tls, quic }

    private struct Pending: Sendable {
        var kind: Kind
        var packets = 0
        var byteCount = 0
        /// tls: the contiguous stream so far
        var stream: [UInt8] = []
        /// quic: decrypted crypto data by offset, so each datagram is decrypted once
        var pieces: [Int: [UInt8]] = [:]
        /// quic: decryption attempts so far (at most maxQUICAttempts)
        var attempts = 0
        var decrypted = false
        /// creation order, so the oldest pending buffer can be found when the table is full
        var order = 0
    }

    private enum State: Sendable {
        case pending(Pending)
        case done
    }

    /// a quic flow's Initial is decrypted at most this many times
    public static let maxQUICAttempts = 3

    /// entries kept at most (pending and done together)
    public static let defaultMaxStates = 4_096

    public let maxPackets: Int
    public let maxBytes: Int
    public let maxStates: Int
    private var states: [FlowKey: State] = [:]
    private var nextOrder = 0

    /// entries removed because the table was full: every done entry dropped plus every pending one finished early
    public private(set) var statesDropped = 0
    /// most entries held at once
    public private(set) var peakStates = 0

    /// buffers that ended without a name (cap, no sni, not a handshake), by kind
    public private(set) var tlsGaveUp = 0
    public private(set) var quicGaveUp = 0
    /// the same events by reason. sums to tlsGaveUp + quicGaveUp
    public private(set) var gaveUpReasons: [GaveUpReason: Int] = [:]

    /// udp flows whose first payload was a quic short header, not yet taken by the caller. such a flow
    /// began before the capture. keys only
    private var shortHeaderKeys: [FlowKey] = []

    /// test hook: called once per quic decryption attempt
    public var decryptProbe: (@Sendable () -> Void)?

    public init(maxPackets: Int = 5, maxBytes: Int = 16_384, maxStates: Int = HandshakeBuffer.defaultMaxStates) {
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
        self.maxStates = max(2, maxStates)
    }

    public var stateCount: Int { states.count }

    /// makes room for one new key. first every done entry goes (they hold no bytes and only stop a second
    /// read of the same flow); if the table is still full, the oldest quarter of the pending ones is finished
    /// as `capReached`, so each shows up in the give-up counts
    private mutating func makeRoom() {
        let done = states.filter { if case .done = $0.value { true } else { false } }.map(\.key)
        for key in done { states[key] = nil }
        statesDropped += done.count
        guard states.count >= maxStates else { return }
        var pending: [(key: FlowKey, order: Int, kind: Kind)] = []
        for (key, state) in states {
            if case .pending(let p) = state { pending.append((key, p.order, p.kind)) }
        }
        pending.sort { $0.order < $1.order }
        for victim in pending.prefix(max(1, maxStates / 4)) {
            states[victim.key] = nil
            record(victim.kind, .capReached)
            statesDropped += 1
        }
    }

    public var pendingCount: Int {
        states.values.reduce(0) { count, state in
            if case .pending = state { return count + 1 }
            return count
        }
    }

    /// feeds the payload of an outbound packet. returns a server name (with the ech flag) once, then nothing more for that key
    public mutating func add(key: FlowKey, payload: ArraySlice<UInt8>, isQUIC: Bool) -> ServerNameResult? {
        guard !payload.isEmpty else { return nil }
        defer { if states.count > peakStates { peakStates = states.count } }
        var pending: Pending
        switch states[key] {
        case .done:
            return nil
        case .pending(let p):
            pending = p
        case nil:
            if states.count >= maxStates { makeRoom() }
            let first = payload[payload.startIndex]
            if !isQUIC, key.transport == .tcp, first == 0x16 {
                pending = Pending(kind: .tls, order: nextOrder)
                nextOrder += 1
            } else if isQUIC, key.transport == .udp, key.remotePort == 443 {
                if first & 0xC0 == 0xC0 {
                    pending = Pending(kind: .quic, order: nextOrder)
                    nextOrder += 1
                } else {
                    states[key] = .done
                    record(.quic, first & 0x80 == 0 ? .shortHeaderFirst : .notHandshake)
                    if first & 0x80 == 0 { shortHeaderKeys.append(key) }
                    return nil
                }
            } else {
                states[key] = .done
                return nil
            }
        }

        pending.packets += 1
        pending.byteCount += payload.count
        if pending.packets > maxPackets || pending.byteCount > maxBytes {
            return finish(key, pending.kind, reason: .capReached)
        }
        let result: SNIResult
        switch pending.kind {
        case .tls:
            pending.stream += payload
            result = TLSClientHello.serverName(inRecords: pending.stream[...])
        case .quic:
            pending.attempts += 1
            decryptProbe?()
            switch QUICInitial.inspect(datagram: Array(payload)) {
            case .unsupportedVersion: return finish(key, .quic, reason: .unsupportedVersion)
            case .notInitial: return finish(key, .quic, reason: .notHandshake)
            case .decryptFailed:
                guard pending.attempts < Self.maxQUICAttempts else {
                    return finish(key, .quic, reason: pending.decrypted ? .capReached : .decryptFailed)
                }
                states[key] = .pending(pending)
                return nil
            case .frames(let frames):
                pending.decrypted = true
                for (offset, data) in frames where (pending.pieces[offset]?.count ?? 0) < data.count {
                    pending.pieces[offset] = data
                }
                result = TLSClientHello.serverName(inHandshake: QUICInitial.reassemble(pending.pieces)[...])
                if case .needMore = result, pending.attempts >= Self.maxQUICAttempts {
                    return finish(key, .quic, reason: .capReached)
                }
            }
        }
        switch result {
        case .found(let found): return finish(key, pending.kind, found: found)
        case .needMore:
            states[key] = .pending(pending)
            return nil
        case .notHandshake: return finish(key, pending.kind, reason: .notHandshake)
        case .noSNI: return finish(key, pending.kind, reason: .noServerName)
        }
    }

    /// the flows seen since the last call whose first payload was a quic short header (the connection began
    /// before the capture). each key is returned once
    public mutating func drainShortHeaderFirst() -> [FlowKey] {
        defer { shortHeaderKeys.removeAll(keepingCapacity: true) }
        return shortHeaderKeys
    }

    /// called when the flow closes
    public mutating func forget(_ key: FlowKey) {
        states[key] = nil
    }

    private mutating func finish(_ key: FlowKey, _ kind: Kind, found: ServerNameResult) -> ServerNameResult? {
        states[key] = .done
        return found
    }

    private mutating func finish(_ key: FlowKey, _ kind: Kind, reason: GaveUpReason) -> ServerNameResult? {
        states[key] = .done
        record(kind, reason)
        return nil
    }

    private mutating func record(_ kind: Kind, _ reason: GaveUpReason) {
        switch kind {
        case .tls: tlsGaveUp += 1
        case .quic: quicGaveUp += 1
        }
        gaveUpReasons[reason, default: 0] += 1
    }
}
