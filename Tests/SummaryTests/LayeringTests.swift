import Foundation
import Testing

// a test file sits at Tests/SummaryTests/, so the repo root is two levels up
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func swiftFiles(in folder: String) -> [URL] {
    let dir = root.appendingPathComponent("Sources/" + folder)
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

// every spelling of an import line: attributes (@testable, @_exported, @preconcurrency), an access level
// (public, internal, package, private, fileprivate) and an import kind (import struct Foo.Bar)
nonisolated(unsafe) private let importLine = try! NSRegularExpression(
    pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#)

/// the top-level modules a source text imports
func importedModules(in text: String) -> Set<String> {
    var found = Set<String>()
    for line in text.split(separator: "\n") {
        let line = String(line)
        let range = NSRange(line.startIndex..., in: line)
        if let match = importLine.firstMatch(in: line, range: range), let r = Range(match.range(at: 1), in: line) {
            found.insert(String(line[r]))
        }
    }
    return found
}

private func imports(_ file: URL) -> Set<String> {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return importedModules(in: text)
}

@Test func importScannerSeesEveryForm() {
    let text = """
        import Foundation
        @testable import A
        public import B
        internal import C
        package import D
        private import E
        fileprivate import F
        @_exported import G
        @_exported public import H
        import struct I.Thing
        // import NotThis
        let import_ = 1
        """
    #expect(importedModules(in: text) == ["Foundation", "A", "B", "C", "D", "E", "F", "G", "H", "I"])
}

@Test func layeringHolds() {
    // the packet path and storage never see company labels
    for folder in ["Pipeline", "Flows", "PacketDecoder", "PCAPNG", "Domains", "Storage", "Attribution", "Report", "Capture"] {
        let files = swiftFiles(in: folder)
        #expect(!files.isEmpty, "no files found in \(folder)")
        for file in files {
            let modules = imports(file)
            #expect(!modules.contains("Companies"), "\(file.lastPathComponent) imports Companies")
            #expect(!modules.contains("Summary"), "\(file.lastPathComponent) imports Summary")
        }
    }
    // the summary side reads flows and names, never storage or the capture path
    let summary = swiftFiles(in: "Summary")
    #expect(!summary.isEmpty)
    for file in summary {
        let modules = imports(file)
        for module in ["Report", "Storage", "TattleApp", "Capture", "Pipeline"] {
            #expect(!modules.contains(module), "\(file.lastPathComponent) imports \(module)")
        }
    }
    // Companies has no dependencies: Foundation only
    let companies = swiftFiles(in: "Companies")
    #expect(!companies.isEmpty)
    for file in companies {
        let extra = imports(file).subtracting(["Foundation"])
        #expect(extra.isEmpty, "\(file.lastPathComponent) imports more than Foundation")
    }
    // PrivacyReport has no dependencies either: Foundation only, so it imports neither Companies nor
    // Storage, and Companies (Foundation only, above) cannot import it
    let report = swiftFiles(in: "PrivacyReport")
    #expect(!report.isEmpty)
    for file in report {
        let extra = imports(file).subtracting(["Foundation"])
        #expect(extra.isEmpty, "\(file.lastPathComponent) imports more than Foundation")
    }
    // Storage never imports the parser: the import glue in Pipeline maps between them
    for file in swiftFiles(in: "Storage") {
        #expect(!imports(file).contains("PrivacyReport"), "\(file.lastPathComponent) imports PrivacyReport")
    }
    // inside Pipeline only the import glue knows the parser; the packet path files do not
    for file in swiftFiles(in: "Pipeline") where file.lastPathComponent != "ReportImporter.swift" {
        #expect(!imports(file).contains("PrivacyReport"), "\(file.lastPathComponent) imports PrivacyReport")
    }
    #expect(swiftFiles(in: "Pipeline").contains { $0.lastPathComponent == "ReportImporter.swift" })
    // the app talks to the importer in Pipeline too: it never imports the parser
    for file in swiftFiles(in: "TattleApp") {
        #expect(!imports(file).contains("PrivacyReport"), "\(file.lastPathComponent) imports PrivacyReport")
    }
    // the command line talks to the importer, not the parser
    for file in swiftFiles(in: "TattleCLI") {
        #expect(!imports(file).contains("PrivacyReport"), "\(file.lastPathComponent) imports PrivacyReport")
    }
}
