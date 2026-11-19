import Attribution
import Domains
import Flows
import Foundation

// a scenario file describes what a capture should contain (what the phone did, and when).
// it names apps and sites, so real ones live outside the repo (~/dev/watch-fixtures/scenarios).
// scoring is pure: flows and domain observations in, numbers out.

public struct ScenarioWindow: Codable, Equatable, Sendable {
    /// seconds after the first packet of the capture
    public var start: Double
    public var end: Double
    /// empty or absent: no app is expected to lead (an idle phone)
    public var expectedTopApp: String?

    public init(start: Double, end: Double, expectedTopApp: String? = nil) {
        self.start = start
        self.end = end
        self.expectedTopApp = expectedTopApp
    }
}

public struct Scenario: Codable, Equatable, Sendable {
    public static let defaultSlackSeconds = 5.0

    public var id: String
    public var windows: [ScenarioWindow]
    public var expectedApps: [String]
    public var expectedHosts: [String]
    public var mustNotBeDeviceLink: [String]
    public var slackSeconds: Double

    public init(
        id: String, windows: [ScenarioWindow], expectedApps: [String] = [], expectedHosts: [String] = [],
        mustNotBeDeviceLink: [String] = [], slackSeconds: Double = Scenario.defaultSlackSeconds
    ) {
        self.id = id
        self.windows = windows
        self.expectedApps = expectedApps
        self.expectedHosts = expectedHosts
        self.mustNotBeDeviceLink = mustNotBeDeviceLink
        self.slackSeconds = slackSeconds
    }

    // everything but id and windows may be absent in the file
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        windows = try c.decode([ScenarioWindow].self, forKey: .windows)
        expectedApps = try c.decodeIfPresent([String].self, forKey: .expectedApps) ?? []
        expectedHosts = try c.decodeIfPresent([String].self, forKey: .expectedHosts) ?? []
        mustNotBeDeviceLink = try c.decodeIfPresent([String].self, forKey: .mustNotBeDeviceLink) ?? []
        slackSeconds = try c.decodeIfPresent(Double.self, forKey: .slackSeconds) ?? Scenario.defaultSlackSeconds
    }

    public static func load(_ url: URL) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    }
}

public struct WindowScore: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var flows: Int
    /// nil when the window expects no top app
    public var topAppMatch: Bool?
}

public struct ScenarioScore: Codable, Equatable, Sendable {
    public var scenario: String
    /// windows with an expected top app that matched, over windows with an expected top app
    public var topAppMatch: Ratio
    /// expected apps found among app-traffic flows in any window, over expected apps
    public var appRecall: Ratio
    /// expected hosts matched by a resolved name in any window, over expected hosts
    public var hostRecall: Ratio
    /// bytes of app-traffic flows in the windows whose app is not an expected app, over all such bytes.
    /// information, not an error
    public var unlabelledShare: Ratio
    /// flows in the windows that `Classifier` put in `deviceLink` although a process in `mustNotBeDeviceLink` carried them; must be 0
    public var deviceLinkFalsePositives: Int?
    public var windows: [WindowScore]
}

