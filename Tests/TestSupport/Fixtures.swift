import Foundation

// fixture captures live outside the repo; tests skip when WATCH_FIXTURES is unset
public enum Fixtures {
    public static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["WATCH_FIXTURES"], !path.isEmpty else {
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
