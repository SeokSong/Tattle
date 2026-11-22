import Foundation
import Testing

@testable import Capture

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let me = SudoUserFixture.current

private enum SudoUserFixture {
    static var current: FileOwnership.SudoUser {
        FileOwnership.SudoUser(uid: getuid(), gid: getgid(), home: NSHomeDirectory())
    }
}

@Test func sudoUserNeedsRootAndAllVariables() {
    let full = ["SUDO_UID": "501", "SUDO_GID": "20", "SUDO_USER": NSUserName()]
    let user = FileOwnership.sudoUser(environment: full, effectiveUID: 0)
    #expect(user?.uid == 501)
    #expect(user?.gid == 20)
    #expect(user?.home.hasPrefix("/") == true)
    #expect(FileOwnership.sudoUser(environment: full, effectiveUID: 501) == nil)
    for missing in ["SUDO_UID", "SUDO_GID", "SUDO_USER"] {
        var env = full
        env[missing] = nil
        #expect(FileOwnership.sudoUser(environment: env, effectiveUID: 0) == nil)
    }
    var bad = full
    bad["SUDO_UID"] = "abc"
    #expect(FileOwnership.sudoUser(environment: bad, effectiveUID: 0) == nil)
    bad = full
    bad["SUDO_USER"] = "no-such-user-\(UUID().uuidString.prefix(8))"
    #expect(FileOwnership.sudoUser(environment: bad, effectiveUID: 0) == nil)
}

@Test func expandTildeOnlyLeading() {
    #expect(FileOwnership.expandTilde("~/a/b", home: "/Users/x") == "/Users/x/a/b")
    #expect(FileOwnership.expandTilde("a/~/b", home: "/Users/x") == "a/~/b")
    #expect(FileOwnership.expandTilde("~other/x", home: "/Users/x") == "~other/x")
}

@Test func giveBackToSelfSucceeds() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("f").path
    FileManager.default.createFile(atPath: file, contents: nil)
    let failed = FileOwnership.giveBack([file, dir.appendingPathComponent("missing").path], to: me)
    #expect(failed.isEmpty)
}

@Test func giveBackReportsFailure() throws {
    guard geteuid() != 0 else { return }
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("f").path
    FileManager.default.createFile(atPath: file, contents: nil)
    let root = FileOwnership.SudoUser(uid: 0, gid: 0, home: "/var/root")
    #expect(FileOwnership.giveBack([file], to: root) == [file])
}

@Test func giveBackCallsChownWithUserIds() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("f").path
    FileManager.default.createFile(atPath: file, contents: nil)
    nonisolated(unsafe) var seen: [(String, uid_t, gid_t)] = []
    let user = FileOwnership.SudoUser(uid: 501, gid: 20, home: "/Users/x")
    let failed = FileOwnership.giveBack([file], to: user, chown: { seen.append(($0, $1, $2)); return 0 })
    #expect(failed.isEmpty)
    #expect(seen.count == 1 && seen[0].0 == file && seen[0].1 == 501 && seen[0].2 == 20)
}

@Test func openForWritingRefusesSymlink() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("target")
    try Data("keep".utf8).write(to: target)
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: FileOwnership.OpenError.self) { try FileOwnership.openForWriting(path: link.path) }
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
}

@Test func openForWritingRefusesExisting() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("d.pcapng").path
    let handle = try FileOwnership.openForWriting(path: path)
    try handle.close()
    #expect(throws: FileOwnership.OpenError.self) { try FileOwnership.openForWriting(path: path) }
    let mode = (try FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func missingDirectoriesListsOnlyNewOnes() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let deep = dir.appendingPathComponent("a/b/f.sqlite").path
    #expect(FileOwnership.missingDirectories(of: deep) == [dir.path + "/a", dir.path + "/a/b"])
    #expect(FileOwnership.missingDirectories(of: dir.appendingPathComponent("f").path).isEmpty)
}

@Test func gitWorkTreeIsFoundFromAnyDepth() throws {
    let outside = try tempDir()
    defer { try? FileManager.default.removeItem(at: outside) }
    #expect(FileOwnership.gitWorkTreeRoot(containing: outside.appendingPathComponent("a.txt").path) == nil)

    let repo = try tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let deep = repo.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    let root = repo.resolvingSymlinksInPath().path
    // a new file, a file in a folder that does not exist yet, and an existing file
    #expect(FileOwnership.gitWorkTreeRoot(containing: deep.appendingPathComponent("new.txt").path) == root)
    #expect(FileOwnership.gitWorkTreeRoot(containing: repo.appendingPathComponent("x/y/z.txt").path) == root)
    #expect(FileOwnership.gitWorkTreeRoot(containing: repo.appendingPathComponent(".git/config").path) == root)
    // a linked work tree has a .git file, not a folder
    let linked = try tempDir()
    defer { try? FileManager.default.removeItem(at: linked) }
    try Data("gitdir: elsewhere\n".utf8).write(to: linked.appendingPathComponent(".git"))
    #expect(FileOwnership.gitWorkTreeRoot(containing: linked.appendingPathComponent("f.txt").path) != nil)
    // a symlink into the repo is resolved
    let link = outside.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: deep)
    #expect(FileOwnership.gitWorkTreeRoot(containing: link.appendingPathComponent("f.txt").path) == root)
}

@Test func openForWritingCreatesTheFilePrivateFromTheStart() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("out.txt").path
    let handle = try FileOwnership.openForWriting(path: path)
    var info = stat()
    #expect(fstat(handle.fileDescriptor, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    try handle.close()
    // an existing file is refused, never overwritten
    #expect(throws: (any Error).self) { try FileOwnership.openForWriting(path: path) }
}
