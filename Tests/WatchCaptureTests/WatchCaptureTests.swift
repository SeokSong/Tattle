import Foundation
import Testing
import TestSupport
@testable import PCAPNG

private typealias B = PCAPNGBuilder

// MARK: - Tests

@Test func readsInterfacesInOrder() throws {
    let capture = try PCAPNGReader.parse(Data(B.sampleCapture() + B.pcapTrailer))

    #expect(capture.interfaces.map(\.name) == ["en0", "en2", "utun4"])
    #expect(capture.interfaces.map(\.linkType) == [1, 1, 0])
}

@Test func readsPacketMetadata() throws {
    let capture = try PCAPNGReader.parse(Data(B.sampleCapture() + B.pcapTrailer))

    #expect(capture.packets.count == 3)
    #expect(capture.packets.map { $0.interface.name } == ["en0", "en2", "utun4"])
    #expect(capture.packets[1].timestamp.timeIntervalSince1970 == 1_763_000_000.5)

    #expect(capture.packets[0].process == nil)
    #expect(capture.packets[1].process == PCAPNGProcess(pid: 212, name: "mDNSResponder"))
    #expect(capture.packets[2].effectiveProcess == PCAPNGProcess(pid: 19_475, name: "TikTok"))
    #expect(capture.unresolvedProcessReferences == 0)
}

@Test func stopsAtPcapTrailer() throws {
    let withTrailer = try PCAPNGReader.parse(Data(B.sampleCapture() + B.pcapTrailer))
    #expect(withTrailer.endedWithPcapTrailer)

    let withoutTrailer = try PCAPNGReader.parse(Data(B.sampleCapture()))
    #expect(!withoutTrailer.endedWithPcapTrailer)
    #expect(withoutTrailer.packets.count == 3)
}

@Test func rejectsTruncatedBlock() throws {
    let bytes = B.sampleCapture()
    let truncated = Array(bytes.dropLast(10))

    #expect(throws: PCAPNGError.self) {
        try PCAPNGReader.parse(Data(truncated))
    }
}

@Test func rejectsNonPCAPNG() throws {
    #expect(throws: PCAPNGError.notPCAPNG) {
        try PCAPNGReader.parse(Data(B.pcapTrailer))
    }
}

@Test func countsUnresolvedProcessReferences() throws {
    let bytes = B.sectionHeader()
        + B.interface("en0")
        + B.packet(interface: 0, microseconds: 0, process: 5)

    let capture = try PCAPNGReader.parse(Data(bytes))

    #expect(capture.packets[0].process == nil)
    #expect(capture.unresolvedProcessReferences == 1)
}

// MARK: - Stream parser

private func collect(_ chunks: [[UInt8]]) throws -> (events: [PCAPNGEvent], end: PCAPNGEnd) {
    var parser = PCAPNGStreamParser()
    var events: [PCAPNGEvent] = []
    for chunk in chunks {
        events += try parser.append(chunk)
    }
    return (events, try parser.finish())
}

private func describe(_ event: PCAPNGEvent) -> String {
    switch event {
    case .sectionStarted: return "section"
    case .interface(let i): return "interface \(i.id) \(i.name ?? "-")"
    case .process(let p): return "process \(p.pid) \(p.name ?? "-")"
    case .packet(let p):
        return "packet \(p.interface.id) \(p.rawTimestamp) \(p.data) \(String(describing: p.flags)) \(p.process?.pid ?? 0) \(p.effectiveProcess?.pid ?? 0)"
    case .end(let e): return "end \(e)"
    }
}

@Test func streamOneByteAtATimeMatchesOneShot() throws {
    let bytes = B.sampleCapture() + B.pcapTrailer

    let oneShot = try collect([bytes])
    let bytewise = try collect(bytes.map { [$0] })

    #expect(oneShot.events.map(describe) == bytewise.events.map(describe))
    #expect(oneShot.events.count == 9)
    #expect(bytewise.end == .pcapTrailer)
}

@Test func streamHandlesChunkBoundaries() throws {
    let bytes = B.sampleCapture() + B.pcapTrailer
    let expected = try collect([bytes]).events.map(describe)

    // cuts: inside a block header, inside the options of the first packet, inside the trailer
    let header = B.sectionHeader().count
    let firstPacket = header + B.interface("en0").count
    let cuts = [header + 3, firstPacket + 40, bytes.count - 10]

    for cut in cuts {
        let result = try collect([Array(bytes[..<cut]), Array(bytes[cut...])])
        #expect(result.events.map(describe) == expected)
        #expect(result.end == .pcapTrailer)
    }
}

@Test func streamRejectsBytesAfterTrailer() throws {
    var parser = PCAPNGStreamParser()
    _ = try parser.append(B.sampleCapture() + B.pcapTrailer)

    #expect(throws: PCAPNGError.self) {
        try parser.append([0])
    }
}

@Test func finishThrowsOnHalfBlock() throws {
    let bytes = B.sampleCapture()
    var parser = PCAPNGStreamParser()
    _ = try parser.append(bytes.dropLast(10))

    let expected = bytes.count - B.packet(interface: 2, microseconds: 0, process: 0, effective: 1).count
    #expect(throws: PCAPNGError.truncatedBlock(offset: expected)) {
        try parser.finish()
    }
}

