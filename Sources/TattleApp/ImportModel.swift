import Foundation
import Pipeline
import PrivacyReport
import Storage

// the state behind the Import screen: pure and testable, no views. the import itself runs off the main thread
// (a detached task with its own store connection). no message here holds a file path, an app id or a domain:
// only counts, dates and fixed sentences.

/// what the setup text and fixed notices say. the iPhone path is from memory of iOS and is
/// to verify on the owner's phone (owner step, see the plan's O1/O3)
enum ImportText {
    static let setup =
        "On your iPhone: Settings > Privacy & Security > App Privacy Report > turn on App Privacy Report. "
        + "Later, Save App Activity at the bottom of that screen, and send the file to this Mac."
    static let originalFileNotice = "\(AppIdentity.name) cannot delete the file you saved. Delete it yourself when you are done."
    static let accessNotice =
        "Only network activity is imported. Access records (camera, location and similar) were not kept."
    static func retention(days: Int) -> String {
        "Imported reports follow your retention setting (\(days == 1 ? "1 day" : "\(days) days"))."
    }
    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

/// one shown result of an import
struct ImportCard: Equatable {
    enum Kind: Equatable { case stored, duplicate, olderRefused, empty }
    var kind: Kind
    var headline: String
    var details: [String]
    /// the newer-format warning (OD17), shown apart from the details
    var warning: String?
}

/// one stored import, as the list shows it
struct ImportItem: Identifiable, Equatable {
    var id: String { sha256 }
    var sha256: String
    var periodStart: Date
    var periodEnd: Date
    var recordsKept: Int
    var skippedLines: Int
}

enum ImportState: Equatable {
    case idle
    case running
    case done(ImportCard)
    /// the file was rejected or could not be saved: a plain sentence, no values
    case failed(String)
}

struct OpenFailure: Error {}

/// what a runner hands back: the importer's summary and the distinct counts of what was stored
struct ImportRun: Sendable {
    var summary: ReportImportSummary
    var apps: Int
    var domains: Int
}

@MainActor
final class ImportModel: ObservableObject {
    /// does the import work; called on a background thread, never the main one
    typealias Runner = @Sendable (URL) throws -> ImportRun

    @Published private(set) var state: ImportState = .idle
    @Published private(set) var items: [ImportItem] = []
    @Published var listError: String?

    /// set by the app model: true while a capture is starting, running or saving. an import then waits
    @Published var captureBusy = false

    private let storePath: URL
    private let runner: Runner
    let timeZone: TimeZone
    let locale: Locale

    init(storePath: URL, timeZone: TimeZone = .current, locale: Locale = .current, runner: Runner? = nil) {
        self.storePath = storePath
        self.timeZone = timeZone
        self.locale = locale
        self.runner = runner ?? { try Self.defaultRun(file: $0, storePath: storePath) }
        refresh()
    }

    var isRunning: Bool { state == .running }

    /// why the Import action is off, or nil when it is on
    var importUnavailableReason: String? {
        captureBusy ? "Import is unavailable while a capture is running." : nil
    }

    /// why Delete all data is off, or nil when it is on. an import task that is in flight would store its
    /// result after the delete, so the two never overlap: this is the one place that enforces it
    func deleteAllUnavailableReason(captureBusy: Bool) -> String? {
        if captureBusy { return "Delete all data is unavailable while a capture is running." }
        if isRunning { return "Wait for the import to finish." }
        return nil
    }

    // MARK: import

    /// starts an import from the UI; a second start while one runs does nothing
    func start(file: URL) {
        guard begin() else { return }
        Task { await perform(file) }
    }

    /// the same import, awaitable (tests)
    func runImport(file: URL) async {
        guard begin() else { return }
        await perform(file)
    }

    private func begin() -> Bool {
        guard !isRunning, importUnavailableReason == nil else { return false }
        state = .running
        return true
    }

    private func perform(_ file: URL) async {
        let runner = self.runner
        // the work runs in a detached task: nothing here holds the main actor while the file is read
        let result = await Task.detached { Result { try runner(file) } }.value
        switch result {
        case .success(let run): state = .done(card(for: run))
        case .failure(let error): state = .failed(Self.sentence(for: error))
        }
        refresh()
    }

