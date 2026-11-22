import Foundation

// fixture captures live outside the repo; tests skip when TATTLE_FIXTURES is unset.
// WATCH_FIXTURES is the deprecated old name, still read as a fallback
public enum Fixtures {
    public static var directory: URL? {
        let env = ProcessInfo.processInfo.environment
        let value = [env["TATTLE_FIXTURES"], env["WATCH_FIXTURES"]].compactMap { $0 }.first { !$0.isEmpty }
        guard let path = value else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static func url(_ name: String) -> URL? {
        guard let directory else { return nil }
        // captures live in captures/ (scripts/fixtures.sh layout); the folder root still works
        for sub in ["captures/", ""] {
            let url = directory.appendingPathComponent(sub + name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static let all = [
        "watch-clean-test.pcap",
        "watch-safari-test.pcap",
        "watch-test.pcap",
        "watch-youtube-test.pcap",
        "multi-app-test.pcap",
    ]

    // scenario captures from the phone requests (found by url() in captures/)
    public static let scenarios = [
        "s0-idle.pcapng",
        "s1-safari.pcapng",
        "s2-two-apps.pcapng",
        "s3-youtube-quic.pcapng",
        "s4-link-failures.pcapng",
    ]
}
