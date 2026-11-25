import Foundation

/// the one place that names the product. user-facing strings use `name`; the support folder is
/// ~/Library/Application Support/<supportFolder>. the project was called Watch before 2026-11-21.
public enum AppIdentity {
    public static let name = "Tattle"
    public static let supportFolder = "Tattle"
    static let legacySupportFolder = "Watch"

    /// the environment variable that points the whole data folder (database, run folders, diagnostics)
    /// somewhere else, so the app can be launched for a check or a screenshot without touching the real data
    public static let supportBaseVariable = "TATTLE_SUPPORT_BASE"

    /// the user's Application Support directory, or `TATTLE_SUPPORT_BASE` when it names an existing folder that
    /// this user owns and no one else can write to. the capture's run folders live under it, so a shared folder
    /// such as /tmp itself is refused and the real folder is used (review of PR #10)
    public static func defaultBase(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[supportBaseVariable], override.hasPrefix("/"), isPrivateFolder(override) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// base/Tattle. on first use, moves a real base/Watch folder there (same volume, so a rename).
    /// never overwrites: if anything already sits at the new path, or the old path is a symlink or
    /// a plain file, nothing moves. a failed move is ignored and the new folder is simply created later.
    public static func supportDirectory(base: URL? = nil) -> URL {
        let base = base ?? defaultBase()
        let new = base.appendingPathComponent(supportFolder, isDirectory: true)
        let old = base.appendingPathComponent(legacySupportFolder, isDirectory: true)
        if !exists(new.path), isRealDirectory(old.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
        return new
    }

    /// a real directory (not a symlink) owned by this user, with no group or other write permission
    static func isPrivateFolder(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return st.st_uid == getuid() && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }

    // lstat, so a symlink (even a dangling one) counts as present and is never followed
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