    /// resets a finished screen to the start
    func dismissResult() { if !isRunning { state = .idle } }

    // MARK: stored imports

    func refresh() {
        do {
            let store = try Store(path: storePath)
            items = try store.imports().map {
                ImportItem(
                    sha256: $0.fileSHA256, periodStart: $0.periodStart, periodEnd: $0.periodEnd,
                    recordsKept: $0.recordsKept, skippedLines: $0.malformed)
            }
            listError = nil
        } catch {
            listError = "The list of imported reports could not be read."
        }
    }

    func delete(sha256: String) {
        do {
            try Store(path: storePath).deleteImport(sha256: sha256)
        } catch {
            listError = "The report could not be deleted."
            return
        }
        refresh()
    }

    // MARK: text

    /// "Nov 18 – Nov 21" in the user's time zone and locale; one day when both ends fall on it
    func periodText(start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        let a = f.string(from: start), b = f.string(from: end)
        return a == b ? a : "\(a) – \(b)"
    }

    func dayText(_ date: Date) -> String {
        periodText(start: date, end: date)
    }

    func card(for run: ImportRun) -> ImportCard {
        let summary = run.summary
        let result = summary.result
        var warning: String?
        if summary.newerFormatWarning {
            let version = result.formatVersion.map { "version \($0)" } ?? "an unknown version"
            warning =
                "This report is \(version), but \(AppIdentity.name) reads version \(ReportParser.supportedFormatVersion). "
                + "It was imported as it is, and some fields may be missing."
        }
        var details: [String] = []
        let kind: ImportCard.Kind
        let headline: String
        switch summary.outcome {
        case .stored(let replaced):
            kind = .stored
            headline = "Imported \(ImportText.count(result.kept, "network record", "network records"))."
            if let s = result.periodStart, let e = result.periodEnd { details.append("Period: \(periodText(start: s, end: e))") }
            details.append("Read: \(ImportText.count(run.apps, "app", "apps")) and \(ImportText.count(run.domains, "domain", "domains")).")
            if replaced > 0 {
                details.append(
                    "Replaced \(replaced) older \(replaced == 1 ? "import" : "imports") covering the same period.")
            }
        case .duplicate:
            kind = .duplicate
            headline = "This report was already imported. Nothing was changed."
        case .empty:
            kind = .empty
            headline = "This report has no network records. Nothing was imported."
        case .olderThanStored(let end):
            kind = .olderRefused
            headline =
                "A newer report that ends on \(dayText(end)) is already imported and covers this period. "
                + "This older report was not imported."
        }
        if result.malformed > 0 {
            details.append("\(ImportText.count(result.malformed, "line", "lines")) could not be read.")
        }
        if result.unknownTypes > 0 {
            details.append("\(ImportText.count(result.unknownTypes, "record", "records")) of other kinds were skipped.")
        }
        if result.truncatedLastLine { details.append("The last line was cut off and was ignored.") }
        details.append(ImportText.accessNotice)
        return ImportCard(kind: kind, headline: headline, details: details, warning: warning)
    }

    /// a plain sentence for any failure; the importer's own messages carry counts only
    nonisolated static func sentence(for error: Error) -> String {
        if let failure = error as? ReportImportFailure { return failure.message }
        if error is OpenFailure { return "The database could not be opened. Nothing was imported." }
        return "The report could not be imported. Nothing was imported."
    }

    // MARK: the real run

    /// runs on a background thread with its own store connection, then counts what was stored
    nonisolated static func defaultRun(file: URL, storePath: URL) throws -> ImportRun {
        let store: Store
        do { store = try Store(path: storePath) } catch {
            throw OpenFailure()
        }
        let summary = try ReportImporter.run(file: file, store: store)
        var apps = 0, domains = 0
        if summary.stored,
            let row = try? store.imports().first(where: { $0.fileSHA256 == summary.result.fileSHA256 }),
            let contacts = try? store.contacts(importId: row.id)
        {
            apps = Set(contacts.map(\.appId)).count
            domains = Set(contacts.map(\.domain)).count
        }
        return ImportRun(summary: summary, apps: apps, domains: domains)
    }
}
