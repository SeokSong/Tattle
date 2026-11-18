import Domains
import Flows
import Foundation
import PacketDecoder
import Testing
import TestSupport

@testable import Report

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let phone = IPAddress.v4(0x0A00_0002)

// documentation range 192.0.2.0/24; hostnames are reserved example names
private func flow(at seconds: Double, bytes: Int, app: String?, port: UInt16 = 443, host: UInt32 = 1) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: phone, localPort: UInt16.random(in: 40000...60000),
        remoteAddress: .v4(0xC000_0200 + host), remotePort: port)
    var f = Flow(key: key, interface: "en0", at: t0.addingTimeInterval(seconds))
    f.ipBytesIn = bytes
    f.packetsIn = 2
    f.tally[app.map { ProcessPair($0, 1, nil, nil) } ?? .none] = 2
    return f
}

private func sni(_ f: Flow, _ name: String) -> Flow {
    var f = f
    f.serverName = name
    return f
}

private let window = ScenarioWindow(start: 10, end: 70, expectedTopApp: "Safari")

@Test func windowScoringIgnoresFlowsOutsideWindow() {
    // first packet at 0 s; slack 5 puts the window start at 15 s
    let flows = [
        flow(at: 0, bytes: 100, app: "Safari"), flow(at: 20, bytes: 100, app: "Safari"),
        flow(at: 90, bytes: 100, app: "Safari"),
    ]
    let s = Scenario(id: "x", windows: [window], expectedApps: ["Safari"])
    let score = s.score(flows: flows, domains: [])
    #expect(score.windows.map(\.flows) == [1])
    #expect(score.unlabelledShare == Ratio(numerator: 0, denominator: 100))
    // a flow inside the window but earlier than start + slack is ignored too
    let early = [flow(at: 0, bytes: 1, app: nil), flow(at: 12, bytes: 100, app: "Safari")]
    #expect(s.score(flows: early, domains: []).windows.map(\.flows) == [0])
    // slackSeconds 0 brings it in
    let noSlack = Scenario(id: "x", windows: [window], slackSeconds: 0)
    #expect(noSlack.score(flows: early, domains: []).windows.map(\.flows) == [1])
}

@Test func topAppMatchUsesAppTrafficBytes() {
    let flows = [
        flow(at: 0, bytes: 10, app: nil),
        flow(at: 20, bytes: 500, app: "Safari"), flow(at: 21, bytes: 900, app: "mDNSResponder"),
    ]
    let s = Scenario(id: "x", windows: [window], expectedApps: ["Safari"])
    let score = s.score(flows: flows, domains: [])
    #expect(score.topAppMatch == Ratio(numerator: 1, denominator: 1))
    #expect(score.windows[0].topAppMatch == true)
    // a different leader is a mismatch
    let other = flows + [flow(at: 22, bytes: 600, app: "Instagram")]
    #expect(s.score(flows: other, domains: []).topAppMatch == Ratio(numerator: 0, denominator: 1))
}

@Test func twoWindowsScoreOnTheirOwn() {
    let flows = [
        flow(at: 0, bytes: 1, app: nil), flow(at: 20, bytes: 500, app: "TikTok"),
        flow(at: 60, bytes: 400, app: "Instagram"),
    ]
    let s = Scenario(
        id: "x",
        windows: [
            ScenarioWindow(start: 10, end: 40, expectedTopApp: "TikTok"),
            ScenarioWindow(start: 50, end: 80, expectedTopApp: "Instagram"),
        ], expectedApps: ["TikTok", "Instagram"])
    let score = s.score(flows: flows, domains: [])
    #expect(score.windows.map(\.topAppMatch) == [true, true])
    #expect(score.topAppMatch == Ratio(numerator: 2, denominator: 2))
    #expect(score.appRecall == Ratio(numerator: 2, denominator: 2))
}

