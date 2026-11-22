import Foundation
import PrivacyReport
import Storage

// imports an App Privacy Report export: parse in a stream, combine, map to storage rows, save once.
// this is the only file in Pipeline that knows the parser; the packet path never imports it.
// no copy of the file is made, no path is kept, and nothing here puts a path or a value in a message.

/// what the store needs from the importer's side. lets tests fail the save on demand
public protocol ReportImportStoring: AnyObject {
    @discardableResult
    func saveImport(_ row: ReportImportRow, contacts: [ReportContactRow]) throws -> SaveImportOutcome
}

extension Store: ReportImportStoring {}

/// an import that did not happen, in words. counts only, never a path or a value
public struct ReportImportFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// what one import did: the parser's counts and what the store did with them
public struct ReportImportSummary: Sendable, Equatable {
    public let result: ImportResult
    public let outcome: SaveImportOutcome

    /// OD17: the file name did not carry the supported format version; the file was imported anyway
    public var newerFormatWarning: Bool { result.unexpectedFormatVersion }

    public var stored: Bool { if case .stored = outcome { return true } else { return false } }

    /// plain-language lines for the command line and the app: counts and dates only
    public var lines: [String] {
        var out: [String] = []
        switch outcome {
        case .stored(let replaced):
            out.append("Imported \(result.kept) network records.")
            if replaced > 0 { out.append("Replaced \(replaced) older \(replaced == 1 ? "import" : "imports") covering the same period.") }
        case .duplicate:
            out.append("This report was already imported. Nothing was changed.")
        case .empty:
            out.append("This report has no network records. Nothing was imported.")
        case .olderThanStored(let end):
            out.append(
                "A newer report that ends on \(Self.day(end)) is already imported and covers this period. "
                    + "This older report was not imported.")
        }
        if newerFormatWarning {
            let v = result.formatVersion.map { "version \($0)" } ?? "an unknown version"
            out.append(
                "Warning: this report is \(v), but Tattle reads version \(ReportParser.supportedFormatVersion). "
                    + "It was imported as is, and some fields may be missing.")
        }
        out.append("Lines read: \(result.linesRead)")
        out.append("Network records kept: \(result.kept)")
        out.append("Access records skipped: \(result.skippedAccess)")
        out.append("Other records skipped: \(result.unknownTypes)")
        out.append("Lines that were not valid records: \(result.malformed)")
        if result.truncatedLastLine { out.append("The last line was cut off and was ignored.") }
        if let s = result.periodStart, let e = result.periodEnd {
            out.append("Period: \(Self.day(s)) to \(Self.day(e))")
        }
        return out
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + " UTC"
    }
}

public enum ReportImporter {
    /// imports the file at `file`, opened read-only where the user chose it. a rejected file (limits) or a failed
    /// save stores nothing and throws a `ReportImportFailure`
    public static func run(
        file: URL, store: any ReportImportStoring, limits: ImportLimits = .standard, now: Date = Date()
    ) throws -> ReportImportSummary {
        let source: FileLineSource
        do { source = try FileLineSource(url: file) } catch { throw failure(error) }
        defer { source.close() }
        return try run(source: source, store: store, limits: limits, now: now)
    }

    /// the same import from any line source (tests count reads with one)
    public static func run(
        source: any LineSource, store: any ReportImportStoring, limits: ImportLimits = .standard, now: Date = Date()
    ) throws -> ReportImportSummary {
        let parsed: (contacts: [ReportContact], result: ImportResult)
        do { parsed = try ReportParser.parseCombined(source: source, limits: limits) } catch { throw failure(error) }
        let result = parsed.result
        guard let start = result.periodStart, let end = result.periodEnd, !parsed.contacts.isEmpty else {
            return ReportImportSummary(result: result, outcome: .empty)
        }
        let row = ReportImportRow(
            fileSHA256: result.fileSHA256, periodStart: start, periodEnd: end, importedAt: now,
            linesRead: result.linesRead, recordsKept: result.kept, malformed: result.malformed,
            unknownTypes: result.unknownTypes, formatVersion: result.formatVersion)
        let contacts = parsed.contacts.map {
            ReportContactRow(
                importId: row.id, appId: $0.appID, domain: $0.domain, domainOwner: $0.domainOwner, hits: $0.hits,
                firstSeen: $0.firstSeen, lastSeen: $0.lastSeen, initiatedType: $0.initiatedType,
                domainType: $0.domainType, domainClassification: $0.domainClassification)
        }
        let outcome: SaveImportOutcome
        do { outcome = try store.saveImport(row, contacts: contacts) } catch {
            throw ReportImportFailure(message: "The report could not be saved. Nothing was imported.")
        }
        return ReportImportSummary(result: result, outcome: outcome)
    }

    /// the distinct app ids of the report at `file`, sorted, without storing anything. for the join rate
    /// (`import-report --join-rate`); the ids are the report's own text and stay local
    public static func appIds(file: URL, limits: ImportLimits = .standard) throws -> [String] {
        let source: FileLineSource
        do { source = try FileLineSource(url: file) } catch { throw failure(error) }
        defer { source.close() }
        do {
            return Set(try ReportParser.parseCombined(source: source, limits: limits).contacts.map(\.appID)).sorted()
        } catch { throw failure(error) }
    }

    private static func failure(_ error: Error) -> ReportImportFailure {
        guard let e = error as? ImportError else {
            return ReportImportFailure(message: "The report could not be read. Nothing was imported.")
        }
        switch e {
        case .fileTooLarge(let limit):
            return ReportImportFailure(message: "The file is larger than the limit of \(limit) bytes. Nothing was imported.")
        case .lineTooLong(let limit):
            return ReportImportFailure(message: "The file has a line longer than the limit of \(limit) bytes. Nothing was imported.")
        case .tooManyMalformed(let malformed, let lines):
            return ReportImportFailure(
                message: "\(malformed) of \(lines) lines are not valid records, which is too many. Nothing was imported.")
        case .recordCap(let limit):
            return ReportImportFailure(message: "The file has more than \(limit) lines. Nothing was imported.")
        case .unreadable:
            return ReportImportFailure(message: "The report could not be read. Nothing was imported.")
        }
    }
}
