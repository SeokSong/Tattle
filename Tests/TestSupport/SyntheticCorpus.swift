import Foundation
import PCAPNG
import PacketDecoder

// a generated capture with hand-computed answers: the CI truth set (real captures never leave the Mac).
// all names are fictional (.example, .test) and all addresses come from documentation ranges, except the
// phone's private address, the mDNS group and the private fd5d:: address the heartbeat flow uses.
//
// byte formulas used below (IP bytes = the IP total length field, link header not counted):
//   tcp packet      = 20 (ip) + 20 (tcp) + payload
//   udp packet      = 20 (ip) + 8 (udp) + payload
//   ipv6 tcp        = 40 + 20 + payload      ipv6 udp = 40 + 8 + payload
//   client hello record with an n-byte name = 102 + n:
//     body 2 + 32 + (1 + 32) + (2 + 4) + 2 + 2 = 77, extensions (9 + n) + 7 = 16 + n, handshake header 4, record header 5
//     77 + 16 + n + 4 + 5 = 102 + n. with an encrypted_client_hello extension (2 + 2 + 3 = 7 more bytes): 109 + n
//   quic initial = 1200 bytes (padded)
//   dns answer = 12 (header) + question name + 4 + one record (2 + 2 + 2 + 4 + 2 + rdata); worked out at each answer
public enum SyntheticCorpus {
    public struct ExpectedFlow: Sendable {
        public var label: String
        public var remote: IPAddress
        public var remotePort: UInt16
        public var interface: String
        public var packets: Int
        public var ipBytes: Int
        public var serverName: String?
        public var startedMidstream: Bool
        public var echSeen: Bool
    }

    public struct Expected: Sendable {
        public var flows: [ExpectedFlow]
        public var flowCount: Int
        /// packets that ended in a flow
        public var flowPackets: Int
        public var ipBytes: Int
        public var byInterface: [String: Int]
        // pipeline counters
        public var packetsRead: Int
        public var decoded: Int
        public var skipped: Int
        public var malformed: Int
        public var droppedNoPort: Int
        // metrics, as numerator over denominator
        public var noProcessBytes: Int
        public var attributedBytes: Int
        public var port443Bytes: Int
        public var sniNamedBytes: Int
        public var mixedBytes: Int
        // categories, keyed by TrafficCategory raw value (TestSupport does not import Attribution)
        public var categoryBytes: [String: Int]
        public var categoryFlows: [String: Int]
        public var categoryPackets: [String: Int]
        public var ruleBytes: [String: Int]
        public var movedOutOfAppBytes: [String: Int]
        public var phoneTrafficBytes: Int
        // hostnames (5.1): appTraffic flows with remote port 443
        /// flow label -> "sni", "dns" or the unnamed reason
        public var hostnameOutcome: [String: String]
        public var hostnameDenominatorBytes: Int
        public var sniBytes: Int
        public var dnsBytes: Int
        /// bytes per unnamed reason; all four keys present
        public var unnamedBytes: [String: Int]
        public var midstreamBytes: Int
        public var echBytes: Int
        public var dnsPrecisionAgreeBytes: Int
        public var dnsPrecisionBytes: Int

        public func flow(_ label: String) -> ExpectedFlow {
            flows.first { $0.label == label }!
        }
    }

    // MARK: layout

    /// seconds since the epoch of the first packet
    public static let start: UInt64 = 1_763_000_000

    static let phone = PacketBuilder.v4(10, 0, 0, 2)
    static let phone6 = PacketBuilder.v6(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2)
    static let dns4 = PacketBuilder.v4(192, 0, 2, 53)
    static let dns6 = PacketBuilder.v6(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x53)

    // interface indexes, in block order
    static let en2: UInt32 = 0, en0: UInt32 = 1, pdp: UInt32 = 2
    // process indexes, in block order
    static let mdns: UInt32 = 0, tiktok: UInt32 = 1, instagram: UInt32 = 2
    static let heartbeat: UInt32 = 3, safari: UInt32 = 4, appstore: UInt32 = 5
    static let inbound: UInt32 = 1, outbound: UInt32 = 2

    static let syn: UInt8 = 0x02, synAck: UInt8 = 0x12, ack: UInt8 = 0x10, pshAck: UInt8 = 0x18

    private struct Frame {
        var at: Double
        var interface: UInt32
        var process: UInt32?
        var effective: UInt32?
        var direction: UInt32
        var bytes: [UInt8]
    }

