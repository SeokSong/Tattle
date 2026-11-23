import Foundation
import Pipeline
import Storage
import Testing
import TestSupport

@testable import TattleApp

private typealias B = PrivacyReportBuilder

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tattle-app-import-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ lines: [String], in dir: URL, name: String = "App_Privacy_Report_v4_a.ndjson") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try B.file(lines).write(to: url)
    return url
}

private let utc = TimeZone(identifier: "UTC")!
private let us = Locale(identifier: "en_US")

@MainActor
private func model(_ dir: URL, zone: TimeZone = utc, runner: ImportModel.Runner? = nil) -> ImportModel {
    ImportModel(storePath: dir.appendingPathComponent("db.sqlite"), timeZone: zone, locale: us, runner: runner)
}

private func cardOf(_ state: ImportState) -> ImportCard? {
    if case .done(let card) = state { return card }
    return nil
}

private let sample = [
    B.network(app: "com.example.app1", domain: "example.com", last: B.stamp(18)),
    B.network(app: "com.example.app2", domain: "api.example.com", last: B.stamp(19)),
    B.network(app: "com.example.app2", domain: "cdn.example.net", last: B.stamp(21)),
] + (0..<120).map { _ in B.network(app: "com.example.app1", domain: "example.com", last: B.stamp(20)) } + [
    B.access(),
    B.other(type: "somethingNew"),
    "not a record",
]

@MainActor @Test func successStateShowsCounts() async throws {
    let dir = tempDir()
    let m = model(dir)
    try await m.runImport(file: write(sample, in: dir))
    let card = try #require(cardOf(m.state))
    #expect(card.kind == .stored)
    #expect(card.headline == "Imported 123 network records.")
    #expect(card.details.contains("Read: 2 apps and 3 domains."))
    #expect(card.details.contains("Period: Nov 18 – Nov 21"))
    #expect(card.details.contains("1 line could not be read."))
    #expect(card.details.contains("1 record of other kinds were skipped."))
    #expect(card.details.contains { $0.contains("Access records (camera, location and similar) were not kept") })
    #expect(card.warning == nil)
    #expect(m.items.count == 1)
    #expect(m.items[0].recordsKept == 123)
}

@MainActor @Test func datesUseTheLocalTimeZone() async throws {
    let dir = tempDir()
    // 22:00 at -08:00 is 06:00 the next day in UTC and 19:00 the same day in Samoa
    let lines = [B.network(first: B.stamp(18, hour: 22), last: B.stamp(18, hour: 23))]
    let file = try write(lines, in: dir)
    let utcModel = model(dir)
    await utcModel.runImport(file: file)
    #expect(cardOf(utcModel.state)?.details.contains("Period: Nov 19") == true)
    let samoa = model(dir, zone: TimeZone(identifier: "Pacific/Pago_Pago")!)
    #expect(samoa.periodText(start: utcModel.items[0].periodStart, end: utcModel.items[0].periodEnd) == "Nov 18")
}

@MainActor @Test func duplicateAndOlderAndEmptyAndNewerFormat() async throws {
    let dir = tempDir()
    let m = model(dir)
    let first = try write(sample, in: dir)
    await m.runImport(file: first)
    await m.runImport(file: first)
    #expect(cardOf(m.state)?.kind == .duplicate)
    #expect(cardOf(m.state)?.headline == "This report was already imported. Nothing was changed.")

    let older = try write([B.network(first: B.stamp(19), last: B.stamp(19))], in: dir, name: "App_Privacy_Report_v4_old.ndjson")
    await m.runImport(file: older)
    let refused = try #require(cardOf(m.state))
    #expect(refused.kind == .olderRefused)
    #expect(refused.headline.contains("ends on Nov 21"))
    #expect(m.items.count == 1)

    let empty = try write([B.access()], in: dir, name: "App_Privacy_Report_v4_empty.ndjson")
    await m.runImport(file: empty)
    #expect(cardOf(m.state)?.kind == .empty)

    let dir2 = tempDir()
    let m2 = model(dir2)
    await m2.runImport(file: try write(sample, in: dir2, name: "App_Privacy_Report_v9_x.ndjson"))
    let warned = try #require(cardOf(m2.state))
    #expect(warned.kind == .stored)
    #expect(warned.warning?.contains("version 9") == true)
    #expect(warned.warning?.contains("Watch") == false)
}

