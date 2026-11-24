import Domains
import Flows
import Foundation
import PacketDecoder

public enum SummaryWeek {
    /// a deterministic synthetic week: `count` flows to port 443 across 50 apps and the system, 2000 hostnames.
    /// every 10th flow (i % 10 == 1) is a curated name (doubleclick.net, Alphabet) and every 10th (i % 10 == 3) an
    /// AdGuard name with a category and no company (adworxs.net), so the identified and unnamed-category paths are
    /// timed too; i % 10 == 7 has no name and started before the capture
    public static func flows(count: Int) -> [Flow] {
        let local = IPAddress.v4(0xCB00_7102)
        return (0..<count).map { i in
            let key = FlowKey(
                transport: .tcp, localAddress: local, localPort: UInt16(1024 + i % 60000),
                remoteAddress: .v4(0xC612_0000 + UInt32(i % 65536)), remotePort: 443)
            var f = Flow(key: key, interface: "en0", at: Date(timeIntervalSince1970: 1_763_000_000 + Double(i)))
            f.lastSeen = f.firstSeen
            let app = (i / 10) % 50
            let process = ProcessPair(i % 10 == 9 ? "nsurlsessiond" : "WeekApp\(app)", UInt32(1000 + app), nil, nil)
            f.tally[process] = 3
            switch i % 10 {
            case 7: f.serverName = nil
            case 1: f.serverName = "a\(i % 2000).doubleclick.net"
            case 3: f.serverName = "x\(i % 50).adworxs.net"
            default: f.serverName = "h\(i % 2000).week\(i % 300).test"
            }
            f.startedMidstream = (i % 10 == 7)
            f.ipBytesIn = 1000 + i % 500
            f.ipBytesOut = 200
            return f
        }
    }
}
