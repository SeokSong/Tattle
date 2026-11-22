import Foundation

/// helpers so files made by `sudo tattle capture` belong to the invoking user
public enum FileOwnership {
    public struct SudoUser: Equatable, Sendable {
        public let uid: uid_t
        public let gid: gid_t
        public let home: String

        public init(uid: uid_t, gid: gid_t, home: String) {
            self.uid = uid
            self.gid = gid
            self.home = home
        }
    }

    public enum OpenError: Error, Equatable {
        case failed(errno: Int32)
    }

    /// nil unless running as root with valid SUDO_UID, SUDO_GID and SUDO_USER. the home comes from the
    /// password database, never from HOME
    public static func sudoUser(
        environment: [String: String], effectiveUID: uid_t = geteuid()
    ) -> SudoUser? {
        guard effectiveUID == 0,
            let uidText = environment["SUDO_UID"], let uid = uid_t(uidText),
            let gidText = environment["SUDO_GID"], let gid = gid_t(gidText),
            let name = environment["SUDO_USER"], !name.isEmpty,
            let entry = getpwnam(name), let dir = entry.pointee.pw_dir
        else { return nil }
        let home = String(cString: dir)
        guard home.hasPrefix("/") else { return nil }
        return SudoUser(uid: uid, gid: gid, home: home)
    }

    /// expands a leading `~/` (or a lone `~`) only; `~other/x` and inner tildes are left alone
    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return base + String(path.dropFirst(1))
    }

    /// lchown each existing path to the user; returns the paths that failed. missing paths are skipped
    public static func giveBack(_ paths: [String], to user: SudoUser) -> [String] {
        giveBack(paths, to: user, chown: { lchown($0, $1, $2) })
    }

    /// same, with an injectable chown (returns 0 on success)
    public static func giveBack(
        _ paths: [String], to user: SudoUser, chown: (String, uid_t, gid_t) -> Int32
    ) -> [String] {
        var failed: [String] = []
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if chown(path, user.uid, user.gid) != 0 { failed.append(path) }
        }
        return failed
    }

    /// creates a new file, refusing an existing path or a symlink
    public static func openForWriting(path: String, mode: mode_t = 0o600) throws -> FileHandle {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw OpenError.failed(errno: errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// the nearest ancestor folder that holds a `.git` entry (a folder, or a file for a linked work tree),
    /// found by walking up from the path with symlinks resolved; nil when the path is outside any work tree.
    /// the path need not exist: the nearest existing ancestor is used
    public static func gitWorkTreeRoot(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) { url.deleteLastPathComponent() }
        url = url.resolvingSymlinksInPath()
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            if url.path == "/" { return nil }
            url.deleteLastPathComponent()
        }
    }

    /// the ancestors of a path (nearest last) that do not exist yet
    public static func missingDirectories(of path: String) -> [String] {
        var missing: [String] = []
        var dir = (path as NSString).deletingLastPathComponent
        var info = stat()
        while !dir.isEmpty, dir != "/", lstat(dir, &info) != 0 {
            missing.append(dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        return missing.reversed()
    }
}
