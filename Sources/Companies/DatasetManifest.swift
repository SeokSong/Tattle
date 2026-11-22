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

    /// location of a file in the bundled Resources folder. note: if the code ever ships inside an
    /// .app bundle, SwiftPM's resource bundle must be copied into it or this returns nil
    public static func resourceURL(_ name: String) -> URL? {
        let base = Bundle.module.bundleURL.appendingPathComponent("Resources/" + name)
        if FileManager.default.fileExists(atPath: base.path) { return base }
        // an app bundle may lay the resources out differently; ask the bundle itself
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: nil)
    }

    public static func load() throws -> DatasetManifest {
        guard let url = resourceURL("manifest.json") else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(DatasetManifest.self, from: Data(contentsOf: url))
    }
}
