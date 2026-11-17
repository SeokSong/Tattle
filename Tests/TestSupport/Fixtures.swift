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
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static let all = [
        "watch-clean-test.pcap",
        "watch-safari-test.pcap",
        "watch-test.pcap",
        "watch-youtube-test.pcap",
        "multi-app-test.pcap",
    ]
}
