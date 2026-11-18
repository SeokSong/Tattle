// the kernel cuts process names to 16 characters, so PKTAP never gives a longer one.
// raw names stay in stored data; display names are derived when a report or screen groups rows.
public enum ProcessNames {
    public static let maxLength = 16

    /// the form the kernel would report for a full name
    public static func cut(_ s: String) -> String {
        String(s.prefix(maxLength))
    }

    /// true when raw is the full name, or the full name as the kernel cuts it. never a prefix match
    public static func matches(_ raw: String, full: String) -> Bool {
        raw == full || raw == cut(full)
    }

    /// readable name for a raw (cut) process name; unknown names come back unchanged
    public static func displayName(_ raw: String) -> String {
        displayNames[raw] ?? raw
    }
}

/// keyed by the raw (cut) name. extend here from real top names
let displayNames: [String: String] = [
    "appstorecomponen": "App Store (component)",
]
