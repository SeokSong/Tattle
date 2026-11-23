import Foundation

/// streaming parser for the App Privacy Report export (NDJSON, format in md/PRIVACY_REPORT.md).
/// pure: reads a `LineSource`, hands each network record to a sink, keeps nothing else. it has no
/// dependencies and does not touch storage. records handed to the sink are provisional until `parse`
/// returns: a thrown `ImportError` means the import is refused and the sink's records must be dropped
public enum ReportParser {
    /// the export format this parser was written against (`v4` in the file name)
    public static let supportedFormatVersion = 4

    // one line, decoded once. `type` is read first and the other keys only for a network record, so an
    // access record or an unknown kind is never read beyond its kind; `context` is not a key here at all
    private struct Line: Decodable {
        let type: String?
        let network: Network?

        enum Keys: String, CodingKey {
            case type, bundleID, domain, domainOwner, hits, firstTimeStamp, timeStamp
            case initiatedType, domainType, domainClassification
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try? c.decode(String.self, forKey: .type)
            guard type == "networkActivity" else {
                network = nil
                return
            }
            // a wrong type in one field makes the line malformed, so `try?` is used only for optional fields
            network = Network(
                bundleID: try c.decode(String.self, forKey: .bundleID),
                domain: try c.decode(String.self, forKey: .domain),
                domainOwner: try? c.decodeIfPresent(String.self, forKey: .domainOwner),
                hits: try c.decode(Int.self, forKey: .hits),
                firstTimeStamp: try c.decode(String.self, forKey: .firstTimeStamp),
                timeStamp: try c.decode(String.self, forKey: .timeStamp),
                initiatedType: try? c.decodeIfPresent(String.self, forKey: .initiatedType),
                domainType: try? c.decodeIfPresent(Int.self, forKey: .domainType),
                domainClassification: try? c.decodeIfPresent(Int.self, forKey: .domainClassification))
        }
    }

    private struct Network {
        let bundleID: String
        let domain: String
        let domainOwner: String?
        let hits: Int
        let firstTimeStamp: String
        let timeStamp: String
        let initiatedType: String?
        let domainType: Int?
        let domainClassification: Int?
    }

    public static func parse(
        source: any LineSource, limits: ImportLimits = .standard, sink: (ReportRecord) throws -> Void
    ) throws -> ImportResult {
        if let size = source.byteCount, size > limits.maxFileBytes {
            throw ImportError.fileTooLarge(limit: limits.maxFileBytes)
        }
        var hasher = SHA256Hasher()
        var buffer = [UInt8]()
        var bytesRead = 0
        var lines = 0, kept = 0, access = 0, unknown = 0, malformed = 0
        var names = [String]()
        var start: Date?, end: Date?
        var truncated = false
        let decoder = JSONDecoder()

        // a line that fails to parse is malformed, unless it is the last one and has no line end: then it was cut off
        func handle(_ line: ArraySlice<UInt8>, lastWithoutEnd: Bool) throws {
            var line = line
            if line.last == 13 { line = line.dropLast() }
            if line.allSatisfy({ $0 == 32 || $0 == 9 }) { return }
            lines += 1
            if lines > limits.maxRecords { throw ImportError.recordCap(limit: limits.maxRecords) }
            let data = Data(line)
            guard let parsed = try? decoder.decode(Line.self, from: data), let type = parsed.type else {
                if lastWithoutEnd { truncated = true; lines -= 1 } else { malformed += 1 }
                return
            }
            switch type {
            case "access":
                access += 1
            case "networkActivity":
                guard let n = parsed.network, let record = makeRecord(n) else {
                    if lastWithoutEnd { truncated = true; lines -= 1 } else { malformed += 1 }
                    return
                }
                kept += 1
                start = start.map { min($0, record.firstTimeStamp) } ?? record.firstTimeStamp
                end = end.map { max($0, record.timeStamp) } ?? record.timeStamp
                try sink(record)
            default:
                unknown += 1
                let name = safeName(type)
                if !names.contains(name), names.count < ImportResult.maxUnknownTypeNames { names.append(name) }
            }
        }

        while true {
            let chunk: Data
            do { chunk = try source.read(maxLength: FileLineSource.chunkSize) } catch { throw ImportError.unreadable }
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            if bytesRead > limits.maxFileBytes { throw ImportError.fileTooLarge(limit: limits.maxFileBytes) }
            hasher.update(chunk)
            buffer.append(contentsOf: chunk)

            var from = 0
            while let nl = newline(in: buffer, from: from) {
                if nl - from > limits.maxLineBytes { throw ImportError.lineTooLong(limit: limits.maxLineBytes) }
                try handle(buffer[from..<nl], lastWithoutEnd: false)
                from = nl + 1
            }
            if from > 0 { buffer.removeSubrange(0..<from) }
            if buffer.count > limits.maxLineBytes { throw ImportError.lineTooLong(limit: limits.maxLineBytes) }
        }
        if !buffer.isEmpty { try handle(buffer[...], lastWithoutEnd: true) }

        if lines > 0, Double(malformed) / Double(lines) > limits.maxMalformedShare {
            throw ImportError.tooManyMalformed(malformed: malformed, lines: lines)
        }
        let version = source.fileName.flatMap(formatVersion(inFileName:))
        return ImportResult(
            fileSHA256: hasher.finish(), bytesRead: bytesRead, linesRead: lines, kept: kept,
            skippedAccess: access, unknownTypes: unknown, unknownTypeNames: names, malformed: malformed,
            periodStart: start, periodEnd: end, truncatedLastLine: truncated,
            formatVersion: version, unexpectedFormatVersion: version.map { $0 != supportedFormatVersion } ?? false)
    }

    /// parses and combines into one row per app and domain; nothing is returned when the import is refused
    public static func parseCombined(
        source: any LineSource, limits: ImportLimits = .standard
    ) throws -> (contacts: [ReportContact], result: ImportResult) {
        var combiner = ContactCombiner()
        let result = try parse(source: source, limits: limits) { combiner.add($0) }
        return (combiner.contacts, result)
    }

    /// the `4` of `App_Privacy_Report_v4_<timestamp>.ndjson`; nil for any other name shape
    public static func formatVersion(inFileName name: String) -> Int? {
        let prefix = "App_Privacy_Report_v"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        return Int(digits)
    }

    private static func makeRecord(_ n: Network) -> ReportRecord? {
        guard !n.bundleID.isEmpty, n.hits >= 0,
              let first = ReportTime.parse(n.firstTimeStamp), let last = ReportTime.parse(n.timeStamp),
              first <= last else { return nil }
        var domain = n.domain.lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty else { return nil }
        let owner = n.domainOwner?.trimmingCharacters(in: .whitespaces)
        return ReportRecord(
            bundleID: n.bundleID, domain: domain, domainOwner: (owner?.isEmpty ?? true) ? nil : owner,
            hits: n.hits, firstTimeStamp: first, timeStamp: last, initiatedType: n.initiatedType,
            domainType: n.domainType, domainClassification: n.domainClassification)
    }

    // record kind names are format words; anything odd is not echoed
    private static func safeName(_ s: String) -> String {
        let ok = !s.isEmpty && s.utf8.count <= 40 && s.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95
        }
        return ok ? s : "(unreadable)"
    }

    private static func newline(in buffer: [UInt8], from: Int) -> Int? {
        buffer.withUnsafeBufferPointer { p in
            guard from < p.count, let found = memchr(p.baseAddress! + from, 10, p.count - from) else { return nil }
            return p.baseAddress!.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }
}