    private static func filler(_ n: Int) -> [UInt8] { [UInt8](repeating: 0x07, count: n) }

    // MARK: corpus

    public static func mixed() -> (bytes: [UInt8], expected: Expected) {
        var frames: [Frame] = []
        func add(_ at: Double, _ iface: UInt32, _ process: UInt32?, _ effective: UInt32? = nil, _ dir: UInt32, _ bytes: [UInt8]) {
            frames.append(Frame(at: at, interface: iface, process: process, effective: effective, direction: dir, bytes: bytes))
        }

        // D1: DNS answer video.tiktok.test -> 192.0.2.10 for F1, by mDNSResponder working for TikTok
        // question name "video.tiktok.test" = 3 length bytes + 15 letters + 1 terminator = 19
        // dns = 12 + 19 + 4 + (2 + 2 + 2 + 4 + 2 + 4) = 51; udp 8 + 51 = 59; ip 20 + 59 = 79
        add(0, en2, mdns, tiktok, inbound, PacketBuilder.ethernetIPv4UDP(
            src: dns4, dst: phone, srcPort: 53, dstPort: 53001,
            payload: dnsResponse(
                question: "video.tiktok.test",
                records: [DNSRecord(type: 1, ttl: 300, rdata: [192, 0, 2, 10])])))

        // F1: TikTok, en2, 192.0.2.10:443. SYN, hello with SNI video.tiktok.test (17 bytes), 4 data packets
        // syn 20 + 20 = 40; hello record 102 + 17 = 119, ip 20 + 20 + 119 = 159
        // data payloads 1000 in, 300 out, 1400 in, 500 in -> ip 1040 + 340 + 1440 + 540 = 3360
        // total 40 + 159 + 3360 = 3559 bytes, 6 packets
        let f1 = PacketBuilder.v4(192, 0, 2, 10)
        func f1Packet(_ out: Bool, flags: UInt8, _ payload: [UInt8]) -> [UInt8] {
            out
                ? PacketBuilder.ethernetIPv4TCP(src: phone, dst: f1, srcPort: 50001, dstPort: 443, flags: flags, payload: payload)
                : PacketBuilder.ethernetIPv4TCP(src: f1, dst: phone, srcPort: 443, dstPort: 50001, flags: flags, payload: payload)
        }
        add(1.0, en2, tiktok, nil, outbound, f1Packet(true, flags: syn, []))
        add(1.1, en2, tiktok, nil, outbound, f1Packet(true, flags: pshAck, tlsRecord(clientHello(sni: "video.tiktok.test"))))
        add(1.2, en2, tiktok, nil, inbound, f1Packet(false, flags: pshAck, filler(1000)))
        add(1.3, en2, tiktok, nil, outbound, f1Packet(true, flags: pshAck, filler(300)))
        add(1.4, en2, tiktok, nil, inbound, f1Packet(false, flags: pshAck, filler(1400)))
        add(1.5, en2, tiktok, nil, inbound, f1Packet(false, flags: pshAck, filler(500)))

        // F2: Instagram, en2, 192.0.2.20:443. first packet is an ACK (midstream), no name
        // payloads 100 out, 1200 in, 0 out -> ip 140 + 1240 + 40 = 1420 bytes, 3 packets
        let f2 = PacketBuilder.v4(192, 0, 2, 20)
        add(2.0, en2, instagram, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f2, srcPort: 50002, dstPort: 443, flags: ack, payload: filler(100)))
        add(2.1, en2, instagram, nil, inbound, PacketBuilder.ethernetIPv4TCP(
            src: f2, dst: phone, srcPort: 443, dstPort: 50002, flags: ack, payload: filler(1200)))
        add(2.2, en2, instagram, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f2, srcPort: 50002, dstPort: 443, flags: ack))

        // F3: TikTok, en2, UDP 192.0.2.30:443. QUIC Initial with SNI cdn.tiktok.test, then 2 more packets
        // initial is padded to 1200 bytes: ip 20 + 8 + 1200 = 1228
        // then 1100 in -> 1128, 300 out -> 328. total 1228 + 1128 + 328 = 2684 bytes, 3 packets
        let f3 = PacketBuilder.v4(192, 0, 2, 30)
        let initial = quicInitial(
            dcid: [1, 2, 3, 4, 5, 6, 7, 8], frames: cryptoFrame(offset: 0, clientHello(sni: "cdn.tiktok.test")))
        add(3.0, en2, tiktok, nil, outbound, PacketBuilder.ethernetIPv4UDP(
            src: phone, dst: f3, srcPort: 50003, dstPort: 443, payload: initial))
        add(3.1, en2, tiktok, nil, inbound, PacketBuilder.ethernetIPv4UDP(
            src: f3, dst: phone, srcPort: 443, dstPort: 50003, payload: filler(1100)))
        add(3.2, en2, tiktok, nil, outbound, PacketBuilder.ethernetIPv4UDP(
            src: phone, dst: f3, srcPort: 50003, dstPort: 443, payload: filler(300)))

        // F4: heartbeatd, en0, IPv6 TCP to fd5d::1:62078. SYN, SYN-ACK, ACK with no payload
        // each ip 40 + 20 = 60 -> 180 bytes, 3 packets
        let hb = PacketBuilder.v6(0xFD5D, 0, 0, 0, 0, 0, 0, 1)
        let hbLocal = PacketBuilder.v6(0xFD5D, 0, 0, 0, 0, 0, 0, 2)
        add(4.0, en0, heartbeat, nil, outbound, PacketBuilder.ethernetIPv6TCP(
            src: hbLocal, dst: hb, srcPort: 50004, dstPort: 62078, flags: syn))
        add(4.1, en0, heartbeat, nil, inbound, PacketBuilder.ethernetIPv6TCP(
            src: hb, dst: hbLocal, srcPort: 62078, dstPort: 50004, flags: synAck))
        add(4.2, en0, heartbeat, nil, outbound, PacketBuilder.ethernetIPv6TCP(
            src: hbLocal, dst: hb, srcPort: 50004, dstPort: 62078, flags: ack))

        // F5: no process, en0, UDP mDNS to 224.0.0.251:5353. payloads 40 and 60
        // ip 20 + 8 + 40 = 68, 20 + 8 + 60 = 88 -> 156 bytes, 2 packets
        let mdnsGroup = PacketBuilder.v4(224, 0, 0, 251)
        add(5.0, en0, nil, nil, outbound, PacketBuilder.ethernetIPv4UDP(
            src: phone, dst: mdnsGroup, srcPort: 5353, dstPort: 5353, payload: [UInt8](repeating: 0, count: 40)))
        add(5.5, en0, nil, nil, outbound, PacketBuilder.ethernetIPv4UDP(
            src: phone, dst: mdnsGroup, srcPort: 5353, dstPort: 5353, payload: [UInt8](repeating: 0, count: 60)))

        // F7: Safari, en0, 192.0.2.70:443. SYN, hello with SNI outer.example (13 bytes) and an ECH extension, 600 in
        // syn 40; hello record 109 + 13 = 122, ip 20 + 20 + 122 = 162; data ip 20 + 20 + 600 = 640
        // total 40 + 162 + 640 = 842 bytes, 3 packets
        let f7 = PacketBuilder.v4(192, 0, 2, 70)
        add(6.0, en0, safari, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f7, srcPort: 50007, dstPort: 443, flags: syn))
        add(6.1, en0, safari, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f7, srcPort: 50007, dstPort: 443, flags: pshAck,
            payload: tlsRecord(clientHello(sni: "outer.example", extraExtensions: [(0xFE0D, [0, 1, 2])]))))
        add(6.2, en0, safari, nil, inbound, PacketBuilder.ethernetIPv4TCP(
            src: f7, dst: phone, srcPort: 443, dstPort: 50007, flags: pshAck, payload: filler(600)))

        // F8: Safari, en0, one UDP datagram (192.0.2.80:9000, 200 data bytes) split in two IPv4 fragments
        // first fragment: MF set, offset 0, carries the UDP header (length field 208) and 96 data bytes
        //   ip 20 + 8 + 96 = 124. the decoder parses its ports, so it is counted in a flow: 124 bytes, 1 packet
        // second fragment: offset 13 (104 / 8), 104 raw bytes, ip 20 + 104 = 124. no ports: droppedNoPort, in no flow
        let f8 = PacketBuilder.v4(192, 0, 2, 80)
        let firstFragment = PacketBuilder.udp(srcPort: 50008, dstPort: 9000, payload: filler(96), lengthOverride: 208)
        add(7.0, en0, safari, nil, outbound, PacketBuilder.ethernetIPv4Fragment(
            src: phone, dst: f8, proto: 17, offsetUnits: 0, moreFragments: true, body: firstFragment))
        add(7.1, en0, safari, nil, outbound, PacketBuilder.ethernetIPv4Fragment(
            src: phone, dst: f8, proto: 17, offsetUnits: 13, moreFragments: false, body: filler(104)))

        // F9: appstorecomponen, pdp_ip0, 192.0.2.90:443. SYN, SYN-ACK, 200 bytes out, no SNI
        // ip 40 + 40 + 240 = 320 bytes, 3 packets
        let f9 = PacketBuilder.v4(192, 0, 2, 90)
        add(8.0, pdp, appstore, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f9, srcPort: 50009, dstPort: 443, flags: syn))
        add(8.1, pdp, appstore, nil, inbound, PacketBuilder.ethernetIPv4TCP(
            src: f9, dst: phone, srcPort: 443, dstPort: 50009, flags: synAck))
        add(8.2, pdp, appstore, nil, outbound, PacketBuilder.ethernetIPv4TCP(
            src: phone, dst: f9, srcPort: 50009, dstPort: 443, flags: pshAck, payload: filler(200)))

        // ARP: skipped by the decoder, in no flow
        add(9.0, en0, nil, nil, 0, PacketBuilder.ethernetARP())

        // D6: DNS answer (AAAA) site.example -> 2001:db8::5, TTL 300, 30 s before F6, for Safari
        // question name "site.example" = 2 length bytes + 11 letters + 1 terminator = 14
        // dns = 12 + 14 + 4 + (2 + 2 + 2 + 4 + 2 + 16) = 58; ipv6 40 + 8 + 58 = 106
        let f6 = PacketBuilder.v6(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 5)
        add(10.0, en0, mdns, safari, inbound, PacketBuilder.ethernetIPv6UDP(
            src: dns6, dst: phone6, srcPort: 53, dstPort: 53006,
            payload: dnsResponse(
                question: "site.example",
                records: [DNSRecord(type: 28, ttl: 300, rdata: f6)])))

        // F6: Safari, en0, IPv6 TCP to 2001:db8::5:443, no hello. SYN, SYN-ACK, 100 out, 900 in
        // ip 60 + 60 + (60 + 100) + (60 + 900) = 1240 bytes, 4 packets
        add(40.0, en0, safari, nil, outbound, PacketBuilder.ethernetIPv6TCP(
            src: phone6, dst: f6, srcPort: 50006, dstPort: 443, flags: syn))
        add(40.1, en0, safari, nil, inbound, PacketBuilder.ethernetIPv6TCP(
            src: f6, dst: phone6, srcPort: 443, dstPort: 50006, flags: synAck))
        add(40.2, en0, safari, nil, outbound, PacketBuilder.ethernetIPv6TCP(
            src: phone6, dst: f6, srcPort: 50006, dstPort: 443, flags: pshAck, payload: filler(100)))
        add(40.3, en0, safari, nil, inbound, PacketBuilder.ethernetIPv6TCP(
            src: f6, dst: phone6, srcPort: 443, dstPort: 50006, flags: pshAck, payload: filler(900)))

        var bytes = PCAPNGBuilder.sectionHeader()
            + PCAPNGBuilder.interface("en2") + PCAPNGBuilder.interface("en0") + PCAPNGBuilder.interface("pdp_ip0")
        for (pid, name) in [
            (212, "mDNSResponder"), (19_475, "TikTok"), (4_321, "Instagram"),
            (98, "heartbeatd"), (3_003, "Safari"), (777, "appstorecomponen"),
        ] {
            bytes += PCAPNGBuilder.process(pid: UInt32(pid), name: name)
        }
        // times are distinct, so the sort order is fully defined
        for f in frames.sorted(by: { $0.at < $1.at }) {
            bytes += PCAPNGBuilder.packet(
                interface: f.interface, microseconds: UInt64((Double(start) + f.at) * 1_000_000),
                process: f.process, effective: f.effective, flags: f.direction == 0 ? nil : f.direction,
                payload: f.bytes)
        }
        return (bytes, expected())
    }

    /// the same capture followed by the 24-byte pcap header tcpdump appends
    public static func withTrailer() -> (bytes: [UInt8], expected: Expected) {
        let m = mixed()
        return (m.bytes + PCAPNGBuilder.pcapTrailer, m.expected)
    }

    // MARK: answers

    private static func expected() -> Expected {
        func v4(_ a: UInt32) -> IPAddress { .v4(a) }
        let flows: [ExpectedFlow] = [
            // 79 bytes, 1 packet (arithmetic at the frame)
            ExpectedFlow(label: "D1", remote: v4(0xC000_0235), remotePort: 53, interface: "en2",
                packets: 1, ipBytes: 79, serverName: nil, startedMidstream: false, echSeen: false),
            // 40 + 159 + 3360 = 3559, 1 + 1 + 4 packets
            ExpectedFlow(label: "F1", remote: v4(0xC000_020A), remotePort: 443, interface: "en2",
                packets: 6, ipBytes: 3559, serverName: "video.tiktok.test", startedMidstream: false, echSeen: false),
            // 140 + 1240 + 40 = 1420
            ExpectedFlow(label: "F2", remote: v4(0xC000_0214), remotePort: 443, interface: "en2",
                packets: 3, ipBytes: 1420, serverName: nil, startedMidstream: true, echSeen: false),
            // 1228 + 1128 + 328 = 2684
            ExpectedFlow(label: "F3", remote: v4(0xC000_021E), remotePort: 443, interface: "en2",
                packets: 3, ipBytes: 2684, serverName: "cdn.tiktok.test", startedMidstream: false, echSeen: false),
            // 60 + 60 + 60 = 180
            ExpectedFlow(label: "F4", remote: .v6(hi: 0xFD5D_0000_0000_0000, lo: 1), remotePort: 62078, interface: "en0",
                packets: 3, ipBytes: 180, serverName: nil, startedMidstream: false, echSeen: false),
            // 68 + 88 = 156
            ExpectedFlow(label: "F5", remote: v4(0xE000_00FB), remotePort: 5353, interface: "en0",
                packets: 2, ipBytes: 156, serverName: nil, startedMidstream: false, echSeen: false),
            // 60 + 60 + 160 + 960 = 1240
            ExpectedFlow(label: "F6", remote: .v6(hi: 0x2001_0DB8_0000_0000, lo: 5), remotePort: 443, interface: "en0",
                packets: 4, ipBytes: 1240, serverName: nil, startedMidstream: false, echSeen: false),
            // 40 + 162 + 640 = 842. the name is the public outer name
            ExpectedFlow(label: "F7", remote: v4(0xC000_0246), remotePort: 443, interface: "en0",
                packets: 3, ipBytes: 842, serverName: "outer.example", startedMidstream: false, echSeen: true),
            // first fragment only: 20 + 8 + 96 = 124
            ExpectedFlow(label: "F8", remote: v4(0xC000_0250), remotePort: 9000, interface: "en0",
                packets: 1, ipBytes: 124, serverName: nil, startedMidstream: false, echSeen: false),
            // 40 + 40 + 240 = 320
            ExpectedFlow(label: "F9", remote: v4(0xC000_025A), remotePort: 443, interface: "pdp_ip0",
                packets: 3, ipBytes: 320, serverName: nil, startedMidstream: false, echSeen: false),
            // 106 bytes, 1 packet
            ExpectedFlow(label: "D6", remote: .v6(hi: 0x2001_0DB8_0000_0000, lo: 0x53), remotePort: 53, interface: "en0",
                packets: 1, ipBytes: 106, serverName: nil, startedMidstream: false, echSeen: false),
        ]
        return Expected(
            flows: flows,
            // D1, F1..F9, D6
            flowCount: 11,
            // 1 + 6 + 3 + 3 + 3 + 2 + 4 + 3 + 1 + 3 + 1 = 30
            flowPackets: 30,
            // 79 + 3559 + 1420 + 2684 + 180 + 156 + 1240 + 842 + 124 + 320 + 106 = 10710
            ipBytes: 10710,
            byInterface: [
                // D1 79 + F1 3559 + F2 1420 + F3 2684 = 7742
                "en2": 7742,
                // F4 180 + F5 156 + F6 1240 + F7 842 + F8 124 + D6 106 = 2648
                "en0": 2648,
                // F9 = 320
                "pdp_ip0": 320,
            ],
            // 30 in flows + the dropped fragment + the ARP frame
            packetsRead: 32,
            decoded: 31,
            skipped: 1,
            malformed: 0,
            // the second fragment of F8
            droppedNoPort: 1,
            // only F5 has no process on any packet
            noProcessBytes: 156,
            // everything except F5: 10710 - 156 = 10554
            attributedBytes: 10554,
            // 443 flows: F1 3559 + F2 1420 + F3 2684 + F6 1240 + F7 842 + F9 320 = 10065
            port443Bytes: 10065,
            // flows with any serverName (M1 view): F1 3559 + F3 2684 + F7 842 = 7085
            sniNamedBytes: 7085,
            // no flow has two app names
            mixedBytes: 0,
            // classification per flow (4.1 rules). process names: mDNSResponder is a system process, appstorecomponen
            // is not in the system list (so F9 is an app), heartbeatd is a device link process
            //   D1 mDNSResponder for TikTok -> helper.eproc      D6 mDNSResponder for Safari -> helper.eproc
            //   F1 F2 F3 TikTok/Instagram/TikTok, F6 F7 F8 Safari, F9 appstorecomponen -> app.process
            //   F4 heartbeatd -> deviceLink.process              F5 no process, 224.0.0.251 -> localNetwork.address
            // app: F1 3559 + F2 1420 + F3 2684 + F6 1240 + F7 842 + F8 124 + F9 320 = 10189
            // helper: D1 79 + D6 106 = 185. deviceLink: F4 180. localNetwork: F5 156. system 0, unknown 0
            // 10189 + 185 + 180 + 156 = 10710
            categoryBytes: ["app": 10189, "helper": 185, "system": 0, "deviceLink": 180, "localNetwork": 156, "unknown": 0],
            // app 7 flows (F1 F2 F3 F6 F7 F8 F9), helper 2 (D1 D6), deviceLink 1 (F4), localNetwork 1 (F5): 11
            categoryFlows: ["app": 7, "helper": 2, "system": 0, "deviceLink": 1, "localNetwork": 1, "unknown": 0],
            // app 6 + 3 + 3 + 4 + 3 + 1 + 3 = 23, helper 1 + 1 = 2, deviceLink 3, localNetwork 2: 30
            categoryPackets: ["app": 23, "helper": 2, "system": 0, "deviceLink": 3, "localNetwork": 2, "unknown": 0],
            // each flow has one rule, so rule bytes equal category bytes here (deviceLink.linkLocal never fires)
            ruleBytes: ["app.process": 10189, "helper.eproc": 185, "deviceLink.process": 180, "localNetwork.address": 156],
            // F4 was `.app(heartbeatd)` in M1 -> deviceLink 180. F5 was `.unknown` in M1, so it is not "moved": 0
            movedOutOfAppBytes: ["deviceLink": 180, "localNetwork": 0],
            // app + helper + system + unknown = 10189 + 185 + 0 + 0 = 10374 (10710 - 180 - 156)
            phoneTrafficBytes: 10374,
            // F1 sni, F3 sni (quic), F6 dns (answer 30 s before, Safari matches), F7 echHidden (outer name not used),
            // F2 startedBeforeCapture (first packet is an ack), F9 noDNSMatch. F9 is `app` here, not `system`
            // (appstorecomponen is not in the system list), so it is in the denominator. no udp 443 flow is
            // unnamed (F3 has its name), so noHandshakeUDP is 0; a unit test covers that reason
            hostnameOutcome: [
                "F1": "sni", "F3": "sni", "F6": "dns", "F7": "echHidden", "F2": "startedBeforeCapture", "F9": "noDNSMatch",
            ],
            // all six 443 flows are app traffic: 3559 + 1420 + 2684 + 1240 + 842 + 320 = 10065 (= port443Bytes)
            hostnameDenominatorBytes: 10065,
            // sni: F1 3559 + F3 2684 = 6243
            sniBytes: 6243,
            // dns: F6 1240
            dnsBytes: 1240,
            // echHidden F7 842, startedBeforeCapture F2 1420, noHandshakeUDP 0, noDNSMatch F9 320
            // 6243 + 1240 + 842 + 1420 + 0 + 320 = 10065
            unnamedBytes: ["echHidden": 842, "startedBeforeCapture": 1420, "noHandshakeUDP": 0, "noDNSMatch": 320],
            // tcp 443 midstream: F2 1420
            midstreamBytes: 1420,
            // echSeen: F7 842
            echBytes: 842,
            // sni name and a dns match: only F1 (D1 answers video.tiktok.test for 192.0.2.10, 1 s before F1, TikTok
            // matches). the names are equal: 3559 of 3559. F3 has no dns answer; F7 is ech and excluded
            dnsPrecisionAgreeBytes: 3559,
            dnsPrecisionBytes: 3559)
    }
}
