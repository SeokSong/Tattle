import Foundation
import Testing
import TestSupport
import PrivacyReport

private typealias B = PrivacyReportBuilder

// reads from memory in chunks and records how it was read
private final class MemorySource: LineSource {
    let data: Data
    let chunk: Int
    var byteCount: Int?
    var fileName: String?
    private(set) var reads = 0
    private(set) var largestRequest = 0
    private var position = 0
    init(_ data: Data, chunk: Int = 64 * 1024, name: String? = nil) {
        self.data = data
        self.chunk = chunk
        byteCount = data.count
        fileName = name
    }
    func read(maxLength: Int) throws -> Data {
        reads += 1
        largestRequest = max(largestRequest, maxLength)
        let n = min(chunk, maxLength, data.count - position)
        defer { position += n }
        return data.subdata(in: position..<position + n)
    }
}

private func run(_ data: Data, limits: ImportLimits = .standard, name: String? = nil) throws -> (ImportResult, [ReportRecord]) {
    var records = [ReportRecord]()
    let result = try ReportParser.parse(source: MemorySource(data, name: name), limits: limits) { records.append($0) }
    return (result, records)
}

@Test func parsesWellFormedFile() throws {
    let data = B.file([
        B.network(app: "com.example.app1", domain: "api.example.com", owner: "Example Owner", hits: 3,
                  first: B.stamp(18, hour: 8), last: B.stamp(19, hour: 10, millis: 250),
                  initiated: "NonAppInitiated", domainType: 2, classification: 2),
        B.access(),
        B.network(app: "com.example.app2", domain: "example.com", hits: 1),
    ])
    let (result, records) = try run(data)
    #expect(result.linesRead == 3 && result.kept == 2 && result.skippedAccess == 1)
    #expect(result.malformed == 0 && result.unknownTypes == 0 && !result.truncatedLastLine)
    let r = try #require(records.first)
    #expect(r.bundleID == "com.example.app1" && r.domain == "api.example.com" && r.hits == 3)
    #expect(r.domainOwner == "Example Owner" && r.initiatedType == "NonAppInitiated")
    #expect(r.domainType == 2 && r.domainClassification == 2)
    #expect(r.timeStamp.timeIntervalSince(r.firstTimeStamp) == 26 * 3600 + 0.25)
    #expect(records.count == 2 && records[1].bundleID == "com.example.app2")
}

@Test func unknownRecordTypesAreCountedAndSkipped() throws {
    let data = B.file([
        B.network(), B.other(type: "futureKind"), B.other(type: "futureKind"), B.other(type: "another_one"),
        B.other(type: "has spaces and a.dot"), B.network(domain: "example.net"),
    ])
    let (result, records) = try run(data)
    #expect(records.count == 2 && result.kept == 2)
    #expect(result.unknownTypes == 4)
    #expect(Set(result.unknownTypeNames) == ["futureKind", "another_one", "(unreadable)"])
}

@Test func truncatedLastLineIsReported() throws {
    var lines = [B.network(domain: "a.example.com"), B.network(domain: "b.example.com"), B.network(domain: "c.example.com")]
    lines[2] = String(lines[2].dropLast(40))
    let (result, records) = try run(B.file(lines, trailingNewline: false))
    #expect(result.truncatedLastLine)
    #expect(records.count == 2 && result.kept == 2 && result.malformed == 0 && result.linesRead == 2)
    // a complete last line without a line end is a normal record
    let (whole, wholeRecords) = try run(B.file([B.network(), B.network(domain: "b.example.com")], trailingNewline: false))
    #expect(!whole.truncatedLastLine && wholeRecords.count == 2)
}

@Test func malformedOverOnePercentRejects() throws {
    var lines = (0..<99).map { B.network(domain: "h\($0).example.com") }
    lines.append("not json at all")
    lines.append("{\"type\":\"networkActivity\"}")
    let error = #expect(throws: ImportError.self) { try run(B.file(lines)) }
    #expect(error == .tooManyMalformed(malformed: 2, lines: 101))
    // everything malformed stores nothing and is refused too
    #expect(throws: ImportError.self) { try run(B.file(["x", "y", "z"])) }
}

@Test func malformedUnderOnePercentIsCountedNotFatal() throws {
    var lines = (0..<200).map { B.network(domain: "h\($0).example.com") }
    lines.insert("garbage line", at: 50)
    let (result, records) = try run(B.file(lines))
    #expect(result.malformed == 1 && result.kept == 200 && records.count == 200 && result.linesRead == 201)
}