@Test func appRecallAndHostRecall() {
    let flows = [
        sni(flow(at: 0, bytes: 1, app: nil), "start.example"),
        sni(flow(at: 20, bytes: 500, app: "Safari", host: 1), "cdn.example.com"),
        sni(flow(at: 21, bytes: 500, app: "Safari", host: 2), "notexample.com"),
        sni(flow(at: 22, bytes: 500, app: "Safari", host: 3), "www.example.org"),
    ]
    let s = Scenario(
        id: "x", windows: [window], expectedApps: ["Safari", "Instagram"],
        expectedHosts: ["example.com", "example.org", "iana.org"])
    let score = s.score(flows: flows, domains: [])
    // cdn.example.com and www.example.org match by suffix; notexample.com does not; iana.org is missing
    #expect(score.hostRecall == Ratio(numerator: 2, denominator: 3))
    #expect(score.appRecall == Ratio(numerator: 1, denominator: 2))
    #expect(Scenario.hostMatches(["notexample.com"], "example.com") == false)
    #expect(Scenario.hostMatches(["example.com"], "example.com"))
}

@Test func hostNamesComeFromDNSToo() {
    let f = flow(at: 20, bytes: 500, app: "Safari", host: 7)
    let answer = DomainObservation(
        time: t0.addingTimeInterval(19), source: .dns, hostname: "www.iana.org", addresses: [f.key.remoteAddress], ttl: 60)
    let s = Scenario(id: "x", windows: [window], expectedHosts: ["iana.org"])
    let score = s.score(flows: [flow(at: 0, bytes: 1, app: nil), f], domains: [answer])
    #expect(score.hostRecall == Ratio(numerator: 1, denominator: 1))
}

@Test func unlabelledShareIsInformation() {
    let flows = [
        flow(at: 0, bytes: 1, app: nil),
        flow(at: 20, bytes: 600, app: "Safari"), flow(at: 21, bytes: 400, app: "Spotify"),
    ]
    let score = Scenario(id: "x", windows: [window], expectedApps: ["Safari"]).score(flows: flows, domains: [])
    #expect(score.unlabelledShare == Ratio(numerator: 400, denominator: 1000))
    #expect(score.topAppMatch == Ratio(numerator: 1, denominator: 1))
    #expect(score.deviceLinkFalsePositives == 0)
}

@Test func idleScenarioExpectsNoTopApp() {
    let s = Scenario(id: "s0-idle", windows: [ScenarioWindow(start: 0, end: 100, expectedTopApp: "")])
    let score = s.score(flows: [flow(at: 10, bytes: 100, app: "mDNSResponder")], domains: [])
    #expect(score.topAppMatch == Ratio(numerator: 0, denominator: 0))
    #expect(score.windows[0].topAppMatch == nil)
}

@Test func scenarioFileRoundTrips() throws {
    let s = Scenario(
        id: "s1-safari", windows: [window], expectedApps: ["Safari"], expectedHosts: ["example.com"],
        mustNotBeDeviceLink: ["Safari"], slackSeconds: 2)
    let back = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(s))
    #expect(back == s)

    // slackSeconds and the lists may be absent
    let json = #"{"id": "s1", "windows": [{"start": 10, "end": 70, "expectedTopApp": "Safari"}]}"#
    let minimal = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
    #expect(minimal.slackSeconds == 5)
    #expect(minimal.expectedApps.isEmpty && minimal.expectedHosts.isEmpty && minimal.mustNotBeDeviceLink.isEmpty)
}

@Test func scoreTextHasNoNames() {
    let flows = [flow(at: 0, bytes: 1, app: nil), sni(flow(at: 20, bytes: 500, app: "Safari"), "cdn.example.com")]
    let s = Scenario(id: "s1-safari", windows: [window], expectedApps: ["Safari"], expectedHosts: ["example.com"])
    let text = s.score(flows: flows, domains: []).text()
    #expect(text.contains("hostRecall  100.0%"))
    #expect(!text.contains("Safari") && !text.contains("example.com"))
}

@Test func deviceLinkFalsePositivesCountsListedProcesses() {
    // heartbeatd is deviceLink; listing it makes it a false positive, listing Safari does not
    let flows = [flow(at: 0, bytes: 1, app: nil), flow(at: 20, bytes: 100, app: "heartbeatd"), flow(at: 21, bytes: 100, app: "Safari")]
    let listed = Scenario(id: "x", windows: [window], mustNotBeDeviceLink: ["heartbeatd"])
    #expect(listed.score(flows: flows, domains: []).deviceLinkFalsePositives == 1)
    let other = Scenario(id: "x", windows: [window], mustNotBeDeviceLink: ["Safari"])
    #expect(other.score(flows: flows, domains: []).deviceLinkFalsePositives == 0)
}
