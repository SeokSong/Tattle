import Foundation

// incremental pcapng parser. feed it bytes in any chunking; it returns events as soon as
// whole blocks are available and holds back the tail until more bytes (or finish()) arrive.
// after a thrown error the parser must not be reused.

// MARK: - Events

public enum PCAPNGEvent: Sendable {
    case sectionStarted
    case interface(PCAPNGInterface)
    case process(PCAPNGProcess)
    case packet(PCAPNGPacket)
    /// sent last by a PacketSource, once the stream has ended
    case end(PCAPNGEnd)
}

public enum PCAPNGEnd: Sendable, Equatable {
    /// the data ended exactly on a block boundary
    case cleanEnd
    /// the data ended with the 24-byte classic pcap header tcpdump appends
    case pcapTrailer
}

// MARK: - Block and option codes

private enum BlockType {
    static let sectionHeader: UInt32 = 0x0A0D_0D0A
    static let interfaceDescription: UInt32 = 0x0000_0001
    static let enhancedPacket: UInt32 = 0x0000_0006
    // apple extension (libpcap in macOS)
    static let processInformation: UInt32 = 0x8000_0001
}

private enum OptionCode {
    static let endOfOptions: UInt16 = 0
    static let interfaceName: UInt16 = 2
    static let interfaceTimestampResolution: UInt16 = 9
    static let processName: UInt16 = 2
    static let packetFlags: UInt16 = 2
    // apple epb extensions
    static let processIndex: UInt16 = 0x8001
    static let effectiveProcessIndex: UInt16 = 0x8003
}

private let byteOrderMagic: UInt32 = 0x1A2B_3C4D
private let compactionThreshold = 1 << 20

// classic pcap magics as read little-endian: usec/nsec, both byte orders
private let pcapHeaderLength = 24

private func isPcapHeaderMagic(_ value: UInt32) -> Bool {
    value == 0xA1B2_C3D4 || value == 0xD4C3_B2A1 || value == 0xA1B2_3C4D || value == 0x4D3C_B2A1
}

// MARK: - Parser

public struct PCAPNGStreamParser: Sendable {
    /// a block longer than this is treated as corrupt (`badBlockLength`) instead of waiting for its bytes
    public static let maxBlockLength = 16 * 1024 * 1024
    /// process blocks remembered per section; later ones are still returned as events but cannot be
    /// referenced by packets (those count in `unresolvedProcessReferences`)
    public static let maxSectionProcesses = 100_000
    /// distinct skipped block types counted separately in `skippedBlocks`
    public static let maxSkippedBlockTypes = 64

    // unparsed bytes start at `offset`; consumed bytes stay until the prefix passes 1 MB
    private var buffer: [UInt8] = []
    private var offset = 0
    // bytes already dropped by compaction, so error offsets stay absolute
    private var droppedBytes = 0

    private var bigEndian = false
    private var started = false

    // interface ids and process indices are scoped to a section
    private var sectionInterfaces: [PCAPNGInterface] = []
    private var sectionProcesses: [PCAPNGProcess] = []

    /// every interface seen, across all sections
    public private(set) var interfaces: [PCAPNGInterface] = []
    /// block types this parser skips, with how often they appeared
    public private(set) var skippedBlocks: [UInt32: Int] = [:]
    /// packets whose process index pointed at a process block not seen yet
    public private(set) var unresolvedProcessReferences = 0
    /// process blocks not remembered because the section already had `maxSectionProcesses`
    public private(set) var processBlocksDropped = 0

    public init() {}

