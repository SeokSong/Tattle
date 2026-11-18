import PacketDecoder

extension IPAddress {
    /// IPv4 169.254.0.0/16 or IPv6 fe80::/10
    public var isLinkLocal: Bool {
        switch self {
        case .v4(let v): return v >> 16 == 0xA9FE
        case .v6(let hi, _): return hi >> 54 == 0x3FA
        }
    }

    /// the address never leaves the LAN: multicast, broadcast, loopback, link-local, private ranges.
    /// 100.64.0.0/10 (carrier NAT) is not included: real servers can sit there
    public var isLocalOnly: Bool {
        if isLinkLocal { return true }
        switch self {
        case .v4(let v):
            return v >> 28 == 0xE  // 224.0.0.0/4 multicast
                || v == 0xFFFF_FFFF  // broadcast
                || v >> 24 == 127  // loopback
                || v >> 24 == 10  // 10.0.0.0/8
                || v >> 20 == 0xAC1  // 172.16.0.0/12
                || v >> 16 == 0xC0A8  // 192.168.0.0/16
        case .v6(let hi, let lo):
            return hi >> 56 == 0xFF  // ff00::/8 multicast
                || (hi == 0 && lo == 1)  // ::1
                || hi >> 57 == 0x7E  // fc00::/7 unique-local
        }
    }
}
