import Foundation

// scans a source tree for personal data that must never be committed. violation
// descriptions name the path and the rule, never the text that matched.
public enum RepoGuard {
    static let skippedFolders: Set<String> = [".build", ".git", "img"]
    static let forbiddenExtensions: Set<String> = ["pcap", "pcapng", "sqlite", "sqlite-wal", "sqlite-shm"]
    static let topLevelDomains = [
        "com", "net", "org", "io", "co", "app", "dev", "me", "tv", "ai", "apple", "cn", "jp",
        "uk", "de", "kr", "fr", "ru", "in", "br", "us", "edu", "gov", "info", "cloud",
    ]
    static let maxTextBytes = 8_000_000

    nonisolated(unsafe) private static let udid = try! NSRegularExpression(
        pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#)
    nonisolated(unsafe) private static let hex40 = try! NSRegularExpression(
        pattern: #"\b[0-9A-Fa-f]{40}\b"#)
    nonisolated(unsafe) private static let ipv4 = try! NSRegularExpression(
        pattern: #"\b\d{1,3}(\.\d{1,3}){3}\b"#)
    nonisolated(unsafe) private static let hostname = try! NSRegularExpression(
        pattern: #"\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(\#(topLevelDomains.joined(separator: "|")))\b"#,
        options: [.caseInsensitive])

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // three documented exceptions, so docs and data can quote public values: a 40-hex value on a
    // line that mentions a salt (the public quic initial salts), the placeholder udid used
    // as an example in the plan (built from pieces so this file stays clean), and the git
    // commit of a bundled dataset, only on a line that starts with its label and only in the one
    // file that carries it: "// COMMIT:" in the public suffix list header, a "commit" key in the manifest
    static let placeholderUDID = "00008110" + "-" + "001A2B3C4D5E601E"
    static let suffixListPath = "Sources/Companies/Resources/psl.dat"
    static let manifestPath = "Sources/Companies/Resources/manifest.json"

    /// `path` is relative to the repo root; the commit-label exceptions apply only to the two files above
    public static func hasDeviceIdentifier(_ text: String, path: String? = nil) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            let lower = line.lowercased()
            if matches(udid, line), !lower.contains(placeholderUDID.lowercased()) { return true }
            let trimmed = lower.trimmingCharacters(in: .whitespaces)
            let isCommitLabel = (path == suffixListPath && trimmed.hasPrefix("// commit:"))
                || (path == manifestPath && trimmed.hasPrefix("\"commit\":"))
            if matches(hex40, line), !lower.contains("salt"), !isCommitLabel { return true }
        }
        return false
    }

    public static func scan(root: URL) -> [String] {
        guard let paths = FileManager.default.enumerator(atPath: root.path) else {
            return ["\(root.lastPathComponent): cannot read folder"]
        }
        var violations: [String] = []
        for case let relative as String in paths {
            let parts = relative.split(separator: "/").map(String.init)
            if parts.contains(where: { skippedFolders.contains($0) }) { continue }
            let url = root.appendingPathComponent(relative)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            if forbiddenExtensions.contains(url.pathExtension.lowercased()) {
                violations.append("\(relative): capture or database file")
                continue
            }
            guard let data = try? Data(contentsOf: url), data.count <= maxTextBytes,
                  !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }

            if hasDeviceIdentifier(text, path: relative) {
                violations.append("\(relative): device identifier (udid-like or 40 hex characters)")
            }
            if relative.hasPrefix("Tests/Expected/") {
                if matches(ipv4, text) { violations.append("\(relative): ip address in expected output") }
                if matches(hostname, text) { violations.append("\(relative): hostname in expected output") }
            }
        }
        return violations.sorted()
    }

    // folder holding Package.swift, found by walking up from a source file path
    public static func repoRoot(from file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
