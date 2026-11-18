import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Storage

// turns pcapng events into flows and domains. single actor, no threads (see md/PIPELINE.md).
// the raw bytes of a packet go out of scope after observe(); only the handshake buffer keeps a copy.
// addresses and hostnames are never logged.

public struct PipelineStats: Sendable {
    public var packets = 0, decoded = 0, skipped = 0, malformed = 0, droppedNoPort = 0
    public var flowsOpened = 0, flowsClosed = 0, dnsObservations = 0, sniFound = 0, echSeen = 0
    public var interfaces: [String: Int] = [:]
    /// saves (and end-of-session writes) that threw
    public var saveFailures = 0
    /// flows still unsaved after the final flush of stop
    public var unsavedFlows = 0
    /// wall time of run()
    public var elapsed: TimeInterval = 0

    public init() {}
}

public actor CapturePipeline {
    /// replay flushes every this many packets
    public static let replayFlushPackets = 5_000

    private let store: (any FlowStore)?
    private let session: CaptureSession
    private let flushInterval: TimeInterval
    private let retainFlows: Bool
    private let retainDomains: Bool

    private var decoder = PacketDecoder()
    private var flowTable = FlowTable()
    private var extractor = DomainExtractor()
    private var pendingDomains: [DomainObservation] = []
    private var retainedDomains: [DomainObservation] = []
    private var retained: [UUID: Flow] = [:]
    private var counters = PipelineStats()
    private var lastExpire: Date?
    private var sessionStarted = false
    private var stopped = false
    private var lastRequeued = 0
    private var timer: Task<Void, Never>?

    /// retainFlows keeps the final state of every flow in memory for flowsSnapshot(); for the CLI and tests.
    /// retainDomains does the same for domainsSnapshot(). both are unbounded: never set them in the app
    public init(
        store: sending (any FlowStore)?, session: CaptureSession, flushInterval: TimeInterval = 2,
        retainFlows: Bool = false, retainDomains: Bool = false
    ) {
        self.store = store
        self.session = session
        self.flushInterval = flushInterval
        self.retainFlows = retainFlows
        self.retainDomains = retainDomains
    }

    public var stats: PipelineStats {
        var s = counters
        s.flowsClosed = s.flowsOpened - flowTable.openCount
        return s
    }

    /// final state of every flow seen, only when retainFlows is set. call after stop
    public func flowsSnapshot() -> [Flow] { Array(retained.values) }

    /// every domain observation flushed so far, only when retainDomains is set. call after stop
    public func domainsSnapshot() -> [DomainObservation] { retainedDomains }

    public var tlsGaveUp: Int { extractor.tlsGaveUp }
    public var quicGaveUp: Int { extractor.quicGaveUp }

    /// replays a source to its end. the flows stay open: call stop afterwards
    public func run(_ source: some PacketSource) async throws -> PipelineStats {
        let clock = ContinuousClock()
        let start = clock.now
        var sincePacketFlush = 0
        do {
            if !stopped { try beginSessionIfNeeded() }
            for try await event in source.events() {
                guard !stopped else { break }
                guard case .packet(let raw) = event else { continue }
                process(raw)
                sincePacketFlush += 1
                if sincePacketFlush >= Self.replayFlushPackets {
                    sincePacketFlush = 0
                    try flush()
                }
            }
            try flush()
        } catch {
            // parser errors carry the byte offset; store errors stop the capture. both rethrow
            counters.elapsed += seconds(clock.now - start)
            await stop(reason: .interrupted)
            throw error
        }
        counters.elapsed += seconds(clock.now - start)
        return stats
    }

    /// closes every flow, flushes a last time and ends the session
    public func stop(reason: FlowEndReason) async {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        for flow in flowTable.closeAll(reason: reason) { extractor.flowClosed(flow.key) }
        // save first, clear on success: a failed save keeps its flows queued. retry once, then give up
        do { try flush(final: true) } catch {
            do { try flush(final: true) } catch { counters.unsavedFlows = lastRequeued }
        }
        if let store, sessionStarted {
            do { try store.endSession(id: session.id, at: lastExpire ?? Date(), reason: reason.rawValue) } catch {
                counters.saveFailures += 1
            }
        }
    }

    /// live mode: flushes every flushInterval until stop
    public func startFlushTimer() {
        guard timer == nil, !stopped else { return }
        let interval = flushInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                do { try await self.flushNow() } catch {
                    await self.stop(reason: .interrupted)
                    return
                }
            }
        }
    }

    func flushNow() throws { try flush() }

    private func beginSessionIfNeeded() throws {
        guard let store, !sessionStarted else { return }
        try store.beginSession(session)
        sessionStarted = true
    }

    private func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func process(_ raw: PCAPNGPacket) {
        guard !stopped else { return }
        counters.packets += 1
        counters.interfaces[raw.interface.name ?? "", default: 0] += 1

        let packet: DecodedPacket
        switch decoder.decode(raw) {
        case .failure(.skipped):
            counters.skipped += 1
            return
        case .failure(.malformed):
            counters.malformed += 1
            return
        case .success(let decoded):
            packet = decoded
            counters.decoded += 1
        }

        let transport = packet.headers.transport
        guard transport == .tcp || transport == .udp, packet.localPort != nil, packet.remotePort != nil else {
            counters.droppedNoPort += 1
            return
        }

        let event = flowTable.add(packet)
        if case .opened = event { counters.flowsOpened += 1 }

        for o in extractor.observe(packet) {
            switch o.source {
            case .dns:
                counters.dnsObservations += 1
            case .sni:
                counters.sniFound += 1
                if let key = o.flowKey { flowTable.setServerName(o.hostname, for: key) }
                if o.echPresent, let key = o.flowKey {
                    flowTable.markECH(for: key)
                    counters.echSeen += 1
                }
            }
            pendingDomains.append(o)
        }

        // a reset closes the flow at once, even when it was also the first packet
        if transport == .tcp, packet.headers.tcpFlags?.contains(.rst) == true,
            let local = packet.localPort, let remote = packet.remotePort
        {
            extractor.flowClosed(FlowKey(
                transport: transport, localAddress: packet.localAddress, localPort: local,
                remoteAddress: packet.remoteAddress, remotePort: remote))
        }
        if case .closed(let flow) = event { extractor.flowClosed(flow.key) }

        let now = packet.timestamp
        if let last = lastExpire {
            if now >= last.addingTimeInterval(1) {
                lastExpire = now
                for flow in flowTable.expire(at: now) { extractor.flowClosed(flow.key) }
            }
        } else {
            lastExpire = now
        }
    }

    /// save first, clear on success. final is only set by stop, which has already set stopped
    private func flush(final: Bool = false) throws {
        guard final || !stopped else { return }
        let flows = flowTable.drainDirty()
        if retainFlows { for f in flows { retained[f.id] = f } }
        guard let store else {
            if retainDomains { retainedDomains += pendingDomains }
            pendingDomains.removeAll(keepingCapacity: true)
            return
        }
        guard !flows.isEmpty || !pendingDomains.isEmpty else { return }
        do {
            try beginSessionIfNeeded()
            try store.save(flows: flows, domains: pendingDomains, session: session.id)
        } catch {
            flowTable.requeue(flows)
            lastRequeued = flows.count
            counters.saveFailures += 1
            throw error
        }
        if retainDomains { retainedDomains += pendingDomains }
        pendingDomains.removeAll(keepingCapacity: true)
    }
}
