import Foundation
import PCAPNG
import PacketDecoder

// parses one dns response message. hostnames and addresses only; nothing else leaves this file.

public enum DNSParser {
    static let maxPointerJumps = 128
    static let maxNameLength = 253

    /// nil for queries, non-zero rcodes, truncated or malformed messages, and responses with no A/AAAA answer
    public static func parse(
        _ payload: ArraySlice<UInt8>, time: Date,
        process: PCAPNGProcess? = nil, effectiveProcess: PCAPNGProcess? = nil
    ) -> DomainObservation? {
        let m = Array(payload)
        guard m.count >= 12 else { return nil }
        let flags = u16(m, 2)
        guard flags & 0x8000 != 0, flags & 0x000F == 0 else { return nil }
        let qd = Int(u16(m, 4)), an = Int(u16(m, 6))
        guard qd >= 1 else { return nil }

        var pos = 12
        var hostname: String?
        for i in 0..<qd {
            guard let (name, next) = readName(m, at: pos), next + 4 <= m.count else { return nil }
            if i == 0 { hostname = name }
            pos = next + 4
        }
        guard let host = hostname, !host.isEmpty else { return nil }

        var chain: [String] = []
        var addresses: [IPAddress] = []
        var ttl: UInt32?
        for _ in 0..<an {
            guard let (_, next) = readName(m, at: pos), next + 10 <= m.count else { return nil }
            let type = u16(m, next)
            let recordTTL = u32(m, next + 4)
            let rdLength = Int(u16(m, next + 8))
            let rdata = next + 10
            guard rdata + rdLength <= m.count else { return nil }
            switch type {
            case 1 where rdLength == 4:
                addresses.append(.v4(u32(m, rdata)))
                ttl = min(ttl ?? recordTTL, recordTTL)
            case 28 where rdLength == 16:
                addresses.append(.v6(hi: u64(m, rdata), lo: u64(m, rdata + 8)))
                ttl = min(ttl ?? recordTTL, recordTTL)
            case 5:
                guard let (target, _) = readName(m, at: rdata) else { return nil }
                chain.append(target)
                ttl = min(ttl ?? recordTTL, recordTTL)
            default:
                break
            }
            pos = rdata + rdLength
        }
        guard !addresses.isEmpty else { return nil }
        return DomainObservation(
            time: time, source: .dns, hostname: host, cnameChain: chain, addresses: addresses,
            ttl: ttl, process: process, effectiveProcess: effectiveProcess)
    }

    /// decodes a possibly compressed name. returns the lowercased name (no trailing dot) and the offset after it
    /// in the original position (after the first pointer, if any). nil on loops, overruns, or names over 253 chars
    static func readName(_ m: [UInt8], at start: Int) -> (String, Int)? {
        var pos = start
        var end: Int?
        var jumps = 0
        var name: [UInt8] = []
        while true {
            guard pos < m.count else { return nil }
            let len = Int(m[pos])
            if len == 0 {
                pos += 1
                break
            }
            switch len & 0xC0 {
            case 0xC0:
                guard pos + 1 < m.count else { return nil }
                jumps += 1
                guard jumps <= maxPointerJumps else { return nil }
                if end == nil { end = pos + 2 }
                pos = (len & 0x3F) << 8 | Int(m[pos + 1])
            case 0:
                guard pos + 1 + len <= m.count else { return nil }
                if !name.isEmpty { name.append(0x2E) }
                name.append(contentsOf: m[(pos + 1)..<(pos + 1 + len)])
                guard name.count <= maxNameLength else { return nil }
                pos += 1 + len
            default:
                return nil
            }
        }
        let text = String(decoding: name, as: UTF8.self).lowercased()
        return (text, end ?? pos)
    }

    private static func u16(_ m: [UInt8], _ i: Int) -> UInt16 { UInt16(m[i]) << 8 | UInt16(m[i + 1]) }
    private static func u32(_ m: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(m, i)) << 16 | UInt32(u16(m, i + 2)) }
    private static func u64(_ m: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(m, i)) << 32 | UInt64(u32(m, i + 4)) }
}
