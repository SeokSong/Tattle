import Foundation
import PCAPNG
import PacketDecoder

// pure data structure: no I/O, no clock. time comes from packet timestamps.
// addresses are never logged.

public struct FlowKey: Hashable, Sendable {
    public let transport: Transport
    public let localAddress: IPAddress
    public let localPort: UInt16
    public let remoteAddress: IPAddress
    public let remotePort: UInt16

    public init(
        transport: Transport, localAddress: IPAddress, localPort: UInt16,
        remoteAddress: IPAddress, remotePort: UInt16
    ) {
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }
}

/// one tally row
public struct ProcessPair: Hashable, Sendable {
    public let processName: String?
    public let processID: UInt32?
    public let effectiveName: String?
    public let effectiveID: UInt32?

    public init(_ processName: String?, _ processID: UInt32?, _ effectiveName: String?, _ effectiveID: UInt32?) {
        self.processName = processName
        self.processID = processID
        self.effectiveName = effectiveName
        self.effectiveID = effectiveID
    }

    public static let none = ProcessPair(nil, nil, nil, nil)
}

public enum FlowEndReason: String, Sendable {
    case fin, rst, idle, captureStopped, interrupted
    /// closed early because the table was full (see `FlowTable.maxOpenFlows`); the flow is saved as it was
    case evicted
}

public struct Flow: Sendable, Identifiable {
    public let id: UUID
    public let key: FlowKey
    public let interface: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var packetsIn = 0, packetsOut = 0
    public var ipBytesIn = 0, ipBytesOut = 0
    public var payloadBytesIn = 0, payloadBytesOut = 0
    public var unknownDirectionPackets = 0
    public var tally: [ProcessPair: Int] = [:]
    /// set by Domains (SNI)
    public var serverName: String?
    /// nil while open
    public var endReason: FlowEndReason?
    /// the connection began before the capture. tcp: the first packet seen had no SYN (or SYN-ACK). udp: the first
    /// outbound payload was a quic short header, set by the pipeline through `markMidstream`
    public var startedMidstream = false
    /// ClientHello carried the encrypted_client_hello extension (set in problem 2.3)
    public var echSeen = false

    public init(id: UUID = UUID(), key: FlowKey, interface: String, at timestamp: Date) {
        self.id = id
        self.key = key
        self.interface = interface
        self.firstSeen = timestamp
        self.lastSeen = timestamp
    }
}

public enum FlowEvent: Sendable { case opened(Flow), closed(Flow) }

public struct FlowTable: Sendable {
    private struct Entry: Sendable {
        var flow: Flow
        var finLocal = false
        var finRemote = false
        var closingSince: Date?
    }

    /// open flows kept at most; a new key past this closes the least recently seen flows as `.evicted`
    public static let defaultMaxOpenFlows = 20_000
    /// how many flows one eviction closes (a batch, so the sort is paid once per 1,000 new flows)
    public static let defaultEvictionBatch = 1_000
    /// closed flows waiting for a drain, at most. only reached when saves keep failing
    public static let maxClosedPending = 100_000
    /// process rows kept per flow; a new pair past this is counted under `ProcessPair.none`
    public static let maxTallyRows = 64

    public let idleTimeout: TimeInterval
    public let closingGrace: TimeInterval
    public let maxOpenFlows: Int
    public let evictionBatch: Int

    private var entries: [FlowKey: Entry] = [:]
    private var dirty = Set<FlowKey>()
    private var closedPending: [Flow] = []
    private var evictedKeys: [FlowKey] = []

    /// flows closed with `.evicted`
    public private(set) var evictedFlows = 0
    /// most flows open at once
    public private(set) var peakOpenFlows = 0
    /// closed flows dropped because `maxClosedPending` was reached (they were never saved)
    public private(set) var droppedClosedFlows = 0
    /// packets whose process pair was folded into `.none` because the flow's tally was full
    public private(set) var tallyRowsFolded = 0

