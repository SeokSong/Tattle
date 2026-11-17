import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Storage
import Testing
import TestSupport

@testable import Pipeline

private let phone: [UInt8] = [10, 0, 0, 2]
private let base: UInt64 = 1_763_000_000

private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

private struct Pkt {
    var out = true
    var at: Double = 0
    var proto: UInt8 = 6
    var remote: [UInt8] = [93, 184, 216, 34]
    var remotePort = 443
    var flags: UInt8 = 0x18
    var payload: [UInt8] = []
    var process: UInt32? = 0
}

private func frame(_ p: Pkt) -> [UInt8] {
    let (src, dst) = p.out ? (phone, p.remote) : (p.remote, phone)
    let (sp, dp) = p.out ? (50000, p.remotePort) : (p.remotePort, 50000)
    var l4: [UInt8]
    switch p.proto {
    case 6: l4 = be16(sp) + be16(dp) + [0, 0, 0, 0, 0, 0, 0, 0, 0x50, p.flags, 0, 0, 0, 0, 0, 0]
    case 17: l4 = be16(sp) + be16(dp) + be16(8 + p.payload.count) + [0, 0]
    default: l4 = [8, 0, 0, 0]
    }
    l4 += p.payload
    let ip: [UInt8] = [0x45, 0] + be16(20 + l4.count) + [0, 0, 0, 0, 64, p.proto, 0, 0] + src + dst + l4
    return [UInt8](repeating: 0, count: 12) + [8, 0] + ip
}

private func capture(_ pkts: [Pkt], extraFrames: [(Double, [UInt8])] = []) -> [UInt8] {
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("en0")
    bytes += PCAPNGBuilder.process(pid: 7, name: "TikTok")
    var all: [(Double, [UInt8], UInt32?)] = pkts.map { ($0.at, frame($0), $0.out ? 2 : 1) }
    all += extraFrames.map { ($0.0, $0.1, 2) }
    for (at, f, dir) in all.sorted(by: { $0.0 < $1.0 }) {
        bytes += PCAPNGBuilder.packet(
            interface: 0, microseconds: UInt64((Double(base) + at) * 1_000_000),
            process: 0, flags: dir, payload: f)
    }
    return bytes
}

private func clientHello(sni: String) -> [UInt8] {
    let name = Array(sni.utf8)
    let list = [0] + be16(name.count) + name
    let exts: [UInt8] = be16(0) + be16(list.count + 2) + be16(list.count) + list
    var body: [UInt8] = [3, 3] + [UInt8](repeating: 7, count: 32) + [0]
    body += be16(4) + [0x13, 0x01, 0x13, 0x02] + [1, 0] + be16(exts.count) + exts
    let hs: [UInt8] = [1, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    return [22, 3, 1] + be16(hs.count) + hs
}

private func dnsAnswer(_ host: String, address: [UInt8]) -> [UInt8] {
    var name: [UInt8] = []
    for label in host.split(separator: ".") { name += [UInt8(label.utf8.count)] + Array(label.utf8) }
    name.append(0)
    var m: [UInt8] = be16(0x1234) + be16(0x8180) + be16(1) + be16(1) + be16(0) + be16(0)
    m += name + be16(1) + be16(1)
    m += [0xC0, 12] + be16(1) + be16(1) + [0, 0, 1, 0x2C] + be16(4) + address
    return m
}

private func scenario() -> [UInt8] {
    let hello = clientHello(sni: "example.com")
    let cut = hello.count / 2
    return capture(
        [
            Pkt(at: 0, proto: 17, remote: [8, 8, 8, 8], remotePort: 53, payload: [1, 2, 3]),
            Pkt(out: false, at: 0.1, proto: 17, remote: [8, 8, 8, 8], remotePort: 53,
                payload: dnsAnswer("example.com", address: [93, 184, 216, 34])),
            Pkt(at: 0.2, flags: 0x02),
            Pkt(at: 0.3, payload: Array(hello[..<cut])),
            Pkt(at: 0.4, payload: Array(hello[cut...])),
            Pkt(out: false, at: 0.5, payload: [9, 9, 9]),
            Pkt(at: 1, proto: 17, remote: [1, 1, 1, 1], remotePort: 9999, payload: [5, 5]),
            Pkt(at: 2, proto: 1, remote: [1, 1, 1, 1]),
        ],
        extraFrames: [
            (0.6, [UInt8](repeating: 0, count: 12) + [8, 6] + [0, 1, 2, 3]),  // arp: skipped
            (0.7, [UInt8](repeating: 0, count: 12) + [8, 0] + [0x45, 0]),  // short ip: malformed
        ])
}

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString).sqlite")
}