extension Scenario {
    /// scoring rules:
    /// - time zero is the earliest `firstSeen` of any flow (the first packet of the capture)
    /// - a window scores the flows whose `firstSeen` is inside `[start + slack, end]`; flows that began
    ///   before the window are ignored, even when they carry traffic inside it
    /// - app traffic is a flow whose winning process group is a non-system app (or a system process
    ///   working for an app); bytes are IP bytes in plus out
    public func score(flows: [Flow], domains: [DomainObservation]) -> ScenarioScore {
        let zero = flows.map(\.firstSeen).min() ?? Date(timeIntervalSince1970: 0)
        // no flows: host recall counts sni and dns names, never the same-address hint
        let index = HostnameIndex(domains)

        var windowScores: [WindowScore] = []
        var inWindow: [Flow] = []
        var seen = Set<UUID>()
        var topMatches = 0, topExpected = 0
        for w in windows {
            let lo = zero.addingTimeInterval(w.start + slackSeconds)
            let hi = zero.addingTimeInterval(w.end)
            let scored = flows.filter { $0.firstSeen >= lo && $0.firstSeen <= hi }
            for f in scored where seen.insert(f.id).inserted { inWindow.append(f) }

            var match: Bool?
            if let expected = w.expectedTopApp, !expected.isEmpty {
                var byApp: [String: Int] = [:]
                for f in scored { if let app = Self.appName(f) { byApp[app, default: 0] += f.totalBytes } }
                let top = byApp.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
                match = top.map { Self.appMatches($0, expected) } ?? false
                topExpected += 1
                if match == true { topMatches += 1 }
            }
            windowScores.append(WindowScore(start: w.start, end: w.end, flows: scored.count, topAppMatch: match))
        }

        let apps = Set(inWindow.compactMap(Self.appName))
        let appsFound = expectedApps.filter { e in apps.contains { Self.appMatches($0, e) } }.count

        let names = inWindow.compactMap { index.resolve($0)?.name.lowercased() }
        let hostsFound = expectedHosts.filter { Self.hostMatches(names, $0.lowercased()) }.count

        var appBytes = 0, unlabelled = 0
        for f in inWindow {
            guard let app = Self.appName(f) else { continue }
            appBytes += f.totalBytes
            if !expectedApps.contains(where: { Self.appMatches(app, $0) }) { unlabelled += f.totalBytes }
        }

        // a flow counts when it is deviceLink and any process name in its tally is on the must-not list
        let falsePositives = inWindow.filter { f in
            guard Classifier.classify(f).category == .deviceLink else { return false }
            let names = f.tally.keys.flatMap { [$0.processName, $0.effectiveName].compactMap { $0 } }
            return names.contains { n in mustNotBeDeviceLink.contains { Self.appMatches(n, $0) } }
        }.count

        return ScenarioScore(
            scenario: id,
            topAppMatch: Ratio(numerator: topMatches, denominator: topExpected),
            appRecall: Ratio(numerator: appsFound, denominator: expectedApps.count),
            hostRecall: Ratio(numerator: hostsFound, denominator: expectedHosts.count),
            unlabelledShare: Ratio(numerator: unlabelled, denominator: appBytes),
            deviceLinkFalsePositives: falsePositives,
            windows: windowScores)
    }

    /// resolved name equals the expected host, or ends with "." + host (so notexample.com never matches example.com)
    static func hostMatches(_ names: [String], _ host: String) -> Bool {
        names.contains { $0 == host || $0.hasSuffix("." + host) }
    }

    /// raw process names are cut to 16 characters; the expected name may be the full or the display name
    static func appMatches(_ raw: String, _ expected: String) -> Bool {
        raw == expected || ProcessNames.matches(raw, full: expected) || ProcessNames.displayName(raw) == expected
    }

    /// the app of an app-traffic flow; nil for system, device link and no-process flows
    static func appName(_ f: Flow) -> String? {
        switch Attributor.attribute(f.tally).primary {
        case .app(let name, _): return name
        case .onBehalfOf(let app, _): return app
        case .system, .unknown: return nil
        }
    }
}

extension Flow {
    fileprivate var totalBytes: Int { ipBytesIn + ipBytesOut }
}

extension ScenarioScore {
    /// numbers and the scenario id only; app and host names never print
    public func text() -> String {
        func pct(_ r: Ratio) -> String {
            let v = r.value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
            return "\(v)  (\(r.numerator) / \(r.denominator))"
        }
        var lines = ["Scenario \(scenario)"]
        lines.append("topAppMatch  \(pct(topAppMatch))")
        lines.append("appRecall  \(pct(appRecall))")
        lines.append("hostRecall  \(pct(hostRecall))")
        lines.append("unlabelledShare  \(pct(unlabelledShare))  (information)")
        lines.append("deviceLinkFalsePositives  \(deviceLinkFalsePositives.map(String.init) ?? "n/a")")
        for (i, w) in windows.enumerated() {
            let top = w.topAppMatch.map { $0 ? "match" : "MISMATCH" } ?? "no expectation"
            lines.append("window \(i + 1)  \(Int(w.start))-\(Int(w.end)) s  \(w.flows) flows  top app: \(top)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
