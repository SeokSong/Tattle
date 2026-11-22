import Foundation

/// what one parse found. counts and record kind names only: never an app id, a domain or an owner
public struct ImportResult: Sendable, Equatable {
    /// sha-256 of every byte of the file, lower-case hex. the same file always gives the same value
    public let fileSHA256: String
    public let bytesRead: Int
    /// non-empty lines read (blank lines are ignored and not counted)
    public let linesRead: Int
    /// network records handed to the sink
    public let kept: Int
    /// `access` records seen and dropped (OD6: not imported, contents never kept)
    public let skippedAccess: Int
    /// records of any other type, skipped
    public let unknownTypes: Int
    /// the distinct names of those types (record kinds, not user data), at most `maxUnknownTypeNames`,
    /// each at most 40 ascii characters; anything else is listed as "(unreadable)"
    public let unknownTypeNames: [String]
    /// lines that were not valid records, counted and skipped
    public let malformed: Int
    /// earliest `firstTimeStamp` and latest `timeStamp` of the kept network records; nil when none
    public let periodStart: Date?
    public let periodEnd: Date?
    /// the last line had no line end and was cut off in the middle of a record: dropped, not counted as malformed
    public let truncatedLastLine: Bool
    /// the `v<number>` from the file name, when the source has a name and it follows the pattern
    public let formatVersion: Int?
    /// true when the file name does not carry the supported format version (see `ReportParser.supportedFormatVersion`)
    public let unexpectedFormatVersion: Bool

    public static let maxUnknownTypeNames = 16

    /// no network record at all: nothing to store (md/STORAGE.md: an import needs at least one)
    public var hasNoNetworkRecords: Bool { kept == 0 }
}

public struct ImportLimits: Sendable, Equatable {
    public var maxFileBytes: Int
    public var maxLineBytes: Int
    /// malformed lines over this share of the lines read reject the whole import
    public var maxMalformedShare: Double
    /// lines read; stops a file of millions of tiny lines
    public var maxRecords: Int

    public init(maxFileBytes: Int, maxLineBytes: Int, maxMalformedShare: Double, maxRecords: Int) {
        self.maxFileBytes = maxFileBytes
        self.maxLineBytes = maxLineBytes
        self.maxMalformedShare = maxMalformedShare
        self.maxRecords = maxRecords
    }

    /// a real export (7 days at most) is a few MB, with lines of a few hundred bytes
    /// (md/PRIVACY_REPORT.md): the file cap is the 50 MB floor, the line cap 16 KiB, the line count cap 250,000
    public static let standard = ImportLimits(
        maxFileBytes: 50 * 1024 * 1024, maxLineBytes: 16 * 1024, maxMalformedShare: 0.01, maxRecords: 250_000)
}

/// why an import was refused. the descriptions hold numbers from the limits only, never file content
public enum ImportError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge(limit: Int)
    case lineTooLong(limit: Int)
    case tooManyMalformed(malformed: Int, lines: Int)
    case recordCap(limit: Int)
    case unreadable

    public var description: String {
        switch self {
        case .fileTooLarge(let limit): return "the file is larger than \(limit) bytes"
        case .lineTooLong(let limit): return "a line is longer than \(limit) bytes"
        case .tooManyMalformed(let malformed, let lines):
            return "\(malformed) of \(lines) lines are not valid records"
        case .recordCap(let limit): return "the file has more than \(limit) lines"
        case .unreadable: return "the file could not be read"
        }
    }
}

extension ImportError: LocalizedError {
    public var errorDescription: String? { description }
}