@Test func invalidRecordsAreMalformed() throws {
    var lines = (0..<400).map { B.network(domain: "h\($0).example.com") }
    lines.append(B.network(first: B.stamp(19), last: B.stamp(18)))          // first after last
    lines.append(B.network(app: ""))                                         // no app
    lines.append(B.network(hits: -1))                                        // negative hits
    lines.append(B.network(first: "yesterday", last: "yesterday"))           // bad stamps
    lines.append(B.network().replacingOccurrences(of: "\"hits\":1", with: "\"hits\":\"many\""))
    let (result, _) = try run(B.file(lines), limits: ImportLimits(maxFileBytes: 1 << 20, maxLineBytes: 4096, maxMalformedShare: 0.05, maxRecords: 1000))
    #expect(result.malformed == 5 && result.kept == 400)
}

@Test func fileOverCapRejectsBeforeReading() throws {
    let source = MemorySource(B.file([B.network()]))
    source.byteCount = 11
    let limits = ImportLimits(maxFileBytes: 10, maxLineBytes: 1000, maxMalformedShare: 0.01, maxRecords: 10)
    #expect(throws: ImportError.fileTooLarge(limit: 10)) {
        try ReportParser.parse(source: source, limits: limits) { _ in }
    }
    #expect(source.reads == 0)
    // a source that cannot say its size is stopped while reading
    let unsized = MemorySource(B.bulk(count: 200), chunk: 1000)
    unsized.byteCount = nil
    #expect(throws: ImportError.fileTooLarge(limit: 10_000)) {
        try ReportParser.parse(source: unsized, limits: ImportLimits(maxFileBytes: 10_000, maxLineBytes: 1000, maxMalformedShare: 0.01, maxRecords: 10_000)) { _ in }
    }
}

@Test func lineOverCapRejects() throws {
    let limits = ImportLimits(maxFileBytes: 1 << 20, maxLineBytes: 200, maxMalformedShare: 0.01, maxRecords: 100)
    // a terminated long line
    let long = B.network(domain: String(repeating: "a", count: 300) + ".example.com")
    #expect(throws: ImportError.lineTooLong(limit: 200)) { try run(B.file([B.network(), long]), limits: limits) }
    // a long run with no line end at all is stopped without waiting for the end of the file
    let endless = Data(repeating: 65, count: 5000)
    #expect(throws: ImportError.lineTooLong(limit: 200)) { try run(endless, limits: limits) }
}

@Test func recordCapRejects() throws {
    let limits = ImportLimits(maxFileBytes: 1 << 20, maxLineBytes: 4096, maxMalformedShare: 0.01, maxRecords: 5)
    #expect(throws: ImportError.recordCap(limit: 5)) {
        try run(B.file((0..<6).map { B.network(domain: "h\($0).example.com") }), limits: limits)
    }
    _ = try run(B.file((0..<5).map { B.network(domain: "h\($0).example.com") }), limits: limits)
}

@Test func accessRecordsAreDroppedNotStored() throws {
    let data = B.file([B.access(category: "camera"), B.network(), B.access(category: "photos"), B.access(), B.network(domain: "b.example.com")])
    let (result, records) = try run(data)
    #expect(result.skippedAccess == 3 && result.kept == 2 && records.count == 2 && result.linesRead == 5)
    #expect(records.allSatisfy { $0.domain.hasSuffix("example.com") })
}

@Test func contextIsDropped() throws {
    let line = B.network(context: "site.example.org")
    #expect(line.contains("site.example.org"))
    let (_, records) = try run(B.file([line]))
    let r = try #require(records.first)
    // the type has no context field, and nothing it holds carries the value
    #expect(Mirror(reflecting: r).children.allSatisfy { !String(describing: $0.value).contains("site.example.org") })
    #expect(!Mirror(reflecting: r).children.contains { $0.label == "context" })
}

@Test func emptyOwnerIsNil() throws {
    let (_, records) = try run(B.file([B.network(owner: ""), B.network(domain: "b.example.com", owner: "  "), B.network(domain: "c.example.com", owner: "Example Owner")]))
    #expect(records.map(\.domainOwner) == [nil, nil, "Example Owner"])
}

@Test func opaqueIntsAreCarriedRaw() throws {
    let (_, records) = try run(B.file([
        B.network(initiated: "NonAppInitiated", domainType: 7, classification: 9),
        B.network(domain: "b.example.com", initiated: "SomethingNew", domainType: 0, classification: 0),
    ]))
    #expect(records[0].domainType == 7 && records[0].domainClassification == 9 && records[0].initiatedType == "NonAppInitiated")
    #expect(records[1].domainType == 0 && records[1].domainClassification == 0 && records[1].initiatedType == "SomethingNew")
}

