import Foundation
import Testing

@testable import Storage

// the privacy gate (Milestone 3, 6.1): every table the database really creates must be described in md/STORAGE.md,
// so a new store cannot be added without its row in the docs. reads the doc; fails on a missing table name
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func everyDatabaseTableIsInTheStorageDoc() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tattle-doc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try Store(path: folder.appendingPathComponent("watch.sqlite"))
    let st = try store.db.statement("select name from sqlite_master where type = 'table' and name not like 'sqlite_%'")
    defer { st.reset() }
    var tables: [String] = []
    while try st.step() { tables.append(st.text(0) ?? "") }
    #expect(tables.count >= 8, "the schema lost tables: \(tables)")

    let doc = try String(contentsOf: root.appendingPathComponent("md/STORAGE.md"), encoding: .utf8)
    // the doc describes a table either as its create statement (versions 1 and 2) or as the first cell of a
    // schema-table row (version 3)
    for table in tables {
        #expect(doc.contains("create table \(table) (") || doc.contains("| `\(table)` |"),
                "md/STORAGE.md has no schema for the table \(table)")
    }
}
