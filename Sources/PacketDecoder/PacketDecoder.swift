import Foundation
import PCAPNG

// the decoder has no logging; addresses must never reach a log

public enum IPAddress: Hashable, Sendable {
    /// network byte order packed big-endian into the UInt32
    case v4(UInt32)
    case v6(hi: UInt64, lo: UInt64)

    public var description: String {
        switch self {
        case .v4(let value):
            return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
        case .v6(let hi, let lo):
            var groups = [UInt16](repeating: 0, count: 8)
            for i in 0..<4 {
                groups[i] = UInt16(truncatingIfNeeded: hi >> UInt64(48 - 16 * i))
                groups[4 + i] = UInt16(truncatingIfNeeded: lo >> UInt64(48 - 16 * i))
            }
            // longest run of zero groups (length >= 2) is compressed, first one wins ties
            var bestStart = -1, bestLength = 0, i = 0
            while i < 8 {
                if groups[i] == 0 {
                    var j = i
                    while j < 8, groups[j] == 0 { j += 1 }
                    if j - i > bestLength { bestStart = i; bestLength = j - i }
                    i = j
                } else {
                    i += 1
                }
            }
            if bestLength < 2 { bestStart = -1 }
            var out = ""
            i = 0
            while i < 8 {
                if i == bestStart {
                    out += "::"
                    i += bestLength
                    continue
                }
                if !out.isEmpty, !out.hasSuffix(":") { out += ":" }
                out += String(groups[i], radix: 16)
                i += 1
            }
            return out
        }
    }
}

public enum Transport: Hashable, Sendable { case tcp, udp, other(UInt8) }

public struct TCPFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let fin = TCPFlags(rawValue: 1)
    public static let syn = TCPFlags(rawValue: 2)
    public static let rst = TCPFlags(rawValue: 4)
    public static let psh = TCPFlags(rawValue: 8)
    public static let ack = TCPFlags(rawValue: 16)
}

public struct IPHeaders: Sendable {
    public let ipVersion: UInt8
    public let source: IPAddress
    public let destination: IPAddress
    public let transport: Transport
    /// nil for .other or a non-first fragment
    public let sourcePort: UInt16?
    public let destinationPort: UInt16?
    public let tcpFlags: TCPFlags?
    /// from the length fields, link header excluded
    public let ipBytes: Int
    /// indices into the parsed slice (equal to packet.data indices); empty when there is no transport header
    public let payload: Range<Int>
    public let fragmented: Bool
}

public enum SkipReason: Hashable, Sendable {
    case arp
    case otherEtherType(UInt16)
    case nonIPFamily
    case unknownLinkType
}

public enum DecodeOutcome: Sendable {
    case decoded(IPHeaders)
    case skipped(SkipReason)
    /// short header, bad IHL, length field beyond the bytes
    case malformed(String)
}

public enum DecodeFailure: Error, Sendable {
    case skipped(SkipReason)
    case malformed(String)
}

public enum PacketDirection: Sendable {
    case inbound, outbound, inferredInbound, inferredOutbound, unknown
}

public enum HeaderParser {
    public static func parse(linkType: UInt16, bytes: ArraySlice<UInt8>) -> DecodeOutcome {
        let s = bytes.startIndex
        let end = bytes.endIndex
        switch linkType {
        case 1:
            guard end - s >= 14 else { return .malformed("short ethernet header") }
            var etherType = (UInt16(bytes[s + 12]) << 8) | UInt16(bytes[s + 13])
            var ip = s + 14
            if etherType == 0x8100 {
                guard end - s >= 18 else { return .malformed("short vlan header") }
                etherType = (UInt16(bytes[s + 16]) << 8) | UInt16(bytes[s + 17])
                ip = s + 18
            }
            switch etherType {
            case 0x0800: return parseIPv4(bytes, at: ip)
            case 0x86DD: return parseIPv6(bytes, at: ip)
            case 0x0806: return .skipped(.arp)
            default: return .skipped(.otherEtherType(etherType))
            }
        case 0:
            guard end - s >= 4 else { return .malformed("short null header") }
            let family = UInt32(bytes[s]) | UInt32(bytes[s + 1]) << 8 | UInt32(bytes[s + 2]) << 16 | UInt32(bytes[s + 3]) << 24
            switch family {
            case 2, 0x0200_0000: return parseIPv4(bytes, at: s + 4)
            case 30, 0x1E00_0000: return parseIPv6(bytes, at: s + 4)
            default: return .skipped(.nonIPFamily)
            }
        default:
            return .skipped(.unknownLinkType)
        }
    }