@Test func domainsAreLowerCasedWithoutTrailingDot() throws {
    let (_, records) = try run(B.file([B.network(domain: "API.Example.COM."), B.network(domain: "2001:DB8::1")]))
    #expect(records.map(\.domain) == ["api.example.com", "2001:db8::1"])
}

@Test func sameFileSameHash() throws {
    let data = B.file([B.network(), B.access()])
    let a = try run(data).0, b = try run(data).0
    #expect(a.fileSHA256 == b.fileSHA256 && a.fileSHA256.count == 64)
    // chunk size does not change it
    let small = try ReportParser.parse(source: MemorySource(data, chunk: 7)) { _ in }
    #expect(small.fileSHA256 == a.fileSHA256 && small == a)
}

@Test func differentFileDifferentHash() throws {
    let a = try run(B.file([B.network(hits: 1)])).0, b = try run(B.file([B.network(hits: 2)])).0
    #expect(a.fileSHA256 != b.fileSHA256)
}

@Test func hashMatchesKnownVectors() throws {
    // the parser reads these as one malformed line, so use a generous share to get past it
    let limits = ImportLimits(maxFileBytes: 1 << 26, maxLineBytes: 1 << 20, maxMalformedShare: 1, maxRecords: 10)
    func h(_ s: String, chunk: Int = 64) throws -> String {
        try ReportParser.parse(source: MemorySource(Data(s.utf8), chunk: chunk), limits: limits) { _ in }.fileSHA256
    }
    #expect(try h("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(try h("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(try h("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", chunk: 5)
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(try h(String(repeating: "a", count: 1_000_000), chunk: 4099)
        == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test func periodBoundary() throws {
    // seven days exactly, in one offset
    let week = try run(B.file([
        B.network(first: B.stamp(14), last: B.stamp(14, hour: 10)),
        B.network(domain: "b.example.com", first: B.stamp(21), last: B.stamp(21)),
    ])).0
    #expect(try #require(week.periodEnd).timeIntervalSince(try #require(week.periodStart)) == 7 * 86_400)
    // two offsets: 23:30 at -08:00 is later than 06:00 the next day at Z only when converted (07:30Z vs 06:00Z)
    let zones = try run(B.file([
        B.network(first: B.stamp(18, hour: 23, minute: 30, offset: "-08:00"), last: B.stamp(18, hour: 23, minute: 30, offset: "-08:00")),
        B.network(domain: "b.example.com", first: B.stamp(19, hour: 6, offset: "Z"), last: B.stamp(19, hour: 6, offset: "Z")),
        B.network(domain: "c.example.com", first: B.stamp(19, hour: 14, offset: "+09:00"), last: B.stamp(19, hour: 14, offset: "+09:00")),
    ])).0
    // earliest is 14:00 at +09:00 on the 19th (05:00Z); latest is 23:30 at -08:00 on the 18th (07:30Z the 19th)
    #expect(try #require(zones.periodStart) == ReportTimeCheck.date("2026-11-19T05:00:00Z"))
    #expect(try #require(zones.periodEnd) == ReportTimeCheck.date("2026-11-19T07:30:00Z"))
    // daylight saving: the clock goes from 01:59:59 -08:00 to 03:00:00 -07:00, one real second
    let dst = try run(B.file([
        B.network(first: B.stamp(8, month: 3, hour: 1, minute: 59, second: 59), last: B.stamp(8, month: 3, hour: 1, minute: 59, second: 59)),
        B.network(domain: "b.example.com", first: B.stamp(8, month: 3, hour: 3, offset: "-07:00"), last: B.stamp(8, month: 3, hour: 3, offset: "-07:00")),
    ])).0
    #expect(try #require(dst.periodEnd).timeIntervalSince(try #require(dst.periodStart)) == 1)
    // access records do not move the period
    let access = try run(B.file([B.network(first: B.stamp(18), last: B.stamp(18)), B.access(at: B.stamp(25))])).0
    #expect(access.periodEnd == access.periodStart)
}

private enum ReportTimeCheck {
    static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }
}

@Test func timeStampsAgreeWithTheSystemParser() throws {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for s in ["2026-11-18T00:00:00.000-08:00", "2026-02-28T23:59:59.999+05:30", "2024-02-29T12:00:00.500Z", "1999-12-31T23:59:59.001+14:00"] {
        let (_, records) = try run(B.file([B.network(first: s, last: s)]))
        let expected = try #require(f.date(from: s))
        #expect(abs(try #require(records.first).timeStamp.timeIntervalSince(expected)) < 0.002, "\(s)")
    }
    for bad in ["2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-11-18T24:00:00Z", "2026-11-18 09:00:00Z", "2026-11-18T09:00:00", "2026-11-18T09:00:00.Z"] {
        #expect(throws: ImportError.self) { try run(B.file([B.network(first: bad, last: bad)])) }
    }
}

@Test func combinesOneRowPerAppAndDomain() throws {
    let data = B.file([
        B.network(app: "com.example.app1", domain: "example.com", owner: "", hits: 2, first: B.stamp(18, hour: 9), last: B.stamp(18, hour: 10), initiated: "AppInitiated", domainType: 1, classification: 1),
        B.network(app: "com.example.app1", domain: "EXAMPLE.com", owner: "First Owner", hits: 5, first: B.stamp(19, hour: 9), last: B.stamp(19, hour: 12), initiated: "NonAppInitiated", domainType: 2, classification: 2),
        B.network(app: "com.example.app1", domain: "example.com", owner: "Second Owner", hits: 1, first: B.stamp(17, hour: 8), last: B.stamp(17, hour: 8), initiated: "AppInitiated", domainType: 1, classification: 1),
        B.network(app: "com.example.app2", domain: "example.com", hits: 4),
    ])
    let (contacts, result) = try ReportParser.parseCombined(source: MemorySource(data))
    #expect(result.kept == 4 && contacts.count == 2)
    let c = try #require(contacts.first)
    #expect(c.appID == "com.example.app1" && c.domain == "example.com" && c.hits == 8)
    #expect(c.domainOwner == "First Owner")                       // first non-empty in file order
    #expect(c.firstSeen == ReportTimeCheck.date("2026-11-17T08:00:00-08:00"))
    #expect(c.lastSeen == ReportTimeCheck.date("2026-11-19T12:00:00-08:00"))
    #expect(c.initiatedType == "NonAppInitiated" && c.domainType == 2 && c.domainClassification == 2)   // latest record
    #expect(contacts[1].appID == "com.example.app2" && contacts[1].hits == 4)
}

@Test func combinedHitsNeverOverflow() throws {
    var c = ContactCombiner()
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    for _ in 0..<2 {
        c.add(ReportRecord(bundleID: "com.example.app1", domain: "example.com", domainOwner: nil, hits: Int.max - 1,
                           firstTimeStamp: t, timeStamp: t, initiatedType: nil, domainType: nil, domainClassification: nil))
    }
    #expect(c.contacts.first?.hits == Int.max)
}

@Test func formatVersionComesFromTheFileName() throws {
    let data = B.file([B.network()])
    let ok = try run(data, name: "App_Privacy_Report_v4_2026-11-21T17_04_21.ndjson").0
    #expect(ok.formatVersion == 4 && !ok.unexpectedFormatVersion)
    let newer = try run(data, name: "App_Privacy_Report_v5_2027-01-01T00_00_00.ndjson").0
    #expect(newer.formatVersion == 5 && newer.unexpectedFormatVersion && newer.kept == 1)
    let odd = try run(data, name: "export.ndjson").0
    // a renamed export has no version to compare: no version, no warning
    #expect(odd.formatVersion == nil && !odd.unexpectedFormatVersion)
    // no name, no verdict
    let none = try run(data).0
    #expect(none.formatVersion == nil && !none.unexpectedFormatVersion)
}

@Test func errorsNeverEchoDomainsOrAppIds() throws {
    let secretApp = "com.example.secretapp", secretDomain = "secret-host.example.com"
    let limits = ImportLimits(maxFileBytes: 1 << 20, maxLineBytes: 100, maxMalformedShare: 0.01, maxRecords: 3)
    let cases: [Data] = [
        B.file([B.network(app: secretApp, domain: secretDomain)]),
        B.file([B.network(app: secretApp, domain: secretDomain, hits: -1)]),
        B.file((0..<5).map { _ in B.network(app: secretApp, domain: secretDomain) }),
    ]
    var seen = 0
    for data in cases {
        do { _ = try run(data, limits: limits) } catch {
            seen += 1
            for text in ["\(error)", error.localizedDescription, String(reflecting: error)] {
                #expect(!text.contains("secret") && !text.contains("example"))
            }
        }
    }
    #expect(seen == 3)
    let unreadable = FileLineSourceMissing.attempt()
    #expect(unreadable == "the file could not be read")
}

private enum FileLineSourceMissing {
    static func attempt() -> String {
        do { _ = try FileLineSource(url: URL(fileURLWithPath: "/nonexistent/secret-host.example.com.ndjson")) } catch { return "\(error)" }
        return ""
    }
}

@Test func streamingDoesNotLoadWholeFile() throws {
    let data = B.bulk(count: 100_000)
    let source = MemorySource(data)
    var count = 0
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        let result = try ReportParser.parse(source: source) { _ in count += 1 }
        #expect(result.kept == 100_000 && result.malformed == 0)
    }
    print("parsed 100000 lines (\(data.count) bytes) in \(elapsed), \(source.reads) reads")
    #expect(count == 100_000)
    #expect(source.reads > data.count / (64 * 1024) && source.largestRequest <= 64 * 1024)
    // the 2 s budget holds for an optimized build (0.6 s measured); an unoptimized debug build is about 20 times slower
    #if DEBUG
    #expect(elapsed < .seconds(60))
    #else
    #expect(elapsed < .seconds(2))
    #endif
}

