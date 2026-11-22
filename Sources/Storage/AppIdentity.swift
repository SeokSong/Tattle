import Foundation

/// the one place that names the product. user-facing strings use `name`; the support folder is
/// ~/Library/Application Support/<supportFolder>. the project was called Watch before 2026-11-21.
public enum AppIdentity {
    public static let name = "Tattle"
    public static let supportFolder = "Tattle"
    static let legacySupportFolder = "Watch"

    /// the user's Application Support directory
    public static func defaultBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
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
