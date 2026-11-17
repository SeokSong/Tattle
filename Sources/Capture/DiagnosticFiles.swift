import Foundation

/// raw-packet diagnostic files: one private folder, deleted after a day or by "Delete all"
public enum DiagnosticFiles {
    /// files older than this are removed at app start
    public static let maxAge: TimeInterval = 86_400

    public enum CreateError: Error, Equatable {
        case directory(errno: Int32)
        case file(errno: Int32)
    }

    public static func directory(under base: URL) -> URL {
        base.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// creates the directory (0700) and a new `diagnostic-<time>.pcapng` (0600). when the name is taken
    /// (same second) a counter is added: `-2`, `-3`, ... an existing file is never overwritten
    public static func create(in directory: URL, now: Date) throws -> FileHandle {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw CreateError.directory(errno: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        for attempt in 1...1000 {
            let name = attempt == 1 ? "diagnostic-\(stamp).pcapng" : "diagnostic-\(stamp)-\(attempt).pcapng"
            do {
                return try FileOwnership.openForWriting(path: directory.appendingPathComponent(name).path)
            } catch FileOwnership.OpenError.failed(let code) where code == EEXIST {
                continue
            } catch FileOwnership.OpenError.failed(let code) {
                throw CreateError.file(errno: code)
            }
        }
        throw CreateError.file(errno: EEXIST)
    }

    /// removes diagnostic files whose age is more than `seconds` (a file exactly that old stays). only
    /// regular files named `diagnostic-*.pcapng` are considered. a symlink with such a name is removed
    /// itself, whatever its age, and never followed. returns the number removed
    @discardableResult
    public static func purge(in directory: URL, olderThan seconds: TimeInterval = maxAge, now: Date) -> Int {
        remove(in: directory) { info in
            guard info.st_mode & S_IFMT == S_IFREG else { return true }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            return now.timeIntervalSince1970 - modified > seconds
        }
    }

    /// removes every diagnostic file (same name rules). returns the number removed
    @discardableResult
    public static func purgeAll(in directory: URL) -> Int {
        remove(in: directory) { _ in true }
    }

    private static func remove(in directory: URL, where shouldRemove: (stat) -> Bool) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix("diagnostic-") && name.hasSuffix(".pcapng") {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { continue }
            if shouldRemove(info), unlink(path) == 0 { removed += 1 }
        }
        return removed
    }
}
