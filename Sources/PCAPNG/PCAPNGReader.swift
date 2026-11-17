import Foundation

// minimal pcapng reader for tcpdump captures taken on the rvi interface.
// it walks blocks and extracts metadata only: no flow logic, no payload parsing.

// MARK: - Models

public struct PCAPNGInterface: Sendable, Equatable {
    /// index within its section (packets refer to this)
    public let id: Int
    public let name: String?
    public let linkType: UInt16
    public let snapLength: UInt32
    /// timestamp ticks per second, from if_tsresol (default: microseconds)
    public let ticksPerSecond: UInt64
}

public struct PCAPNGProcess: Sendable, Hashable {
    public let pid: UInt32
    public let name: String?

    public init(pid: UInt32, name: String?) {
        self.pid = pid
        self.name = name
    }
}

public struct PCAPNGPacket: Sendable {
    public let interface: PCAPNGInterface
    /// raw timestamp in the interface's ticks
    public let rawTimestamp: UInt64
    public let capturedLength: Int
    public let originalLength: Int
    /// the captured bytes (capturedLength of them)
    public let data: [UInt8]
    /// epb_flags option, in the section's byte order
    public let flags: UInt32?
    /// the process that owns the socket
    public let process: PCAPNGProcess?
    /// the process the traffic was done on behalf of (e.g. an app behind nsurlsessiond)
    public let effectiveProcess: PCAPNGProcess?

    public enum Direction: Sendable, Equatable {
        case inbound
        case outbound
        case unknown
    }

    /// from the low two bits of flags: 1 inbound, 2 outbound, anything else unknown
    public var direction: Direction {
        switch flags.map({ $0 & 0b11 }) {
        case 1: return .inbound
        case 2: return .outbound
        default: return .unknown
        }
    }

    public var timestamp: Date {
        let ticks = interface.ticksPerSecond
        let seconds = Double(rawTimestamp / ticks)
        let fraction = Double(rawTimestamp % ticks) / Double(ticks)
        return Date(timeIntervalSince1970: seconds + fraction)
    }
}

public struct PCAPNGCapture: Sendable {
    public internal(set) var sectionCount = 0
    public internal(set) var interfaces: [PCAPNGInterface] = []
    public internal(set) var processes: [PCAPNGProcess] = []
    public internal(set) var packets: [PCAPNGPacket] = []
    /// block types this reader skips, with how often they appeared
    public internal(set) var skippedBlocks: [UInt32: Int] = [:]
    /// packets whose process index pointed at a process block not seen yet
    public internal(set) var unresolvedProcessReferences = 0
    /// true when the file ended with the 24-byte classic pcap header tcpdump appends
    public internal(set) var endedWithPcapTrailer = false
}

public enum PCAPNGError: Error, Equatable, CustomStringConvertible {
    case notPCAPNG
    case badByteOrderMagic(offset: Int)
    case truncatedBlock(offset: Int)
    case badBlockLength(offset: Int, length: UInt32)
    case trailingLengthMismatch(offset: Int)
    case malformedBlock(offset: Int, type: UInt32)
    case unknownInterface(offset: Int, id: UInt32)

    public var description: String {
        switch self {
        case .notPCAPNG:
            return "not a pcapng file (no section header at offset 0)"
        case .badByteOrderMagic(let offset):
            return "bad byte-order magic in section header at offset \(offset)"
        case .truncatedBlock(let offset):
            return "truncated block at offset \(offset)"
        case .badBlockLength(let offset, let length):
            return "invalid block length \(length) at offset \(offset)"
        case .trailingLengthMismatch(let offset):
            return "leading and trailing block lengths differ at offset \(offset)"
        case .malformedBlock(let offset, let type):
            return "malformed block of type 0x\(String(type, radix: 16)) at offset \(offset)"
        case .unknownInterface(let offset, let id):
            return "packet at offset \(offset) refers to unknown interface \(id)"
        }
    }
}

// MARK: - Reader

public enum PCAPNGReader {
    public static func read(contentsOf url: URL) throws -> PCAPNGCapture {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> PCAPNGCapture {
        var parser = PCAPNGStreamParser()
        var capture = PCAPNGCapture()

        for event in try parser.append(data) {
            switch event {
            case .sectionStarted:
                capture.sectionCount += 1
            case .interface(let interface):
                capture.interfaces.append(interface)
            case .process(let process):
                capture.processes.append(process)
            case .packet(let packet):
                capture.packets.append(packet)
            case .end:
                break
            }
        }

        capture.endedWithPcapTrailer = try parser.finish() == .pcapTrailer
        capture.skippedBlocks = parser.skippedBlocks
        capture.unresolvedProcessReferences = parser.unresolvedProcessReferences
        return capture
    }
}
