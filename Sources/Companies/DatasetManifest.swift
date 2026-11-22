import Foundation

/// provenance of a bundled dataset, read from Resources/manifest.json
public struct DatasetManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let file: String
        public let version: String
        public let commit: String
        public let sourceURL: String
        public let licence: String
        public let fetched: String
        /// SHA-256 of the shipped data file
        public let sha256: String
        /// SHA-256 of the list as downloaded, before the script cleaned it
        public let sourceSHA256: String
        public let rules: Int
    }

    public let datasets: [Entry]

    /// the file name SwiftPM gives this target's resource bundle
    public static let bundleName = "Tattle_Companies.bundle"

    private final class Anchor {}

    /// where the resource bundle is looked for by default: next to the executable, in the app's
    /// resources, beside the main bundle, and beside the bundle this code was linked into (a test bundle)
    public static var defaultSearchDirectories: [URL] {
        var dirs: [URL] = []
        if let exe = Bundle.main.executableURL { dirs.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        dirs.append(Bundle.main.bundleURL)
        dirs.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        let own = Bundle(for: Anchor.self).bundleURL
        dirs.append(own)
        dirs.append(own.deletingLastPathComponent())
        return dirs
    }

    /// the resource bundle folder, or nil when none of `searchDirectories` holds it. SwiftPM's generated
    /// `Bundle.module` traps when the bundle is absent, so it is never used: a missing bundle means
    /// the datasets read as empty and the screens say the lists could not be read
    public static func locateBundle(in searchDirectories: [URL]) -> URL? {
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(bundleName, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static let defaultBundle: URL? = locateBundle(in: defaultSearchDirectories)

    /// location of a file in the bundled Resources folder, or nil when the bundle or the file is not
    /// there. `searchDirectories` replaces the default search (tests pass a fake location)
    public static func resourceURL(_ name: String, searchDirectories: [URL]? = nil) -> URL? {
        guard let bundle = searchDirectories.map({ locateBundle(in: $0) }) ?? defaultBundle else { return nil }
        // SwiftPM copies the Resources folder whole; an app bundle may lay the files out flat
        for path in ["Resources/" + name, name] {
            let url = bundle.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static func load(searchDirectories: [URL]? = nil) throws -> DatasetManifest {
        guard let url = resourceURL("manifest.json", searchDirectories: searchDirectories) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(DatasetManifest.self, from: Data(contentsOf: url))
    }
}
