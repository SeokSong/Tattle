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
    /// dns observations held in the recent ring (at most `CapturePipeline.recentDNSCapacity`)
    public var recentDNSCount = 0
    /// handshake buffers that gave up, by `GaveUpReason` raw value. counts only
    public var handshakeGaveUp: [String: Int] = [:]

    // caps and evictions (see the table in md/PIPELINE.md). every counter is 0 on the five real captures
    /// flows open right now
    public var openFlows = 0
    /// most flows open at once
    public var peakOpenFlows = 0
    /// open flows closed early with end reason `evicted` because the table was full. they are saved
    public var evictedFlows = 0
    /// closed flows lost because saves kept failing until the closed queue was full
    public var droppedClosedFlows = 0
    /// packets counted under the "no process" row because a flow already had 64 process rows
    public var tallyRowsFolded = 0
    /// domain observations waiting for a flush right now
    public var pendingDomains = 0
    /// handshake entries held right now
    public var handshakeStates = 0
    /// most domain observations waiting for a flush at once
    public var peakPendingDomains = 0
    /// domain observations lost because saves kept failing until 40,000 were waiting
    public var droppedDomains = 0
    /// handshake entries removed because the buffer was full (done entries dropped, pending ones finished early)
    public var handshakeStatesDropped = 0
    /// most handshake entries held at once
    public var peakHandshakeStates = 0
    /// closed flows removed from the in-memory retained list (they stay in the database)
    public var retainedDropped = 0
    /// retained domain observations removed from the in-memory list
    public var retainedDomainsDropped = 0
    /// packets counted under the "(other)" interface because 64 interface names were already counted
    public var interfacesFolded = 0

    /// silences longer than `CapturePipeline.gapSeconds` between packets, in packet time (6.2). a locked
    /// phone is a gap, not an end: the session keeps running
    public var gapCount = 0
    /// the longest gap, in seconds of packet time
    public var maxGap: TimeInterval = 0

    /// true when any cap removed or folded something. the live screen's totals are then lower than the truth
    public var anyCapHit: Bool {
        evictedFlows + droppedClosedFlows + tallyRowsFolded + droppedDomains + handshakeStatesDropped
            + retainedDropped + retainedDomainsDropped + interfacesFolded > 0
    }

    public init() {}
}

