import Foundation
import PCAPNG
import PacketDecoder

// a second generated capture for the name hints and quic flows that began before the capture (5.4).
// one app (TikTok, process 0), one interface (en2). names are fictional, addresses are 192.0.2.0/24.
// all flows are app traffic to port 443, so the hostname denominator is the sum of all flow bytes.
//
// byte formulas as in SyntheticCorpus: udp packet = 28 + payload, tcp packet = 40 + payload,
// tcp client hello record with an n-byte name = 102 + n, quic initial = 1200 bytes
public enum HintCorpus {
    public struct Expected: Sendable {
        /// flow label -> source ("sni", "dns", "sameAddress") or unnamed reason
        public var outcome: [String: String]
        /// flow label -> remote address (last octet) and ip bytes
        public var bytes: [String: Int]
        public var denominator: Int
        public var sniBytes: Int
        public var sameAddressBytes: Int
        public var unnamedBytes: [String: Int]
        public var midstreamBytes: Int
        public var sameAddressPrecisionAgreeBytes: Int
        public var sameAddressPrecisionBytes: Int
        /// quic flows that began with a short header: the buffer's `shortHeaderFirst` count
        public var shortHeaderFirst: Int
    }

    public static func remote(_ label: String) -> UInt32 {
        switch label {
        case "H1", "H2", "H5": return 0xC000_026E  // 192.0.2.110
        case "H3": return 0xC000_0278  // 192.0.2.120
        case "H4": return 0xC000_0282  // 192.0.2.130
        default: return 0xC000_028C  // 192.0.2.140: H6a, H6b
        }
    }

    public static func build() -> (bytes: [UInt8], expected: Expected) {
        let phone = PacketBuilder.v4(10, 0, 0, 2)
        func ip(_ label: String) -> [UInt8] { let a = remote(label); return [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)] }
        var frames: [(at: Double, dir: UInt32, bytes: [UInt8])] = []
        func udp(_ at: Double, _ label: String, port: Int, out: Bool, _ payload: [UInt8]) {
            let bytes = out
                ? PacketBuilder.ethernetIPv4UDP(src: phone, dst: ip(label), srcPort: port, dstPort: 443, payload: payload)
                : PacketBuilder.ethernetIPv4UDP(src: ip(label), dst: phone, srcPort: 443, dstPort: port, payload: payload)
            frames.append((at, out ? 2 : 1, bytes))
        }
        func tcp(_ at: Double, _ label: String, port: Int, flags: UInt8, _ payload: [UInt8] = []) {
            frames.append((at, 2, PacketBuilder.ethernetIPv4TCP(
                src: phone, dst: ip(label), srcPort: port, dstPort: 443, flags: flags, payload: payload)))
        }
        let filler = [UInt8](repeating: 0x07, count: 100)

        // H1: udp 192.0.2.110, quic Initial with SNI named.tiktok.test (17 bytes), then 300 bytes out
        // 28 + 1200 = 1228, 28 + 300 = 328 -> 1556 bytes, 2 packets. sni
        udp(1.0, "H1", port: 50011, out: true, quicInitial(
            dcid: [1, 2, 3, 4, 5, 6, 7, 8], frames: cryptoFrame(offset: 0, clientHello(sni: "named.tiktok.test"))))
        udp(1.1, "H1", port: 50011, out: true, [UInt8](repeating: 0x07, count: 300))

        // H2: udp 192.0.2.110 (the same address as H1), first payload a short header (0x41...), 100 out, 200 in
        // 128 + 228 = 356 bytes, 2 packets. no name of its own: it began before the capture, and H1 and H5 share
        // its address and app. H1 (1.0) and H5 (3.5) are 1.0 s and 1.5 s away, so H1's name is the hint
        udp(2.0, "H2", port: 50012, out: true, [0x41] + filler.dropFirst())
        udp(2.1, "H2", port: 50012, out: false, [UInt8](repeating: 0x07, count: 200))

        // H3: udp 192.0.2.120, one short-header payload of 100 bytes: 128 bytes. nothing else at this address
        udp(2.5, "H3", port: 50013, out: true, [0x41] + filler.dropFirst())

        // H4: udp 192.0.2.130, one payload of 100 bytes starting 0x80 (long bit set, not an Initial): 128 bytes.
        // no sign that it began before the capture
        udp(2.6, "H4", port: 50014, out: true, [0x80] + filler.dropFirst())

        // H5: tcp 192.0.2.110, SYN 40, hello with SNI other.tiktok.test (17 bytes): 20 + 20 + 119 = 159. 199 bytes
        tcp(3.5, "H5", port: 50015, flags: SyntheticCorpus.syn)
        tcp(3.6, "H5", port: 50015, flags: SyntheticCorpus.pshAck, tlsRecord(clientHello(sni: "other.tiktok.test")))

        // H6a and H6b: tcp 192.0.2.140, SYN 40, hello with SNI same.tiktok.test (16 bytes): 20 + 20 + 118 = 158
        // 198 bytes each. the two flows name each other correctly
        for (i, label) in ["H6a", "H6b"].enumerated() {
            let port = 50016 + i
            tcp(4.0 + Double(i), label, port: port, flags: SyntheticCorpus.syn)
            tcp(4.1 + Double(i), label, port: port, flags: SyntheticCorpus.pshAck, tlsRecord(clientHello(sni: "same.tiktok.test")))
        }

        var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("en2")
        bytes += PCAPNGBuilder.process(pid: 19_475, name: "TikTok")
        for f in frames.sorted(by: { $0.at < $1.at }) {
            bytes += PCAPNGBuilder.packet(
                interface: 0, microseconds: UInt64((Double(SyntheticCorpus.start) + f.at) * 1_000_000),
                process: 0, flags: f.dir, payload: f.bytes)
        }

        let expected = Expected(
            outcome: [
                "H1": "sni", "H2": "sameAddress", "H3": "startedBeforeCapture", "H4": "noHandshakeUDP",
                "H5": "sni", "H6a": "sni", "H6b": "sni",
            ],
            bytes: ["H1": 1556, "H2": 356, "H3": 128, "H4": 128, "H5": 199, "H6a": 198, "H6b": 198],
            // 1556 + 356 + 128 + 128 + 199 + 198 + 198 = 2763
            denominator: 2763,
            // sni: H1 1556 + H5 199 + H6a 198 + H6b 198 = 2151
            sniBytes: 2151,
            // sameAddress: H2 356
            sameAddressBytes: 356,
            // startedBeforeCapture H3 128, noHandshakeUDP H4 128. 2151 + 356 + 128 + 128 = 2763
            unnamedBytes: ["echHidden": 0, "startedBeforeCapture": 128, "noHandshakeUDP": 128, "noDNSMatch": 0],
            // the short-header flows: H2 356 + H3 128 = 484
            midstreamBytes: 484,
            // flows with an sni name and another flow of the same address and app to name them:
            // H1 (H5 says other.tiktok.test: no), H5 (H1 says named.tiktok.test: no), H6a and H6b (yes)
            // 1556 + 199 + 198 + 198 = 2151; agree 198 + 198 = 396
            sameAddressPrecisionAgreeBytes: 396,
            sameAddressPrecisionBytes: 2151,
            // H2 and H3
            shortHeaderFirst: 2)
        return (bytes, expected)
    }
}
