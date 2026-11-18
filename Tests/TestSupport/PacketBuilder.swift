import Foundation
import PCAPNG

// builds whole link-layer frames by hand: the byte-level truth behind the synthetic corpus.
// addresses are raw bytes (4 for IPv4, 16 for IPv6). checksums are left zero: the decoder never reads them.
public enum PacketBuilder {
    public static let mac: [UInt8] = Array(repeating: 0xAA, count: 6) + Array(repeating: 0xBB, count: 6)

    public static func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [a, b, c, d] }

    /// eight 16-bit groups, so 2001:db8::5 is v6(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 5)
    public static func v6(_ groups: UInt16...) -> [UInt8] {
        precondition(groups.count == 8, "an IPv6 address has eight groups")
        return groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    // MARK: transport headers

    /// 20-byte TCP header (data offset 5) then the payload
    public static func tcp(srcPort: Int, dstPort: Int, flags: UInt8, payload: [UInt8] = []) -> [UInt8] {
        be16(srcPort) + be16(dstPort) + [0, 0, 0, 1, 0, 0, 0, 0, 0x50, flags] + be16(65535) + [0, 0, 0, 0] + payload
    }

    /// 8-byte UDP header then the payload. lengthOverride is for fragments, where the header names the whole datagram
    public static func udp(srcPort: Int, dstPort: Int, payload: [UInt8], lengthOverride: Int? = nil) -> [UInt8] {
        be16(srcPort) + be16(dstPort) + be16(lengthOverride ?? 8 + payload.count) + [0, 0] + payload
    }

    // MARK: ip

    /// 20-byte IPv4 header (no options) then the body. fragField holds the flags and the offset in 8-byte units
    public static func ipv4(
        proto: UInt8, src: [UInt8], dst: [UInt8], body: [UInt8], fragField: Int = 0
    ) -> [UInt8] {
        [0x45, 0] + be16(20 + body.count) + [0, 1] + be16(fragField) + [64, proto, 0, 0] + src + dst + body
    }

    /// 40-byte IPv6 header then the body
    public static func ipv6(next: UInt8, src: [UInt8], dst: [UInt8], body: [UInt8]) -> [UInt8] {
        [0x60, 0, 0, 0] + be16(body.count) + [next, 64] + src + dst + body
    }

    // MARK: ethernet (link type 1)

    public static func ethernet(type: Int, _ body: [UInt8]) -> [UInt8] { mac + be16(type) + body }

    public static func ethernetIPv4TCP(
        src: [UInt8], dst: [UInt8], srcPort: Int, dstPort: Int, flags: UInt8, payload: [UInt8] = []
    ) -> [UInt8] {
        ethernet(type: 0x0800, ipv4(
            proto: 6, src: src, dst: dst,
            body: tcp(srcPort: srcPort, dstPort: dstPort, flags: flags, payload: payload)))
    }

    public static func ethernetIPv4UDP(
        src: [UInt8], dst: [UInt8], srcPort: Int, dstPort: Int, payload: [UInt8] = []
    ) -> [UInt8] {
        ethernet(type: 0x0800, ipv4(
            proto: 17, src: src, dst: dst, body: udp(srcPort: srcPort, dstPort: dstPort, payload: payload)))
    }

    public static func ethernetIPv6TCP(
        src: [UInt8], dst: [UInt8], srcPort: Int, dstPort: Int, flags: UInt8, payload: [UInt8] = []
    ) -> [UInt8] {
        ethernet(type: 0x86DD, ipv6(
            next: 6, src: src, dst: dst,
            body: tcp(srcPort: srcPort, dstPort: dstPort, flags: flags, payload: payload)))
    }

    public static func ethernetIPv6UDP(
        src: [UInt8], dst: [UInt8], srcPort: Int, dstPort: Int, payload: [UInt8] = []
    ) -> [UInt8] {
        ethernet(type: 0x86DD, ipv6(
            next: 17, src: src, dst: dst, body: udp(srcPort: srcPort, dstPort: dstPort, payload: payload)))
    }

    /// one IPv4 fragment. offsetUnits is the fragment offset in 8-byte units; moreFragments sets the MF bit.
    /// the first fragment (offset 0) carries the transport header in body; later ones carry raw bytes
    public static func ethernetIPv4Fragment(
        src: [UInt8], dst: [UInt8], proto: UInt8, offsetUnits: Int, moreFragments: Bool, body: [UInt8]
    ) -> [UInt8] {
        ethernet(type: 0x0800, ipv4(
            proto: proto, src: src, dst: dst, body: body,
            fragField: (moreFragments ? 0x2000 : 0) | offsetUnits))
    }

    /// a 28-byte ARP body: the decoder skips it
    public static func ethernetARP() -> [UInt8] { ethernet(type: 0x0806, [UInt8](repeating: 1, count: 28)) }

    // MARK: utun (link type 0)

    /// 4-byte address family (little endian, as the decoder reads it: 2 is IPv4, 30 is IPv6) then the IP packet
    public static func utunFrame(family: UInt32, ip: [UInt8]) -> [UInt8] { PCAPNGBuilder.le32(family) + ip }

    public static func utunIPv4UDP(
        src: [UInt8], dst: [UInt8], srcPort: Int, dstPort: Int, payload: [UInt8] = []
    ) -> [UInt8] {
        utunFrame(family: 2, ip: ipv4(
            proto: 17, src: src, dst: dst, body: udp(srcPort: srcPort, dstPort: dstPort, payload: payload)))
    }
}