    /// feeds more bytes. returns every complete event found, in order
    public mutating func append(_ bytes: some Collection<UInt8>) throws -> [PCAPNGEvent] {
        buffer.append(contentsOf: bytes)

        var events: [PCAPNGEvent] = []

        while true {
            let remaining = buffer.count - offset

            guard remaining >= 4 else { break }

            let firstWord = littleEndian32(at: offset)

            if !started, firstWord != BlockType.sectionHeader {
                throw PCAPNGError.notPCAPNG
            }

            // a pcap magic where a block should start is the trailer: wait for finish()
            if isPcapHeaderMagic(firstWord) {
                if remaining > pcapHeaderLength {
                    throw PCAPNGError.badBlockLength(offset: droppedBytes + offset, length: littleEndian32(at: offset + 4))
                }
                break
            }

            guard remaining >= 12 else { break }

            // the shb type is a palindrome, so it can be recognised before endianness is known
            if firstWord == BlockType.sectionHeader {
                try readByteOrder(sectionAt: offset)
            }

            let rawLength = u32(at: offset + 4)
            let length = Int(rawLength)

            guard length >= 12, length % 4 == 0, length <= Self.maxBlockLength else {
                throw PCAPNGError.badBlockLength(offset: droppedBytes + offset, length: rawLength)
            }
            // hold the block back until it is complete
            guard length <= remaining else { break }
            guard u32(at: offset + length - 4) == rawLength else {
                throw PCAPNGError.trailingLengthMismatch(offset: droppedBytes + offset)
            }

            let type = u32(at: offset)
            let body = (offset + 8)..<(offset + length - 4)

            switch type {
            case BlockType.sectionHeader:
                started = true
                sectionInterfaces.removeAll()
                sectionProcesses.removeAll()
                events.append(.sectionStarted)
            case BlockType.interfaceDescription:
                events.append(.interface(try readInterface(body: body, blockOffset: offset)))
            case BlockType.enhancedPacket:
                events.append(.packet(try readPacket(body: body, blockOffset: offset)))
            case BlockType.processInformation:
                events.append(.process(try readProcess(body: body, blockOffset: offset)))
            default:
                // distinct skipped types are capped; the rest count under UInt32.max
                let slot = skippedBlocks[type] != nil || skippedBlocks.count < Self.maxSkippedBlockTypes ? type : UInt32.max
                skippedBlocks[slot, default: 0] += 1
            }

            offset += length
        }

        compactIfNeeded()
        return events
    }

    /// call at end of stream. checks the held-back tail
    public mutating func finish() throws -> PCAPNGEnd {
        guard started else {
            throw PCAPNGError.notPCAPNG
        }

        let remaining = buffer.count - offset

        if remaining == 0 {
            return .cleanEnd
        }
        if remaining == pcapHeaderLength, isPcapHeaderMagic(littleEndian32(at: offset)) {
            return .pcapTrailer
        }
        throw PCAPNGError.truncatedBlock(offset: droppedBytes + offset)
    }

    private mutating func compactIfNeeded() {
        guard offset > compactionThreshold else { return }
        buffer.removeSubrange(0..<offset)
        droppedBytes += offset
        offset = 0
    }

    // MARK: blocks

    private mutating func readByteOrder(sectionAt offset: Int) throws {
        switch littleEndian32(at: offset + 8) {
        case byteOrderMagic:
            bigEndian = false
        case byteOrderMagic.byteSwapped:
            bigEndian = true
        default:
            throw PCAPNGError.badByteOrderMagic(offset: droppedBytes + offset)
        }
    }

    private mutating func readInterface(body: Range<Int>, blockOffset: Int) throws -> PCAPNGInterface {
        guard body.count >= 8 else {
            throw PCAPNGError.malformedBlock(offset: droppedBytes + blockOffset, type: BlockType.interfaceDescription)
        }

        var name: String?
        var ticksPerSecond: UInt64 = 1_000_000

        for option in try options(in: (body.lowerBound + 8)..<body.upperBound, blockOffset: blockOffset) {
            switch option.code {
            case OptionCode.interfaceName:
                name = string(in: option.value)
            case OptionCode.interfaceTimestampResolution where option.value.count >= 1:
                ticksPerSecond = Self.ticksPerSecond(resolution: buffer[option.value.lowerBound])
            default:
                break
            }
        }

        let interface = PCAPNGInterface(
            id: sectionInterfaces.count,
            name: name,
            linkType: u16(at: body.lowerBound),
            snapLength: u32(at: body.lowerBound + 4),
            ticksPerSecond: ticksPerSecond
        )

        sectionInterfaces.append(interface)
        interfaces.append(interface)
        return interface
    }

    private mutating func readProcess(body: Range<Int>, blockOffset: Int) throws -> PCAPNGProcess {
        guard body.count >= 4 else {
            throw PCAPNGError.malformedBlock(offset: droppedBytes + blockOffset, type: BlockType.processInformation)
        }

        var name: String?

        for option in try options(in: (body.lowerBound + 4)..<body.upperBound, blockOffset: blockOffset)
        where option.code == OptionCode.processName {
            name = string(in: option.value)
        }

        let process = PCAPNGProcess(pid: u32(at: body.lowerBound), name: name)

        if sectionProcesses.count < Self.maxSectionProcesses {
            sectionProcesses.append(process)
        } else {
            processBlocksDropped += 1
        }
        return process
    }