    // MARK: ip

    private static func parseIPv4(_ b: ArraySlice<UInt8>, at p: Int) -> DecodeOutcome {
        let end = b.endIndex
        guard end - p >= 20 else { return .malformed("short ipv4 header") }
        guard b[p] >> 4 == 4 else { return .malformed("bad ipv4 version") }
        let ihl = Int(b[p] & 0x0F) * 4
        let total = Int(b[p + 2]) << 8 | Int(b[p + 3])
        guard ihl >= 20, total >= ihl else { return .malformed("bad ipv4 header length") }
        guard total <= end - p else { return .malformed("ipv4 total length beyond bytes") }
        let fragField = Int(b[p + 6]) << 8 | Int(b[p + 7])
        let offset = fragField & 0x1FFF
        let fragmented = (fragField & 0x2000) != 0 || offset != 0
        let proto = b[p + 9]
        let src = IPAddress.v4(be32(b, p + 12))
        let dst = IPAddress.v4(be32(b, p + 16))
        // padding after the datagram is ignored
        return parseTransport(
            b, version: 4, source: src, destination: dst, proto: proto,
            at: p + ihl, limit: p + total, ipBytes: total, fragmented: fragmented, hasTransport: offset == 0)
    }

    private static func parseIPv6(_ b: ArraySlice<UInt8>, at p: Int) -> DecodeOutcome {
        let end = b.endIndex
        guard end - p >= 40 else { return .malformed("short ipv6 header") }
        guard b[p] >> 4 == 6 else { return .malformed("bad ipv6 version") }
        let plen = Int(b[p + 4]) << 8 | Int(b[p + 5])
        guard 40 + plen <= end - p else { return .malformed("ipv6 payload length beyond bytes") }
        let limit = p + 40 + plen
        let src = IPAddress.v6(hi: be64(b, p + 8), lo: be64(b, p + 16))
        let dst = IPAddress.v6(hi: be64(b, p + 24), lo: be64(b, p + 32))
        var next = b[p + 6]
        var q = p + 40
        var fragmented = false
        var hasTransport = true
        var walked = 0
        while true {
            switch next {
            case 0, 43, 60, 51, 44:
                guard walked < 8 else { return .malformed("too many ipv6 extension headers") }
                walked += 1
                guard limit - q >= 8 else { return .malformed("short ipv6 extension header") }
                let length: Int
                switch next {
                case 51: length = (Int(b[q + 1]) + 2) * 4
                case 44:
                    length = 8
                    fragmented = true
                    if (Int(b[q + 2]) << 8 | Int(b[q + 3])) & 0xFFF8 != 0 { hasTransport = false }
                default: length = (Int(b[q + 1]) + 1) * 8
                }
                guard length <= limit - q else { return .malformed("ipv6 extension header beyond bytes") }
                next = b[q]
                q += length
            default:
                return parseTransport(
                    b, version: 6, source: src, destination: dst, proto: next,
                    at: q, limit: limit, ipBytes: 40 + plen, fragmented: fragmented, hasTransport: hasTransport)
            }
        }
    }

    // MARK: transport

