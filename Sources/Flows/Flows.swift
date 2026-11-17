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

public enum FlowEndReason: String, Sendable { case fin, rst, idle, captureStopped, interrupted }

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

    public let idleTimeout: TimeInterval
    public let closingGrace: TimeInterval

    private var entries: [FlowKey: Entry] = [:]
    private var dirty = Set<FlowKey>()
    private var closedPending: [Flow] = []

    public init(idleTimeout: TimeInterval = 120, closingGrace: TimeInterval = 5) {
        self.idleTimeout = idleTimeout
        self.closingGrace = closingGrace
    }

    public var openCount: Int { entries.count }

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
        entry.flow.tally[pair, default: 0] += 1

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
            closedPending.append(entry.flow)
            return isNew ? event : .closed(entry.flow)
        }
        entries[key] = entry
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
                closedPending.append(flow)
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
            closedPending.append(flow)
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

    /// every flow changed since the last drain, open or closed. a closed flow appears in exactly one drain
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
}