public actor CapturePipeline {
    /// replay flushes every this many packets
    public static let replayFlushPackets = 5_000

    /// the live screen's dns ring keeps this many answers; the oldest is overwritten
    public static let recentDNSCapacity = 5_000

    /// observations waiting for a flush: reaching this flushes early
    public static let maxPendingDomains = 20_000
    /// a failing save lets the queue grow to this, then the oldest `maxPendingDomains` are dropped
    public static let hardPendingDomains = 40_000
    /// after a failed early flush, the next try comes this many observations later
    public static let domainRetryStep = 5_000
    /// flows kept for `flowsSnapshot()`; past this the oldest closed ones are dropped
    public static let maxRetainedFlows = 50_000
    /// observations kept for `domainsSnapshot()` (CLI and tests only)
    public static let maxRetainedDomains = 200_000
    /// distinct interface names counted in `PipelineStats.interfaces`; later names count as "(other)"
    public static let maxInterfaceNames = 64

    /// a silence strictly longer than this many seconds of packet time is a gap
    public static let gapSeconds: UInt64 = 5

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
    /// fixed-size ring of the latest dns answers; `recentDNSNext` is the slot written next once full
    private var recentDNS: [DomainObservation] = []
    private var recentDNSNext = 0
    private var counters = PipelineStats()
    private var domainFlushAt = CapturePipeline.maxPendingDomains
    private var lastExpire: Date?
    private var sessionStarted = false
    private var kernelDropped: Int?
    private var kernelDroppedProvider: (@Sendable () async -> Int?)?
    private var stopped = false
    private var lastRequeued = 0
    /// packet time of the latest packet in its own interface ticks (0 ticks per second = none yet)
    private var lastTicks: UInt64 = 0
    private var lastTicksPerSecond: UInt64 = 0
    private var timer: Task<Void, Never>?

    /// retainFlows keeps the final state of flows in memory for flowsSnapshot(), at most `maxRetainedFlows`
    /// (the oldest closed ones are dropped and counted). the app uses it for its live list.
    /// retainDomains does the same for domainsSnapshot(), at most `maxRetainedDomains`; CLI and tests only
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
        s.recentDNSCount = recentDNS.count
        s.openFlows = flowTable.openCount
        s.pendingDomains = pendingDomains.count
        s.handshakeStates = extractor.buffer.stateCount
        s.peakOpenFlows = flowTable.peakOpenFlows
        s.evictedFlows = flowTable.evictedFlows
        s.droppedClosedFlows = flowTable.droppedClosedFlows
        s.tallyRowsFolded = flowTable.tallyRowsFolded
        s.handshakeStatesDropped = extractor.handshakeStatesDropped
        s.peakHandshakeStates = extractor.handshakeStatesPeak
        s.handshakeGaveUp = Dictionary(uniqueKeysWithValues: extractor.gaveUpReasons.map { ($0.key.rawValue, $0.value) })
        return s
    }

    /// final state of every flow seen, only when retainFlows is set. call after stop
    public func flowsSnapshot() -> [Flow] { Array(retained.values) }

    /// connections new or changed since the last flush, only when retainFlows is set; nothing is drained or saved.
    /// the live map reads it between flushes so a new connection shows in under a second, not after the next flush
    public func unflushedFlowsSnapshot() -> [Flow] { retainFlows ? flowTable.peekDirty() : [] }

    /// every domain observation flushed so far, only when retainDomains is set. call after stop
    public func domainsSnapshot() -> [DomainObservation] { retainedDomains }

    /// the last `recentDNSCapacity` dns answers, oldest first. always on, dns only, fixed size. the live
    /// screen resolves hostnames from it; the flow's own server name covers sni
    public func dnsSnapshot() -> [DomainObservation] {
        guard recentDNS.count == Self.recentDNSCapacity else { return recentDNS }
        return Array(recentDNS[recentDNSNext...] + recentDNS[..<recentDNSNext])
    }

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

    /// tcpdump's kernel drop count, nil when unknown. set once tcpdump has ended and before `stop`, which
    /// writes the session stats once
    public func setKernelDropped(_ value: Int?) { kernelDropped = value }

    /// asked for the drop count inside `stop`, just before the session stats are written, when none was
    /// set. needed because a source that fails (tcpdump exiting on its own) makes `run` stop the pipeline
    /// before the caller can read tcpdump's summary
    public func setKernelDroppedProvider(_ provider: (@Sendable () async -> Int?)?) { kernelDroppedProvider = provider }

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
        if kernelDropped == nil, let provider = kernelDroppedProvider { kernelDropped = await provider() }
        if let store, sessionStarted {
            do { try store.endSession(id: session.id, at: lastExpire ?? Date(), reason: reason.rawValue) } catch {
                counters.saveFailures += 1
            }
            // last, so the failure counts above are included
            let stats = SessionStats(
                gapCount: counters.gapCount, maxGapMs: Int((counters.maxGap * 1000).rounded()),
                kernelDropped: kernelDropped, saveFailures: counters.saveFailures, unsavedFlows: counters.unsavedFlows)
            do { try store.recordSessionStats(id: session.id, stats) } catch { counters.saveFailures += 1 }
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

    /// internal so tests can feed packets without `run`'s periodic flush
    func process(_ raw: PCAPNGPacket) {
        guard !stopped else { return }
        counters.packets += 1
        trackGap(raw)
        let interfaceName = raw.interface.name ?? ""
        if counters.interfaces.count < Self.maxInterfaceNames || counters.interfaces[interfaceName] != nil {
            counters.interfaces[interfaceName, default: 0] += 1
        } else {
            counters.interfaces["(other)", default: 0] += 1
            counters.interfacesFolded += 1
        }

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
        if flowTable.hasEvictedKeys { for key in flowTable.takeEvictedKeys() { extractor.flowClosed(key) } }

        for o in extractor.observe(packet) {
            switch o.source {
            case .dns:
                counters.dnsObservations += 1
                if recentDNS.count < Self.recentDNSCapacity {
                    recentDNS.append(o)
                } else {
                    recentDNS[recentDNSNext] = o
                    recentDNSNext = (recentDNSNext + 1) % Self.recentDNSCapacity
                }
            case .sni:
                counters.sniFound += 1
                if let key = o.flowKey { flowTable.setServerName(o.hostname, for: key) }
                if o.echPresent, let key = o.flowKey {
                    flowTable.markECH(for: key)
                    counters.echSeen += 1
                }
            }
            pendingDomains.append(o)
            capPendingDomains()
        }

        // a quic flow whose first payload was a short header began before the capture
        for key in extractor.drainMidstreamUDP() { flowTable.markMidstream(for: key) }

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

    /// every packet read counts, decoded or not. integer compare in interface ticks; no allocation.
    /// a backwards timestamp is ignored and does not move the previous time
    @inline(__always)
    private func trackGap(_ raw: PCAPNGPacket) {
        let ticks = raw.rawTimestamp
        let perSecond = raw.interface.ticksPerSecond
        if perSecond != lastTicksPerSecond { rebaseGapClock(to: perSecond) }
        guard lastTicksPerSecond != 0 else { return }
        if ticks > lastTicks {
            if lastTicks != 0, ticks - lastTicks > Self.gapSeconds &* perSecond {
                counters.gapCount += 1
                let seconds = Double(ticks - lastTicks) / Double(perSecond)
                if seconds > counters.maxGap { counters.maxGap = seconds }
            }
            lastTicks = ticks
        }
    }

    /// first packet, or an interface with another timestamp resolution: carry the previous time over
    private func rebaseGapClock(to perSecond: UInt64) {
        if lastTicksPerSecond != 0, lastTicks != 0, perSecond != 0 {
            lastTicks = UInt64(Double(lastTicks) / Double(lastTicksPerSecond) * Double(perSecond))
        }
        lastTicksPerSecond = perSecond
    }

    /// keeps the pending queue bounded: flush early at `maxPendingDomains`; if saves keep failing, drop the oldest
    /// `maxPendingDomains` at `hardPendingDomains`. a failed early flush is retried every `domainRetryStep`
    /// observations, not on every packet. the failure itself is counted and rethrown by the next regular flush
    private func capPendingDomains() {
        let count = pendingDomains.count
        if count > counters.peakPendingDomains { counters.peakPendingDomains = count }
        if count >= Self.hardPendingDomains {
            pendingDomains.removeFirst(Self.maxPendingDomains)
            counters.droppedDomains += Self.maxPendingDomains
            domainFlushAt = pendingDomains.count + Self.domainRetryStep
        } else if count >= domainFlushAt {
            do { try flush() } catch { domainFlushAt = pendingDomains.count + Self.domainRetryStep }
        }
    }

    /// drops the oldest closed flows (by last packet) until `retained` is back at its cap
    private func trimRetained() {
        let excess = retained.count - Self.maxRetainedFlows
        guard excess > 0 else { return }
        let victims = retained.values.filter { $0.endReason != nil }.sorted { $0.lastSeen < $1.lastSeen }.prefix(excess)
        for flow in victims { retained[flow.id] = nil }
        counters.retainedDropped += victims.count
    }

    private func retain(domains: [DomainObservation]) {
        guard retainDomains else { return }
        retainedDomains += domains
        let excess = retainedDomains.count - Self.maxRetainedDomains
        if excess > 0 {
            retainedDomains.removeFirst(excess)
            counters.retainedDomainsDropped += excess
        }
    }

    /// save first, clear on success. final is only set by stop, which has already set stopped
    private func flush(final: Bool = false) throws {
        guard final || !stopped else { return }
        let flows = flowTable.drainDirty()
        if retainFlows {
            for f in flows { retained[f.id] = f }
            trimRetained()
        }
        guard let store else {
            retain(domains: pendingDomains)
            pendingDomains.removeAll(keepingCapacity: true)
            domainFlushAt = Self.maxPendingDomains
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
        retain(domains: pendingDomains)
        pendingDomains.removeAll(keepingCapacity: true)
        domainFlushAt = Self.maxPendingDomains
    }
}