    public init(
        idleTimeout: TimeInterval = 120, closingGrace: TimeInterval = 5,
        maxOpenFlows: Int = FlowTable.defaultMaxOpenFlows, evictionBatch: Int = FlowTable.defaultEvictionBatch
    ) {
        self.idleTimeout = idleTimeout
        self.closingGrace = closingGrace
        self.maxOpenFlows = max(1, maxOpenFlows)
        self.evictionBatch = max(1, evictionBatch)
    }

    public var openCount: Int { entries.count }

    /// keys of flows evicted since the last call, so the caller can release per-flow state. returns each key once
    public var hasEvictedKeys: Bool { !evictedKeys.isEmpty }

    public mutating func takeEvictedKeys() -> [FlowKey] {
        defer { evictedKeys.removeAll(keepingCapacity: true) }
        return evictedKeys
    }

    private mutating func queueClosed(_ flow: Flow) {
        closedPending.append(flow)
        if closedPending.count > Self.maxClosedPending {
            let drop = Self.maxClosedPending / 10
            closedPending.removeFirst(drop)
            droppedClosedFlows += drop
        }
    }

    /// closes the `evictionBatch` least recently seen flows (fewer if the table is smaller)
    private mutating func evict() {
        let victims = entries.sorted { $0.value.flow.lastSeen < $1.value.flow.lastSeen }.prefix(evictionBatch)
        for (key, entry) in victims {
            var flow = entry.flow
            flow.endReason = .evicted
            entries[key] = nil
            dirty.remove(key)
            queueClosed(flow)
            evictedKeys.append(key)
            evictedFlows += 1
        }
    }

    /// .opened on a new key. an RST closes the flow at once: on an existing flow that returns .closed;
    /// on a brand new key it returns .opened and the closed flow shows up in the next drainDirty.
    /// returns nil for an existing flow, and for packets that are not tcp/udp with both ports
    public mutating func add(_ packet: DecodedPacket) -> FlowEvent? {
        let transport = packet.headers.transport
        guard transport == .tcp || transport == .udp,
            let localPort = packet.localPort, let remotePort = packet.remotePort
        else { return nil }

        let key = FlowKey(
            transport: transport, localAddress: packet.localAddress, localPort: localPort,
            remoteAddress: packet.remoteAddress, remotePort: remotePort)

        var event: FlowEvent?
        var entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry(flow: Flow(key: key, interface: packet.interface, at: packet.timestamp))
            // one check per new tcp flow: no syn on the first packet seen means the handshake was missed.
            // a syn-ack counts as a handshake. udp is marked later by the pipeline, from the quic header
            if transport == .tcp { entry.flow.startedMidstream = !(packet.headers.tcpFlags?.contains(.syn) ?? false) }
            event = .opened(entry.flow)
        }

        let isNew = event != nil
        let ipBytes = packet.headers.ipBytes
        let payload = packet.headers.payload.count
        let localSent: Bool
        switch packet.direction {
        case .inbound, .inferredInbound:
            localSent = false
            entry.flow.packetsIn += 1
            entry.flow.ipBytesIn += ipBytes
            entry.flow.payloadBytesIn += payload
        case .outbound, .inferredOutbound:
            localSent = true
            entry.flow.packetsOut += 1
            entry.flow.ipBytesOut += ipBytes
            entry.flow.payloadBytesOut += payload
        case .unknown:
            localSent = true
            entry.flow.packetsOut += 1
            entry.flow.ipBytesOut += ipBytes
            entry.flow.payloadBytesOut += payload
            entry.flow.unknownDirectionPackets += 1
        }
        if packet.timestamp > entry.flow.lastSeen { entry.flow.lastSeen = packet.timestamp }