@Test func finishWithoutTrailerIsCleanEnd() throws {
    #expect(try collect([B.sampleCapture()]).end == .cleanEnd)
}

@Test func directionFromFlags() throws {
    let bytes = B.sectionHeader() + B.interface("en0")
        + B.packet(interface: 0, microseconds: 0, process: nil, flags: 1)
        + B.packet(interface: 0, microseconds: 0, process: nil, flags: 2)
        + B.packet(interface: 0, microseconds: 0, process: nil, flags: 0)
        + B.packet(interface: 0, microseconds: 0, process: nil)

    let packets = try PCAPNGReader.parse(Data(bytes)).packets

    #expect(packets.map(\.direction) == [.inbound, .outbound, .unknown, .unknown])
    #expect(packets.map(\.flags) == [1, 2, 0, nil])
}

@Test func packetDataMatchesCapturedLength() throws {
    let payload: [UInt8] = [9, 8, 7, 6, 5, 4, 3]
    let bytes = B.sectionHeader() + B.interface("en0")
        + B.packet(interface: 0, microseconds: 0, process: nil, payload: payload)

    let capture = try PCAPNGReader.parse(Data(bytes))

    #expect(capture.packets[0].data == payload)
    #expect(capture.packets.allSatisfy { $0.data.count == $0.capturedLength })
}

@Test func dataPacketSourceYieldsEventsAndEnd() async throws {
    var events: [PCAPNGEvent] = []
    for try await event in DataPacketSource(B.sampleCapture() + B.pcapTrailer, chunkSize: 7).events() {
        events.append(event)
    }

    #expect(events.map(describe) == (try collect([B.sampleCapture() + B.pcapTrailer]).events.map(describe)) + ["end pcapTrailer"])
}

@Test func filePacketSourceReadsCleanFixture() async throws {
    guard let url = Fixtures.url("watch-clean-test.pcap") else { return }

    var packets = 0
    var end: PCAPNGEnd?
    for try await event in FilePacketSource(url: url).events() {
        switch event {
        case .packet: packets += 1
        case .end(let e): end = e
        default: break
        }
    }

    #expect(packets == 1_292)
    #expect(end == .pcapTrailer)
}

// MARK: - FileHandlePacketSource

@Test func fileHandleSourceReadsPipeAndTees() async throws {
    let bytes = B.sampleCapture() + B.pcapTrailer
    let pipe = Pipe()
    let teeURL = FileManager.default.temporaryDirectory.appendingPathComponent("tee-" + UUID().uuidString)
    FileManager.default.createFile(atPath: teeURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: teeURL) }
    let tee = try FileHandle(forWritingTo: teeURL)

    let source = FileHandlePacketSource(handle: pipe.fileHandleForReading, tee: tee)
    let writer = pipe.fileHandleForWriting
    // write in small pieces so blocks straddle reads
    DispatchQueue.global().async {
        for start in stride(from: 0, to: bytes.count, by: 37) {
            try? writer.write(contentsOf: Data(bytes[start..<min(start + 37, bytes.count)]))
        }
        try? writer.close()
    }

    var packets = 0
    var end: PCAPNGEnd?
    for try await event in source.events() {
        switch event {
        case .packet: packets += 1
        case .end(let e): end = e
        default: break
        }
    }
    #expect(packets == 3)
    #expect(end == .pcapTrailer)
    #expect(source.end == .pcapTrailer)
    #expect(try Data(contentsOf: teeURL) == Data(bytes))
}

@Test func fileHandleSourceTruncationThrowsUnlessTolerated() async throws {
    let bytes = Array((B.sampleCapture()).dropLast(5))

    for tolerate in [false, true] {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(bytes))
        try pipe.fileHandleForWriting.close()
        let source = FileHandlePacketSource(handle: pipe.fileHandleForReading, tolerateTruncation: tolerate)
        var threw = false
        do { for try await _ in source.events() {} } catch { threw = true }
        #expect(threw == !tolerate)
    }
}

// MARK: - Caps

@Test func streamRejectsOversizeBlockInsteadOfWaiting() throws {
    var parser = PCAPNGStreamParser()
    let huge = UInt32(PCAPNGStreamParser.maxBlockLength + 4)
    // a header that claims a 16 MB block: the parser fails at once, it does not buffer toward it
    #expect(throws: PCAPNGError.self) {
        try parser.append(B.sectionHeader() + B.le32(6) + B.le32(huge) + B.le32(0))
    }
}

@Test func streamCapsSkippedTypesAndProcessTable() throws {
    var bytes = B.sectionHeader()
    for i in 0..<70 { bytes += B.block(0x100 + UInt32(i), [0, 0, 0, 0]) }
    for i in 0..<(PCAPNGStreamParser.maxSectionProcesses + 5) { bytes += B.process(pid: UInt32(i), name: "p") }
    var parser = PCAPNGStreamParser()
    let events = try parser.append(bytes)
    #expect(parser.skippedBlocks.count == PCAPNGStreamParser.maxSkippedBlockTypes + 1)
    #expect(parser.skippedBlocks[UInt32.max] == 6)
    #expect(parser.skippedBlocks.values.reduce(0, +) == 70)
    // every process block is still an event; only the lookup table stops growing
    #expect(events.filter { if case .process = $0 { true } else { false } }.count == PCAPNGStreamParser.maxSectionProcesses + 5)
    #expect(parser.processBlocksDropped == 5)
}