private func session() -> CaptureSession {
    CaptureSession(id: UUID(), startedAt: Date(timeIntervalSince1970: Double(base)), source: "test", watchVersion: "test")
}

@Test func replayBuildsFlowsServerNameAndDomains() async throws {
    let pipeline = CapturePipeline(store: nil, session: session(), retainFlows: true)
    let stats = try await pipeline.run(DataPacketSource(scenario(), chunkSize: 97))
    await pipeline.stop(reason: .captureStopped)

    #expect(stats.packets == 10)
    #expect(stats.droppedNoPort == 1)
    #expect(stats.dnsObservations == 1)
    #expect(stats.sniFound == 1)
    #expect(stats.interfaces == ["en0": 10])

    let flows = await pipeline.flowsSnapshot()
    #expect(flows.count == 3)
    let tls = try #require(flows.first { $0.key.remotePort == 443 })
    #expect(tls.serverName == "example.com")
    #expect(tls.packetsOut == 3 && tls.packetsIn == 1)
    #expect(tls.endReason == .captureStopped)
    let udp = try #require(flows.first { $0.key.remotePort == 9999 })
    #expect(udp.serverName == nil && udp.packetsOut == 1)
    let final = await pipeline.stats
    #expect(final.flowsOpened == 3 && final.flowsClosed == 3)
}

@Test func statsAddUp() async throws {
    let pipeline = CapturePipeline(store: nil, session: session())
    let s = try await pipeline.run(DataPacketSource(scenario()))
    #expect(s.packets == s.decoded + s.skipped + s.malformed)
    #expect(s.skipped == 1 && s.malformed == 1 && s.decoded == 8)
    #expect(s.elapsed > 0)
}

@Test func flushWritesWhatTheStoreReadsBack() async throws {
    let path = tempDB()
    defer { try? FileManager.default.removeItem(at: path) }
    let s = session()
    let store = try Store(path: path)
    let pipeline = CapturePipeline(store: store, session: s, retainFlows: true)
    _ = try await pipeline.run(DataPacketSource(scenario()))
    await pipeline.stop(reason: .captureStopped)

    let reader = try Store(path: path)
    let stored = try reader.flows(session: s.id)
    let memory = await pipeline.flowsSnapshot()
    #expect(stored.count == memory.count)
    #expect(Set(stored.map(\.id)) == Set(memory.map(\.id)))
    #expect(stored.first { $0.key.remotePort == 443 }?.serverName == "example.com")
    #expect(stored.allSatisfy { $0.endReason == .captureStopped })

    let domains = try reader.domains(session: s.id)
    #expect(domains.filter { $0.source == .dns }.count == 1)
    #expect(domains.filter { $0.source == .sni }.count == 1)
}

@Test func idleFlowsExpireOnPacketTime() async throws {
    let data = capture([
        Pkt(at: 0, payload: [1]),
        Pkt(at: 200, proto: 17, remote: [1, 1, 1, 1], remotePort: 9999, payload: [1]),
        Pkt(at: 201, proto: 17, remote: [1, 1, 1, 1], remotePort: 9999, payload: [1]),
    ])
    let pipeline = CapturePipeline(store: nil, session: session())
    let s = try await pipeline.run(DataPacketSource(data))
    #expect(s.flowsOpened == 2)
    #expect(await pipeline.stats.flowsClosed == 1)
}

@Test func parserErrorRethrows() async throws {
    var data = scenario()
    data[data.count - 3] ^= 0xFF  // break the last block's trailing length
    let pipeline = CapturePipeline(store: nil, session: session())
    await #expect(throws: (any Error).self) {
        _ = try await pipeline.run(DataPacketSource(data))
    }
}

@Test func fixturesRunToTheTrailer() async throws {
    for name in Fixtures.all {
        guard let url = Fixtures.url(name) else { return }
        let pipeline = CapturePipeline(store: nil, session: session())
        let s = try await pipeline.run(FilePacketSource(url: url))
        await pipeline.stop(reason: .captureStopped)
        #expect(s.packets > 0)
        #expect(s.packets == s.decoded + s.skipped + s.malformed)
        #expect(await pipeline.stats.flowsClosed == s.flowsOpened)
    }
}

// a store that fails its first `failures` saves, then records
private final class FailingStore: FlowStore, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private(set) var saved: [Flow] = []
    private(set) var endSessionCalls = 0
    // flows saved after endSession was attempted
    private(set) var savedAfterEnd = 0

    init(failures: Int) { remaining = failures }

    struct Failure: Error {}

    func beginSession(_ s: CaptureSession) throws {}

    func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if remaining > 0 {
            remaining -= 1
            throw Failure()
        }
        if endSessionCalls > 0 { savedAfterEnd += flows.count }
        saved += flows
    }

    func endSession(id: UUID, at: Date, reason: String) throws {
        lock.lock()
        defer { lock.unlock() }
        endSessionCalls += 1
    }
}

