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

@Test func guardAllowsOnlyLabelledDatasetCommits() {
    let hash = String(repeating: "ab12", count: 10)
    let list = "Sources/Companies/Resources/psl.dat", manifest = "Sources/Companies/Resources/manifest.json"
    #expect(!RepoGuard.hasDeviceIdentifier("// COMMIT: \(hash)", path: list))
    #expect(!RepoGuard.hasDeviceIdentifier("      \"commit\": \"\(hash)\",", path: manifest))
    #expect(RepoGuard.hasDeviceIdentifier("note \(hash) unlabelled", path: list))
    #expect(RepoGuard.hasDeviceIdentifier("// commit of nothing \(hash)", path: list))
    // each label is allowed in its own file only, not repo-wide and not in the other file
    #expect(RepoGuard.hasDeviceIdentifier("// COMMIT: \(hash)"))
    #expect(RepoGuard.hasDeviceIdentifier("// COMMIT: \(hash)", path: manifest))
    #expect(RepoGuard.hasDeviceIdentifier("\"commit\": \"\(hash)\"", path: list))
    #expect(RepoGuard.hasDeviceIdentifier("\"commit\": \"\(hash)\"", path: "Sources/Other/data.json"))
}

@Test func guardScanAppliesTheCommitExceptionByPath() throws {
    let hash = String(repeating: "cd34", count: 10)
    let root = try makeTree([
        "Sources/Companies/Resources/manifest.json": "  \"commit\": \"\(hash)\",\n",
        "Sources/Elsewhere/manifest.json": "  \"commit\": \"\(hash)\",\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let violations = RepoGuard.scan(root: root)
    #expect(violations.count == 1)
    #expect(violations.first?.hasPrefix("Sources/Elsewhere/manifest.json:") == true)
}

@Test func guardRejectsPrivacyReportFile() throws {
    // keys are joined from pieces so this source file holds no line that looks like an export
    let keys = ["bundleID", "domainOwner", "hits", "firstTimeStamp"].map { "\"\($0)\":1" }
    let record = "{" + keys.joined(separator: ",") + "}"
    let root = try makeTree([
        "reports/App_Privacy_Report_v4_2026-01-01T00_00_00.ndjson": "x\n",
        "notes/renamed.txt": record + "\n",
        "notes/pretty.json": "[\n" + record + "\n]\n",
        "data/lines.jsonl": "x\n",
        "docs/fields.md": "the export has bundleID, domainOwner, firstTimeStamp and hits fields\n",
        "docs/two.json": "{\"bundleID\":1,\"domainOwner\":2}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let violations = RepoGuard.scan(root: root)
    #expect(violations.count == 4)
    for needle in [
        "reports/App_Privacy_Report_v4_2026-01-01T00_00_00.ndjson", "notes/renamed.txt", "notes/pretty.json",
        "data/lines.jsonl",
    ] {
        #expect(violations.contains { $0.hasPrefix(needle + ":") })
    }
    // the committed tree passes
    #expect(RepoGuard.scan(root: try #require(RepoGuard.repoRoot())) == [])
}

@Test func repoIsClean() throws {
    let root = try #require(RepoGuard.repoRoot())
    #expect(RepoGuard.scan(root: root) == [])
}

@Test func guardRejectsSchemaShapeOutput() throws {
    let root = try makeTree(["Tests/Resources/schema-shape.txt": "shape", "notes/readme.txt": "plain"])
    defer { try? FileManager.default.removeItem(at: root) }
    let violations = RepoGuard.scan(root: root)
    #expect(violations.count == 1)
    #expect(violations.first?.hasPrefix("Tests/Resources/schema-shape.txt:") == true)
}