        let pair: ProcessPair
        if packet.process == nil && packet.effectiveProcess == nil {
            pair = .none
        } else {
            pair = ProcessPair(
                packet.process?.name, packet.process?.pid,
                packet.effectiveProcess?.name, packet.effectiveProcess?.pid)
        }
        if entry.flow.tally.count >= Self.maxTallyRows, entry.flow.tally[pair] == nil {
            entry.flow.tally[.none, default: 0] += 1
            tallyRowsFolded += 1
        } else {
            entry.flow.tally[pair, default: 0] += 1
        }

        var reset = false
        if transport == .tcp, let flags = packet.headers.tcpFlags {
            if flags.contains(.rst) {
                reset = true
            } else if flags.contains(.fin) {
                if localSent { entry.finLocal = true } else { entry.finRemote = true }
                if entry.finLocal, entry.finRemote, entry.closingSince == nil {
                    entry.closingSince = packet.timestamp
                }
            }
        }

        if reset {
            entry.flow.endReason = .rst
            entries[key] = nil
            dirty.remove(key)
            queueClosed(entry.flow)
            return isNew ? event : .closed(entry.flow)
        }
        if isNew, entries.count >= maxOpenFlows { evict() }
        entries[key] = entry
        if entries.count > peakOpenFlows { peakOpenFlows = entries.count }
        dirty.insert(key)
        return event
    }

    /// closes finished flows (grace passed) and idle flows. closed flows are removed and marked dirty
    public mutating func expire(at now: Date) -> [Flow] {
        var closed: [Flow] = []
        for (key, entry) in entries {
            var reason: FlowEndReason?
            if let since = entry.closingSince, since.addingTimeInterval(closingGrace) < now {
                reason = .fin
            } else if entry.flow.lastSeen.addingTimeInterval(idleTimeout) <= now {
                reason = .idle
            }
            if let reason {
                var flow = entry.flow
                flow.endReason = reason
                closed.append(flow)
                entries[key] = nil
                dirty.remove(key)
                queueClosed(flow)
            }
        }
        return closed
    }

    public mutating func closeAll(reason: FlowEndReason) -> [Flow] {
        var closed: [Flow] = []
        closed.reserveCapacity(entries.count)
        for entry in entries.values {
            var flow = entry.flow
            flow.endReason = reason
            closed.append(flow)
            queueClosed(flow)
        }
        entries.removeAll()
        dirty.removeAll()
        return closed
    }

    public mutating func setServerName(_ name: String, for key: FlowKey) {
        guard entries[key] != nil else { return }
        entries[key]?.flow.serverName = name
        dirty.insert(key)
    }

    public mutating func markMidstream(for key: FlowKey) {
        guard entries[key] != nil else { return }
        entries[key]?.flow.startedMidstream = true
        dirty.insert(key)
    }

    public mutating func markECH(for key: FlowKey) {
        guard entries[key] != nil else { return }
        entries[key]?.flow.echSeen = true
        dirty.insert(key)
    }

    /// every flow changed since the last drain, open or closed. a closed flow appears in exactly one drain
    /// the flows `drainDirty` would return, without draining them: closed flows waiting to be saved, and open flows
    /// changed since the last drain. read-only, so the live map can look between saves (Milestone 4) without changing
    /// what or when the pipeline saves
    public func peekDirty() -> [Flow] {
        closedPending + dirty.compactMap { entries[$0]?.flow }
    }

    public mutating func drainDirty() -> [Flow] {
        var out = closedPending
        closedPending.removeAll()
        out.reserveCapacity(out.count + dirty.count)
        for key in dirty {
            if let entry = entries[key] { out.append(entry.flow) }
        }
        dirty.removeAll()
        return out
    }

    /// puts flows from a failed save back so the next drain returns them. a closed flow goes back to
    /// closedPending; an open flow still in the table is marked dirty again (the next drain then carries
    /// its latest data); an open flow no longer in the table is ignored
    public mutating func requeue(_ flows: [Flow]) {
        for flow in flows {
            if flow.endReason != nil {
                queueClosed(flow)
            } else if entries[flow.key] != nil {
                dirty.insert(flow.key)
            }
        }
    }
}
