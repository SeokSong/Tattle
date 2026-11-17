import Foundation
import Testing

@testable import Capture

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)

@discardableResult
private func make(_ name: String, in dir: URL, age: TimeInterval) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Test func purgeRemovesOnlyOldDiagnosticFiles() throws {
    let dir = try tempDir()
    let a = try make("diagnostic-a.pcapng", in: dir, age: 25 * 3600)
    let b = try make("diagnostic-b.pcapng", in: dir, age: 3600)
    let notes = try make("notes.txt", in: dir, age: 25 * 3600)
    #expect(DiagnosticFiles.purge(in: dir, olderThan: DiagnosticFiles.maxAge, now: now) == 1)
    #expect(!exists(a))
    #expect(exists(b))
    #expect(exists(notes))
}

@Test func purgeBoundaryKeepsExactlyOneDay() throws {
    let dir = try tempDir()
    let exact = try make("diagnostic-exact.pcapng", in: dir, age: 86_400)
    let over = try make("diagnostic-over.pcapng", in: dir, age: 86_401)
    #expect(DiagnosticFiles.purge(in: dir, olderThan: DiagnosticFiles.maxAge, now: now) == 1)
    #expect(exists(exact))
    #expect(!exists(over))
}

@Test func purgeAllRemovesAllDiagnosticFiles() throws {
    let dir = try tempDir()
    let a = try make("diagnostic-a.pcapng", in: dir, age: 10)
    let b = try make("diagnostic-b.pcapng", in: dir, age: 100_000)
    let other = try make("other.txt", in: dir, age: 10)
    #expect(DiagnosticFiles.purgeAll(in: dir) == 2)
    #expect(!exists(a) && !exists(b))
    #expect(exists(other))
}

@Test func purgeDoesNotFollowSymlinks() throws {
    let dir = try tempDir()
    let outside = try tempDir()
    let target = try make("target.txt", in: outside, age: 10)
    let link = dir.appendingPathComponent("diagnostic-x.pcapng")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(DiagnosticFiles.purge(in: dir, olderThan: DiagnosticFiles.maxAge, now: now) == 1)
    #expect(lstatFails(link))
    #expect(exists(target))

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(DiagnosticFiles.purgeAll(in: dir) == 1)
    #expect(exists(target))
}

private func lstatFails(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) != 0
}

@Test func createMakesPrivateFile() throws {
    let base = try tempDir()
    let dir = DiagnosticFiles.directory(under: base)
    #expect(dir.lastPathComponent == "diagnostics")
    let first = try DiagnosticFiles.create(in: dir, now: now)
    let second = try DiagnosticFiles.create(in: dir, now: now)
    try first.close()
    try second.close()

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1) & 0o777
    }
    #expect(try mode(dir) == 0o700)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names.count == 2)  // the second create in the same second gets a counter
    for name in names {
        #expect(name.hasPrefix("diagnostic-") && name.hasSuffix(".pcapng"))
        #expect(!name.contains(":"))
        #expect(try mode(dir.appendingPathComponent(name)) == 0o600)
    }
    #expect(names.contains { $0.hasSuffix("-2.pcapng") })
}