@Test func emptyFileIsAnEmptyResultNotACrash() throws {
    for data in [Data(), Data("\n\n  \n".utf8)] {
        let (result, records) = try run(data)
        #expect(records.isEmpty && result.kept == 0 && result.linesRead == 0 && result.hasNoNetworkRecords)
        #expect(result.periodStart == nil && result.periodEnd == nil && !result.truncatedLastLine)
    }
    // only access records: valid, nothing to store
    let (onlyAccess, _) = try run(B.file([B.access(), B.access()]))
    #expect(onlyAccess.hasNoNetworkRecords && onlyAccess.skippedAccess == 2)
}

@Test func fileLineSourceReadsInChunks() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString).ndjson")
    try B.bulk(count: 3000).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try FileLineSource(url: url)
    #expect(source.byteCount != nil && source.fileName == url.lastPathComponent)
    let result = try ReportParser.parse(source: source) { _ in }
    #expect(result.kept == 3000)
}

@Test func schemaShapeFileIsNotCommitted() throws {
    // the shape of the owner's export stays in the private fixtures folder (md/PRIVACY_REPORT.md)
    let root = try #require(RepoGuard.repoRoot())
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Tests/PrivacyReportTests/Resources/schema-shape.txt").path))
}

// the owner's real export: counts and invariants only, numbers printed, never a value.
// skipped without TATTLE_FIXTURES. the expected counts are in expected-counts.txt next to the
// export (private, key=value lines); without that file only the invariants are checked
@Test func realFileCountsMatch() throws {
    guard let url = Fixtures.privacyReport() else { return }
    var apps = Set<String>(), domains = Set<String>()
    var noOwner = 0, hits = 0
    let result = try ReportParser.parse(source: try FileLineSource(url: url)) { r in
        apps.insert(r.bundleID)
        domains.insert(r.domain)
        if r.domainOwner == nil { noOwner += 1 }
        hits += r.hits
        #expect(r.firstTimeStamp <= r.timeStamp)
    }
    let days = try #require(result.periodEnd).timeIntervalSince(try #require(result.periodStart)) / 86_400
    let (contacts, _) = try ReportParser.parseCombined(source: try FileLineSource(url: url))
    print("real export: lines=\(result.linesRead) network=\(result.kept) access=\(result.skippedAccess) "
        + "unknown=\(result.unknownTypes) malformed=\(result.malformed) apps=\(apps.count) domains=\(domains.count) "
        + "noOwner=\(noOwner) hits=\(hits) contacts=\(contacts.count) periodDays=\(String(format: "%.2f", days)) "
        + "version=\(result.formatVersion ?? -1) unexpectedVersion=\(result.unexpectedFormatVersion)")
    var expected: [String: Int] = [:]
    let countsFile = url.deletingLastPathComponent().appendingPathComponent("expected-counts.txt")
    for line in ((try? String(contentsOf: countsFile, encoding: .utf8)) ?? "").split(separator: "\n") {
        let parts = line.split(separator: "=")
        if parts.count == 2, let n = Int(parts[1]) { expected[String(parts[0])] = n }
    }
    if !expected.isEmpty {
        #expect(result.linesRead == expected["lines"] && result.kept == expected["network"] && result.skippedAccess == expected["access"])
        #expect(apps.count == expected["apps"] && noOwner == expected["noOwner"] && hits == expected["hits"] && domains.count == expected["domains"])
    }
    #expect(result.linesRead == result.kept + result.skippedAccess + result.unknownTypes + result.malformed)
    #expect(result.malformed == 0 && result.unknownTypes == 0 && !result.truncatedLastLine)
    #expect(contacts.count <= result.kept && contacts.reduce(0) { $0 + $1.hits } == hits)
    #expect(days > 0 && days <= 7.01)
    #expect(result.formatVersion == 4 && !result.unexpectedFormatVersion)
}
