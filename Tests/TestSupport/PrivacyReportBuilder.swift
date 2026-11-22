import Foundation

// builds synthetic App Privacy Report exports in memory: fake bundle ids (com.example.app1) and
// reserved example domains only. lines are made with JSONSerialization so no source file holds a
// line that looks like a real export (the repo guard would reject it)
public enum PrivacyReportBuilder {
    public static let fakeApps = (1...5).map { "com.example.app\($0)" }
    public static let fakeDomains = ["example.com", "api.example.com", "cdn.example.net", "tracker.example.org"]

    /// "2026-11-18T09:15:30.123-08:00" style stamp; `offset` is the text after the time ("-08:00", "Z")
    public static func stamp(
        _ day: Int, month: Int = 11, hour: Int = 9, minute: Int = 0, second: Int = 0, millis: Int = 0,
        offset: String = "-08:00"
    ) -> String {
        String(format: "2026-%02d-%02dT%02d:%02d:%02d.%03d", month, day, hour, minute, second, millis) + offset
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public static func network(
        app: String = "com.example.app1", domain: String = "example.com", owner: String = "",
        hits: Int = 1, first: String? = nil, last: String? = nil,
        initiated: String = "AppInitiated", domainType: Int = 1, classification: Int = 1, context: String = ""
    ) -> String {
        let t = last ?? stamp(18)
        return line([
            "type": "networkActivity", "bundleID": app, "domain": domain, "domainOwner": owner, "hits": hits,
            "firstTimeStamp": first ?? t, "timeStamp": t, "initiatedType": initiated, "context": context,
            "domainType": domainType, "domainClassification": classification, "contextVerificationType": 0,
        ])
    }

    public static func access(app: String = "com.example.app1", category: String = "location", at: String? = nil) -> String {
        line([
            "type": "access", "timeStamp": at ?? stamp(18), "kind": "intervalBegin", "category": category,
            "accessor": ["identifier": app, "identifierType": "bundleID"],
            "identifier": "00000000-0000-4000-8000-000000000001", "accessCount": 0,
        ])
    }

    /// a line of another record type
    public static func other(type: String) -> String { line(["type": type, "timeStamp": stamp(18)]) }

    public static func file(_ lines: [String], trailingNewline: Bool = true) -> Data {
        Data((lines.joined(separator: "\n") + (trailingNewline && !lines.isEmpty ? "\n" : "")).utf8)
    }

    /// `count` network lines spread over the fake apps and domains and four days
    public static func bulk(count: Int) -> Data {
        var out = Data()
        out.reserveCapacity(count * 280)
        for i in 0..<count {
            let l = network(
                app: fakeApps[i % fakeApps.count], domain: "h\(i % 997).example.com", hits: 1 + i % 7,
                last: stamp(18 + i % 4, hour: i % 24, minute: i % 60))
            out.append(Data(l.utf8))
            out.append(10)
        }
        return out
    }
}
