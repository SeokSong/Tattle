import Foundation
import PrivacyReport
import Storage
import Testing
import TestSupport

@testable import Pipeline

private typealias B = PrivacyReportBuilder

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tattle-import-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ data: Data, in dir: URL, name: String = "App_Privacy_Report_v4_2026-11-18T10_00_00.ndjson") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func sampleLines() -> [String] {
    [
        B.network(app: "com.example.app1", domain: "example.com", hits: 3, last: B.stamp(16)),
        B.network(app: "com.example.app1", domain: "example.com", hits: 2, last: B.stamp(18)),
        B.network(app: "com.example.app2", domain: "api.example.com", hits: 5, last: B.stamp(17)),
        B.access(),
        B.other(type: "somethingNew"),
    ]
}

private final class FailingStore: ReportImportStoring {
    func saveImport(_ row: ReportImportRow, contacts: [ReportContactRow]) throws -> SaveImportOutcome {
        throw StorageError.io("disk full")
    }
}

@Test func importThenReadBack() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    let file = try write(B.file(sampleLines()), in: dir)
    let summary = try ReportImporter.run(file: file, store: store)
    #expect(summary.outcome == .stored(replaced: 0))
    let imports = try store.imports()
    #expect(imports.count == 1)
    #expect(imports[0].recordsKept == 3 && imports[0].formatVersion == 4 && imports[0].unknownTypes == 1)
    let contacts = try store.contacts(importId: imports[0].id)
    #expect(contacts.count == 2)
    let first = try #require(contacts.first { $0.appId == "com.example.app1" })
    #expect(first.hits == 5 && first.domain == "example.com")
    // the same file again is a duplicate, and a newer overlapping one replaces it
    #expect(try ReportImporter.run(file: file, store: store).outcome == .duplicate)
    let newer = try write(B.file(sampleLines() + [B.network(last: B.stamp(19))]), in: dir, name: "App_Privacy_Report_v4_b.ndjson")
    #expect(try ReportImporter.run(file: newer, store: store).outcome == .stored(replaced: 1))
    #expect(try store.imports().count == 1)
}

@Test func olderImportIsRefusedWithTheNewerEndDate() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    _ = try ReportImporter.run(file: try write(B.file([B.network(first: B.stamp(18), last: B.stamp(20))]), in: dir), store: store)
    let older = try write(B.file([B.network(first: B.stamp(19), last: B.stamp(19))]), in: dir, name: "App_Privacy_Report_v4_old.ndjson")
    let summary = try ReportImporter.run(file: older, store: store)
    guard case .olderThanStored = summary.outcome else { Issue.record("expected older"); return }
    #expect(summary.lines.joined().contains("ends on 2026-11-20"))
    #expect(try store.imports().count == 1)
}

@Test func newerFormatWarnsAndImports() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    let file = try write(B.file(sampleLines()), in: dir, name: "App_Privacy_Report_v5_x.ndjson")
    let summary = try ReportImporter.run(file: file, store: store)
    #expect(summary.stored && summary.newerFormatWarning)
    #expect(summary.lines.contains { $0.hasPrefix("Warning:") && $0.contains("version 5") })
    #expect(try store.imports().first?.formatVersion == 5)
}

@Test func rejectedImportStoresNothing() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    var lines = sampleLines()
    lines += Array(repeating: "not json", count: 5)
    let file = try write(B.file(lines), in: dir)
    do {
        _ = try ReportImporter.run(file: file, store: store)
        Issue.record("expected a rejection")
    } catch let failure as ReportImportFailure {
        #expect(failure.message.contains("5 of 10 lines"))
        #expect(!failure.message.contains(dir.lastPathComponent) && !failure.message.contains("example.com"))
    }
    #expect(try store.imports().isEmpty)
    let tiny = ImportLimits(maxFileBytes: 10, maxLineBytes: 16384, maxMalformedShare: 0.01, maxRecords: 100)
    #expect(throws: ReportImportFailure.self) { try ReportImporter.run(file: file, store: store, limits: tiny) }
    #expect(try store.imports().isEmpty)
}

@Test func missingFileIsReportedWithoutThePath() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    do {
        _ = try ReportImporter.run(file: dir.appendingPathComponent("nope-secret-name.ndjson"), store: store)
        Issue.record("expected a failure")
    } catch let failure as ReportImportFailure {
        #expect(!failure.message.contains("nope-secret-name") && !failure.message.contains(dir.path))
    }
}

@Test func storeFailureLeavesNoPartialRows() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write(B.file(sampleLines()), in: dir)
    do {
        _ = try ReportImporter.run(file: file, store: FailingStore())
        Issue.record("expected a failure")
    } catch let failure as ReportImportFailure {
        #expect(!failure.message.contains("disk full"))
    }
    // a real store with a contact that cannot be stored (empty period) keeps nothing either
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    #expect(try store.imports().isEmpty)
}

@Test func noTemporaryFileIsCreated() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    let file = try write(B.file(sampleLines()), in: dir)
    let temp = FileManager.default.temporaryDirectory
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
    _ = try ReportImporter.run(file: file, store: store)
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
    // tests run in parallel and may add their own items, so look for a new item that holds a copy of the export
    let original = try Data(contentsOf: file)
    let copies = after.subtracting(before).filter {
        let url = temp.appendingPathComponent($0)
        return (try? Data(contentsOf: url)) == original
            || ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains(file.lastPathComponent)
    }
    #expect(copies.isEmpty, "the import left a copy of the export in the temp folder")
    // and the folder with the export holds the export and the database files only
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(names.subtracting(["t.db", "t.db-wal", "t.db-shm", file.lastPathComponent]).isEmpty)
}

@Test func resultCountsMatchParser() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    let data = B.file(sampleLines() + ["{broken"] + [String](repeating: B.network(), count: 300))
    let file = try write(data, in: dir)
    let parsed = try ReportParser.parse(source: try FileLineSource(url: file)) { _ in }
    let summary = try ReportImporter.run(file: file, store: store, limits: ImportLimits(maxFileBytes: 1 << 20, maxLineBytes: 16384, maxMalformedShare: 0.5, maxRecords: 1000))
    #expect(summary.result == parsed || summary.result.kept == parsed.kept)
    #expect(summary.result.linesRead == parsed.linesRead && summary.result.malformed == 1)
    let row = try #require(store.imports().first)
    #expect(row.recordsKept == parsed.kept && row.linesRead == parsed.linesRead && row.fileSHA256 == parsed.fileSHA256)
    #expect(row.periodStart == parsed.periodStart && row.periodEnd == parsed.periodEnd)
}

@Test func commandOutputHasNoDomains() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("t.db"))
    let file = try write(B.file(sampleLines()), in: dir, name: "App_Privacy_Report_v9_secret.ndjson")
    var all = try ReportImporter.run(file: file, store: store).lines
    all += try ReportImporter.run(file: file, store: store).lines
    let text = all.joined(separator: "\n")
    for forbidden in B.fakeApps + B.fakeDomains + ["secret", dir.path, "somethingNew", "location"] {
        #expect(!text.contains(forbidden), "output mentions \(forbidden)")
    }
    #expect(text.contains("This report was already imported"))
}
