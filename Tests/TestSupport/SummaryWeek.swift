import Domains
import Flows
import Foundation
import PacketDecoder

public enum SummaryWeek {
    /// a deterministic synthetic week: `count` flows to port 443 across 50 apps and the system, 2000 hostnames
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
            f.serverName = i % 10 == 7 ? nil : "h\(i % 2000).week\(i % 300).test"
            f.startedMidstream = (i % 10 == 7)
            f.ipBytesIn = 1000 + i % 500
            f.ipBytesOut = 200
            return f
        }
    }
}