    private mutating func readPacket(body: Range<Int>, blockOffset: Int) throws -> PCAPNGPacket {
        guard body.count >= 20 else {
            throw PCAPNGError.malformedBlock(offset: droppedBytes + blockOffset, type: BlockType.enhancedPacket)
        }

        let start = body.lowerBound
        let interfaceID = u32(at: start)
        let timestampHigh = UInt64(u32(at: start + 4))
        let timestampLow = UInt64(u32(at: start + 8))
        let capturedLength = Int(u32(at: start + 12))
        let originalLength = Int(u32(at: start + 16))

        guard Int(interfaceID) < sectionInterfaces.count else {
            throw PCAPNGError.unknownInterface(offset: droppedBytes + blockOffset, id: interfaceID)
        }

        let dataStart = start + 20
        let optionsStart = dataStart + padded(capturedLength)
        guard optionsStart <= body.upperBound else {
            throw PCAPNGError.malformedBlock(offset: droppedBytes + blockOffset, type: BlockType.enhancedPacket)
        }

        var process: PCAPNGProcess?
        var effectiveProcess: PCAPNGProcess?
        var flags: UInt32?

        for option in try options(in: optionsStart..<body.upperBound, blockOffset: blockOffset)
        where option.value.count >= 4 {
            switch option.code {
            case OptionCode.packetFlags:
                flags = u32(at: option.value.lowerBound)
            case OptionCode.processIndex:
                process = resolveProcess(index: u32(at: option.value.lowerBound))
            case OptionCode.effectiveProcessIndex:
                effectiveProcess = resolveProcess(index: u32(at: option.value.lowerBound))
            default:
                break
            }
        }

        return PCAPNGPacket(
            interface: sectionInterfaces[Int(interfaceID)],
            rawTimestamp: timestampHigh << 32 | timestampLow,
            capturedLength: capturedLength,
            originalLength: originalLength,
            data: Array(buffer[dataStart..<(dataStart + capturedLength)]),
            flags: flags,
            process: process,
            effectiveProcess: effectiveProcess
        )
    }

    private mutating func resolveProcess(index: UInt32) -> PCAPNGProcess? {
        guard Int(index) < sectionProcesses.count else {
            unresolvedProcessReferences += 1
            return nil
        }
        return sectionProcesses[Int(index)]
    }

    // MARK: options

    private func options(in range: Range<Int>, blockOffset: Int) throws -> [(code: UInt16, value: Range<Int>)] {
        var result: [(code: UInt16, value: Range<Int>)] = []
        var cursor = range.lowerBound

        // options are optional, and some writers omit opt_endofopt
        while cursor + 4 <= range.upperBound {
            let code = u16(at: cursor)
            let length = Int(u16(at: cursor + 2))

            if code == OptionCode.endOfOptions {
                break
            }

            let valueStart = cursor + 4
            guard valueStart + length <= range.upperBound else {
                throw PCAPNGError.malformedBlock(offset: droppedBytes + blockOffset, type: u32(at: blockOffset))
            }

            result.append((code, valueStart..<(valueStart + length)))
            cursor = valueStart + padded(length)
        }

        return result
    }

    private static func ticksPerSecond(resolution: UInt8) -> UInt64 {
        // high bit set: negative power of 2, otherwise negative power of 10
        let exponent = UInt64(resolution & 0x7F)
        if resolution & 0x80 != 0 {
            return exponent < 64 ? 1 << exponent : 1
        }
        var ticks: UInt64 = 1
        for _ in 0..<min(exponent, 19) {
            ticks *= 10
        }
        return ticks
    }

    // MARK: bytes

    private func padded(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private func littleEndian32(at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    private func u32(at offset: Int) -> UInt32 {
        let value = littleEndian32(at: offset)
        return bigEndian ? value.byteSwapped : value
    }

    private func u16(at offset: Int) -> UInt16 {
        let value = UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
        return bigEndian ? value.byteSwapped : value
    }

    private func string(in range: Range<Int>) -> String? {
        // some writers include a trailing nul
        var slice = buffer[range]
        while slice.last == 0 {
            slice = slice.dropLast()
        }
        return String(bytes: slice, encoding: .utf8)
    }
}