private final class AlwaysFailingStore: FlowStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var endSessionCalls = 0
    func beginSession(_ s: CaptureSession) throws {}
    func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws {
        throw FailingStore.Failure()
    }
    func endSession(id: UUID, at: Date, reason: String) throws {
        lock.lock()
        defer { lock.unlock() }
        endSessionCalls += 1
    }
}

// three tcp flows, each closed by a reset, so they are closed before the first flush
private func resetFlows() -> [UInt8] {
    capture((0..<3).map { Pkt(at: Double($0) * 0.1, remote: [93, 184, 216, UInt8(30 + $0)], flags: 0x04) })
}

@Test func failedSaveKeepsFlows() async throws {
    let store = FailingStore(failures: 1)
    let pipeline = CapturePipeline(store: store, session: session())
    // the end-of-replay flush throws once; run stops, and the final flush retries
    await #expect(throws: (any Error).self) {
        _ = try await pipeline.run(DataPacketSource(resetFlows()))
    }
    let ids = store.saved.map(\.id)
    #expect(ids.count == 3)
    #expect(Set(ids).count == 3)
    #expect(store.saved.allSatisfy { $0.endReason == .rst })
    let s = await pipeline.stats
    #expect(s.saveFailures == 1 && s.unsavedFlows == 0)
}

@Test func finalSaveFailureIsCounted() async throws {
    let store = AlwaysFailingStore()
    let pipeline = CapturePipeline(store: store, session: session())
    await #expect(throws: (any Error).self) {
        _ = try await pipeline.run(DataPacketSource(resetFlows()))
    }
    let s = await pipeline.stats
    #expect(s.unsavedFlows == 3)
    #expect(s.saveFailures >= 1)
    #expect(store.endSessionCalls == 1)
}

@Test func nothingProcessedAfterStop() async throws {
    let store = FailingStore(failures: 0)
    let pipeline = CapturePipeline(store: store, session: session())
    _ = try await pipeline.run(DataPacketSource(capture([
        Pkt(at: 0, payload: [1]), Pkt(at: 0.1, proto: 17, remote: [1, 1, 1, 1], remotePort: 9999, payload: [1]),
    ])))
    await pipeline.stop(reason: .captureStopped)
    let before = store.saved.count
    let idsBefore = Set(store.saved.map(\.id))
    _ = try await pipeline.run(DataPacketSource(capture([
        Pkt(at: 1, proto: 17, remote: [2, 2, 2, 2], remotePort: 9998, payload: [1]),
    ])))
    let s = await pipeline.stats
    #expect(s.packets == 2)
    #expect(store.saved.count == before && idsBefore.count == 2)
    #expect(store.savedAfterEnd == 0)
    #expect(store.endSessionCalls == 1)
}

@Test func backwardTimestampDoesNotExpire() async throws {
    // capture() sorts by time, so write the frames in the given order by hand
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("en0")
    bytes += PCAPNGBuilder.process(pid: 7, name: "TikTok")
    for at in [10.0, 2.0, 2.5, 3.5] {
        let f = frame(Pkt(at: at, proto: 17, remote: [1, 1, 1, 1], remotePort: 9999, payload: [1]))
        bytes += PCAPNGBuilder.packet(
            interface: 0, microseconds: UInt64((Double(base) + at) * 1_000_000),
            process: 0, flags: 2, payload: f)
    }
    let pipeline = CapturePipeline(store: nil, session: session())
    let s = try await pipeline.run(DataPacketSource(bytes))
    #expect(s.flowsOpened == 1)
    #expect(await pipeline.stats.flowsClosed == 0)
}

@Test func syntheticThroughput() async throws {
    let count = 200_000
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("en0")
    bytes += PCAPNGBuilder.process(pid: 7, name: "TikTok")
    for i in 0..<count {
        let f = frame(Pkt(
            at: 0, proto: 17, remote: [93, 184, UInt8(i % 50), UInt8(i % 200)],
            remotePort: 9999, payload: [1, 2, 3, 4]))
        bytes += PCAPNGBuilder.packet(
            interface: 0, microseconds: UInt64(base) * 1_000_000 + UInt64(i) * 500,
            process: 0, flags: 2, payload: f)
    }
    let pipeline = CapturePipeline(store: nil, session: session())
    let clock = ContinuousClock()
    let start = clock.now
    let s = try await pipeline.run(DataPacketSource(bytes))
    let d = clock.now - start
    let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    let rate = Double(count) / secs
    print("synthetic throughput: \(Int(rate)) packets/s")
    #expect(s.packets == count)
    #expect(rate > 50_000)
}