@MainActor @Test func rejectedStateShowsReasonNotValues() async throws {
    let dir = tempDir()
    let m = model(dir)
    let bad = (0..<50).map { _ in "secret-domain.example not json" }
    let file = try write(bad, in: dir, name: "secret-name-v4.ndjson")
    await m.runImport(file: file)
    guard case .failed(let message) = m.state else { Issue.record("expected failure"); return }
    #expect(message.hasSuffix("Nothing was imported."))
    for forbidden in ["secret", "example", dir.path, "com."] { #expect(!message.contains(forbidden)) }

    await m.runImport(file: dir.appendingPathComponent("missing-secret.ndjson"))
    guard case .failed(let missing) = m.state else { Issue.record("expected failure"); return }
    #expect(!missing.contains("secret") && !missing.contains(dir.path))
    #expect(m.items.isEmpty)
}

@Test func noticeAboutOriginalFileAlwaysShown() {
    #expect(ImportText.originalFileNotice == "Tattle cannot delete the file you saved. Delete it yourself when you are done.")
    #expect(
        ImportText.setup
            == "On your iPhone: Settings > Privacy & Security > App Privacy Report > turn on App Privacy Report. Later, Save App Activity at the bottom of that screen, and send the file to this Mac."
    )
    #expect(ImportText.retention(days: 7) == "Imported reports follow your retention setting (7 days).")
    #expect(ImportText.retention(days: 1) == "Imported reports follow your retention setting (1 day).")
    for text in [ImportText.setup, ImportText.originalFileNotice, ImportText.accessNotice] { #expect(!text.contains("Watch")) }
}

@MainActor @Test func deleteImportRemovesRows() async throws {
    let dir = tempDir()
    let m = model(dir)
    await m.runImport(file: try write(sample, in: dir))
    await m.runImport(file: try write([B.network(last: B.stamp(25))], in: dir, name: "App_Privacy_Report_v4_b.ndjson"))
    #expect(m.items.count == 2)
    m.delete(sha256: m.items[0].sha256)
    #expect(m.items.count == 1)
    let store = try Store(path: dir.appendingPathComponent("db.sqlite"))
    #expect(try store.imports().count == 1)
    m.delete(sha256: m.items[0].sha256)
    #expect(m.items.isEmpty)
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ onMain: Bool) { lock.lock(); values.append(onMain); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor @Test func importRunsOffMainThread() async throws {
    let dir = tempDir()
    let probe = Probe()
    let file = try write(sample, in: dir)
    let m = model(dir) { url in
        probe.record(Thread.isMainThread)
        return try ImportModel.defaultRun(file: url, storePath: dir.appendingPathComponent("db.sqlite"))
    }
    await m.runImport(file: file)
    #expect(probe.all == [false])
    #expect(cardOf(m.state)?.kind == .stored)
}

@MainActor @Test func secondStartWhileRunningDoesNothing() async throws {
    let dir = tempDir()
    let probe = Probe()
    let gate = DispatchSemaphore(value: 0)
    let file = try write(sample, in: dir)
    let m = model(dir) { url in
        probe.record(false)
        gate.wait()
        return try ImportModel.defaultRun(file: url, storePath: dir.appendingPathComponent("db.sqlite"))
    }
    m.start(file: file)
    #expect(m.state == .running)
    m.start(file: file)
    await m.runImport(file: file)  // refused at once, does not wait for the gate
    #expect(m.isRunning)
    gate.signal()
    while m.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(probe.all.count == 1)
    #expect(cardOf(m.state)?.kind == .stored)
}

@MainActor @Test func importIsOffWhileACaptureIsBusy() async throws {
    let dir = tempDir()
    let m = model(dir)
    m.captureBusy = true
    #expect(m.importUnavailableReason == "Import is unavailable while a capture is running.")
    await m.runImport(file: try write(sample, in: dir))
    #expect(m.state == .idle && m.items.isEmpty)
    m.captureBusy = false
    #expect(m.importUnavailableReason == nil)
    await m.runImport(file: try write(sample, in: dir))
    #expect(m.items.count == 1)
}

@MainActor @Test func deleteAllWaitsForARunningImport() async throws {
    let dir = tempDir()
    let gate = DispatchSemaphore(value: 0)
    let m = model(dir) { url in
        gate.wait()
        return try ImportModel.defaultRun(file: url, storePath: dir.appendingPathComponent("db.sqlite"))
    }
    #expect(m.deleteAllUnavailableReason(captureBusy: false) == nil)
    #expect(m.deleteAllUnavailableReason(captureBusy: true) == "Delete all data is unavailable while a capture is running.")
    let file = try write(sample, in: dir)
    m.start(file: file)
    #expect(m.isRunning)
    #expect(m.deleteAllUnavailableReason(captureBusy: false) == "Wait for the import to finish.")
    gate.signal()
    while m.isRunning { await Task.yield() }
    #expect(m.items.count == 1)
    #expect(m.deleteAllUnavailableReason(captureBusy: false) == nil)
}
