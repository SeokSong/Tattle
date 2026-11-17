import Foundation

// builds little-endian pcapng blocks by hand so tests don't depend on capture files
public enum PCAPNGBuilder {
    public static func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    public static func le16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    public static func pad(_ bytes: [UInt8]) -> [UInt8] {
        bytes + Array(repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    public static func option(_ code: UInt16, _ value: [UInt8]) -> [UInt8] {
        le16(code) + le16(UInt16(value.count)) + pad(value)
    }

    public static let endOfOptions: [UInt8] = [0, 0, 0, 0]

    public static func block(_ type: UInt32, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(12 + body.count)
        return le32(type) + le32(length) + body + le32(length)
    }

    public static func sectionHeader() -> [UInt8] {
        block(0x0A0D_0D0A, le32(0x1A2B_3C4D) + le16(1) + le16(0) + Array(repeating: 0xFF, count: 8))
    }

    public static func interface(_ name: String, linkType: UInt16 = 1) -> [UInt8] {
        block(1, le16(linkType) + le16(0) + le32(0x80000) + option(2, Array(name.utf8)) + endOfOptions)
    }

    public static func process(pid: UInt32, name: String) -> [UInt8] {
        block(0x8000_0001, le32(pid) + option(2, Array(name.utf8)) + endOfOptions)
    }

    public static func packet(
        interface: UInt32,
        microseconds: UInt64,
        process: UInt32?,
        effective: UInt32? = nil,
        flags: UInt32? = nil,
        payload: [UInt8] = [1, 2, 3, 4, 5]
    ) -> [UInt8] {
        var options: [UInt8] = []
        if let flags { options += option(0x0002, le32(flags)) }
        if let process { options += option(0x8001, le32(process)) }
        if let effective { options += option(0x8003, le32(effective)) }
        options += option(0x8002, le32(0))
        return block(6,
            le32(interface)
            + le32(UInt32(microseconds >> 32))
            + le32(UInt32(microseconds & 0xFFFF_FFFF))
            + le32(UInt32(payload.count))
            + le32(UInt32(payload.count))
            + pad(payload)
            + options
            + endOfOptions
        )
    }

    // the classic pcap file header tcpdump appends
    public static let pcapTrailer: [UInt8] =
        [0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00]
        + Array(repeating: 0, count: 8)
        + [0x00, 0x00, 0x08, 0x00, 0x95, 0x00, 0x00, 0x00]

    public static func sampleCapture() -> [UInt8] {
        sectionHeader()
            + interface("en0")
            + packet(interface: 0, microseconds: 1_763_000_000_000_000, process: nil)
            + interface("en2")
            + process(pid: 212, name: "mDNSResponder")
            + process(pid: 19_475, name: "TikTok")
            + packet(interface: 1, microseconds: 1_763_000_000_500_000, process: 0)
            + interface("utun4", linkType: 0)
            + packet(interface: 2, microseconds: 1_763_000_001_000_000, process: 0, effective: 1)
    }
}
