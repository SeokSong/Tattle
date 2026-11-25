import Foundation
import Testing

@testable import Storage

private func tempBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("tattle-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func makeFolder(_ url: URL, marker: String) throws {
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
}

private func marker(_ dir: URL) -> String? {
    (try? Data(contentsOf: dir.appendingPathComponent("marker"))).flatMap { String(data: $0, encoding: .utf8) }
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

@Test func identityNames() {
    #expect(AppIdentity.name == "Tattle")
    #expect(AppIdentity.supportFolder == "Tattle")
    #expect(AppIdentity.legacySupportFolder == "Watch")
}

@Test func legacyFolderMovesToNewName() throws {
    let base = try tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let old = base.appendingPathComponent("Watch", isDirectory: true)
    try makeFolder(old, marker: "old")
    let dir = AppIdentity.supportDirectory(base: base)
    #expect(dir.lastPathComponent == "Tattle")
    #expect(marker(dir) == "old")
    #expect(mode(dir) == 0o700)
    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test func bothExistLeavesBoth() throws {
    let base = try tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let old = base.appendingPathComponent("Watch", isDirectory: true)
    let new = base.appendingPathComponent("Tattle", isDirectory: true)
    try makeFolder(old, marker: "old")
    try makeFolder(new, marker: "new")
    let dir = AppIdentity.supportDirectory(base: base)
    #expect(dir.path == new.path)
    #expect(marker(new) == "new")
    #expect(marker(old) == "old")
}

@Test func symlinkedLegacyFolderIsNotFollowedOrMoved() throws {
    let base = try tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("elsewhere", isDirectory: true)
    try makeFolder(target, marker: "target")
    let old = base.appendingPathComponent("Watch")
    try FileManager.default.createSymbolicLink(at: old, withDestinationURL: target)
    let dir = AppIdentity.supportDirectory(base: base)
    #expect(dir.lastPathComponent == "Tattle")
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: old.path)) == target.path)
    #expect(marker(target) == "target")
}

@Test func neitherExistsCreatesNothing() throws {
    let base = try tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let dir = AppIdentity.supportDirectory(base: base)
    #expect(dir.lastPathComponent == "Tattle")
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func storeDefaultPathMigratesLegacyDatabase() throws {
    let base = try tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let old = base.appendingPathComponent("Watch", isDirectory: true)
    try makeFolder(old, marker: "old")
    let path = Store.defaultPath(base: base)
    #expect(path.deletingLastPathComponent().lastPathComponent == "Tattle")
    #expect(marker(path.deletingLastPathComponent()) == "old")
}

@Test func supportBaseCanBePointedElsewhere() throws {
    // TATTLE_SUPPORT_BASE moves the whole data folder, so a launch for a check never touches the real data.
    // only a folder this user owns and no one else can write to is accepted (review of PR #10)
    let own = FileManager.default.temporaryDirectory.appendingPathComponent("tattle-base-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: own) }
    #expect(AppIdentity.defaultBase(environment: [AppIdentity.supportBaseVariable: own.path]).path == own.path)
    // a shared folder anyone can write to, a missing folder and a relative path all fall back to the real folder
    for refused in ["/tmp", own.path + "-missing", "relative"] {
        #expect(AppIdentity.defaultBase(environment: [AppIdentity.supportBaseVariable: refused]).path.hasSuffix("Application Support"), "\(refused)")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: own.path)
    #expect(AppIdentity.defaultBase(environment: [AppIdentity.supportBaseVariable: own.path]).path.hasSuffix("Application Support"))
    #expect(AppIdentity.defaultBase(environment: [:]).path.hasSuffix("Application Support"))
}
