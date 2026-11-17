import Foundation
import Testing
import TestSupport

private func makeTree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("repoguard-\(UUID().uuidString)", isDirectory: true)
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    return root
}

@Test func guardFindsForbiddenFiles() throws {
    // built from pieces so this source file does not trip the guard itself
    let udid = "00008120" + "-" + "0012AB34CD56E78F"
    let root = try makeTree([
        "captures/a.pcapng": "x",
        "notes/log.txt": "device \(udid) seen",
        "Tests/Expected/x.json": #"{"host":"www.example.com"}"#,
        "Tests/Expected/y.json": "10.1.2.3",
        "skipped/.build/z.pcap": "x",
        "img/shot.pcap": "x",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let violations = RepoGuard.scan(root: root)
    #expect(violations.count == 4)
    for needle in ["captures/a.pcapng", "notes/log.txt", "Tests/Expected/x.json", "Tests/Expected/y.json"] {
        #expect(violations.contains { $0.hasPrefix(needle + ":") })
    }
    for v in violations {
        #expect(!v.contains(udid) && !v.contains("example.com") && !v.contains("10.1.2.3"))
    }
}

@Test func guardAcceptsCleanTree() throws {
    let root = try makeTree([
        "Sources/A/a.swift": "let x = 1 // visit nothing\n",
        "Tests/Expected/band.json": "[0, 12, 345, 6789]\n",
        "README.md": "plain text, version 1.2.3\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(RepoGuard.scan(root: root).isEmpty)
}

@Test func repoIsClean() throws {
    let root = try #require(RepoGuard.repoRoot())
    #expect(RepoGuard.scan(root: root) == [])
}
