import Foundation
import Testing

// a test file sits at Tests/SummaryTests/, so the repo root is two levels up
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func swiftFiles(in folder: String) -> [URL] {
    let dir = root.appendingPathComponent("Sources/" + folder)
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func imports(_ file: URL, _ module: String) -> Bool {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
    return text.split(separator: "\n").contains {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return line == "import " + module || line.hasPrefix("@testable import " + module)
    }
}

@Test func layeringHolds() {
    // the packet path and storage never see company labels
    for folder in ["Pipeline", "Flows", "PacketDecoder", "PCAPNG", "Domains", "Storage", "Attribution", "Report", "Capture"] {
        let files = swiftFiles(in: folder)
        #expect(!files.isEmpty, "no files found in \(folder)")
        for file in files {
            #expect(!imports(file, "Companies"), "\(file.lastPathComponent) imports Companies")
            #expect(!imports(file, "Summary"), "\(file.lastPathComponent) imports Summary")
        }
    }
    // the summary side reads flows and names, never storage or the capture path
    let summary = swiftFiles(in: "Summary")
    #expect(!summary.isEmpty)
    for file in summary {
        for module in ["Report", "Storage", "TattleApp", "Capture", "Pipeline"] {
            #expect(!imports(file, module), "\(file.lastPathComponent) imports \(module)")
        }
    }
}