    private static func parseTransport(
        _ b: ArraySlice<UInt8>, version: UInt8, source: IPAddress, destination: IPAddress, proto: UInt8,
        at q: Int, limit: Int, ipBytes: Int, fragmented: Bool, hasTransport: Bool
    ) -> DecodeOutcome {
        func headers(
            _ t: Transport, _ sp: UInt16?, _ dp: UInt16?, _ flags: TCPFlags?, _ payload: Range<Int>
        ) -> DecodeOutcome {
            .decoded(IPHeaders(
                ipVersion: version, source: source, destination: destination, transport: t,
                sourcePort: sp, destinationPort: dp, tcpFlags: flags, ipBytes: ipBytes,
                payload: payload, fragmented: fragmented))
        }
        let t: Transport = proto == 6 ? .tcp : proto == 17 ? .udp : .other(proto)
        guard hasTransport, proto == 6 || proto == 17 else { return headers(t, nil, nil, nil, q..<q) }
        if proto == 6 {
            guard limit - q >= 20 else { return .malformed("short tcp header") }
            let offset = Int(b[q + 12] >> 4) * 4
            guard offset >= 20, offset <= limit - q else { return .malformed("bad tcp data offset") }
            return headers(.tcp, be16(b, q), be16(b, q + 2), TCPFlags(rawValue: b[q + 13] & 0x1F), (q + offset)..<limit)
        }
        guard limit - q >= 8 else { return .malformed("short udp header") }
        let udpLength = Int(be16(b, q + 4))
        let covered = min(udpLength, limit - q)
        return headers(.udp, be16(b, q), be16(b, q + 2), nil, (q + 8)..<(q + max(covered, 8)))
    }

    @inline(__always) private static func be16(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    @inline(__always) private static func be32(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    @inline(__always) private static func be64(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt64 {
        UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
    }
}

public struct DecodedPacket: Sendable {
    public let timestamp: Date
    public let interface: String
    public let direction: PacketDirection
    public let headers: IPHeaders
    public let localAddress: IPAddress
    public let localPort: UInt16?
    public let remoteAddress: IPAddress
    public let remotePort: UInt16?
    public let process: PCAPNGProcess?
    public let effectiveProcess: PCAPNGProcess?
    /// the raw packet, dropped once flows and domains have seen it
    public let bytes: [UInt8]
}

public struct PacketDecoder: Sendable {
    public static let maxLocalAddresses = 64

    private var localAddresses = Set<IPAddress>()

    public init() {}

    /// decodes and orients. keeps a set of addresses seen as "local" to infer direction when flags are missing
    public mutating func decode(_ packet: PCAPNGPacket) -> Result<DecodedPacket, DecodeFailure> {
        let h: IPHeaders
        switch HeaderParser.parse(linkType: packet.interface.linkType, bytes: packet.data[...]) {
        case .decoded(let headers): h = headers
        case .skipped(let reason): return .failure(.skipped(reason))
        case .malformed(let message): return .failure(.malformed(message))
        }

        var direction: PacketDirection
        switch packet.direction {
        case .inbound:
            direction = .inbound
            learn(h.destination)
        case .outbound:
            direction = .outbound
            learn(h.source)
        case .unknown:
            if localAddresses.contains(h.source) {
                direction = .inferredOutbound
            } else if localAddresses.contains(h.destination) {
                direction = .inferredInbound
            } else {
                direction = .unknown
            }
        }

        let localIsSource: Bool
        switch direction {
        case .inbound, .inferredInbound: localIsSource = false
        default: localIsSource = true
        }
        return .success(DecodedPacket(
            timestamp: packet.timestamp,
            interface: packet.interface.name ?? "",
            direction: direction,
            headers: h,
            localAddress: localIsSource ? h.source : h.destination,
            localPort: localIsSource ? h.sourcePort : h.destinationPort,
            remoteAddress: localIsSource ? h.destination : h.source,
            remotePort: localIsSource ? h.destinationPort : h.sourcePort,
            process: packet.process,
            effectiveProcess: packet.effectiveProcess,
            bytes: packet.data))
    }

    private mutating func learn(_ address: IPAddress) {
        if localAddresses.count < Self.maxLocalAddresses {
            localAddresses.insert(address)
        }
    }
}
