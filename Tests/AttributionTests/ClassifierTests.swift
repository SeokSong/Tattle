import Flows
import Foundation
import PacketDecoder
import Testing

@testable import Attribution

// documentation ranges: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let phone: IPAddress = .v4(0x0A00_0002)
private let publicAddress: IPAddress = .v4(0xCB00_7109)  // 203.0.113.9

private func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> IPAddress {
    .v4(a << 24 | b << 16 | c << 8 | d)
}

private func flow(
    _ rows: [(ProcessPair, Int)], remote: IPAddress = publicAddress, local: IPAddress = phone
) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: local, localPort: 50000, remoteAddress: remote, remotePort: 443)
    var f = Flow(key: key, interface: "en0", at: t0)
    for (pair, n) in rows { f.tally[pair] = n }
    return f
}

private func proc(_ name: String, eproc: String? = nil) -> ProcessPair {
    ProcessPair(name, 100, eproc, eproc == nil ? nil : 200)
}

private func classify(_ f: Flow) -> Classification { Classifier.classify(f) }

@Test func appProcessIsApp() {
    let c = classify(flow([(proc("TikTok"), 5)]))
    #expect(c == Classification(category: .app, rule: "app.process"))
}

@Test func effectiveProcessMakesHelper() {
    let c = classify(flow([(proc("com.apple.WebKit", eproc: "MobileSafari"), 5)]))
    #expect(c == Classification(category: .helper, rule: "helper.eproc"))
}

@Test func onBehalfOfSystemIsHelper() {
    let c = classify(flow([(proc("mDNSResponder", eproc: "TikTok"), 5)]))
    #expect(c == Classification(category: .helper, rule: "helper.eproc"))
}

@Test func systemProcessIsSystem() {
    let c = classify(flow([(proc("apsd"), 5)]))
    #expect(c == Classification(category: .system, rule: "system.process"))
}

@Test func noProcessPublicAddressIsUnknown() {
    let c = classify(flow([(.none, 5)]))
    #expect(c == Classification(category: .unknown, rule: "unknown.noProcess"))
}

@Test func heartbeatdIsDeviceLink() {
    let hb: IPAddress = .v6(hi: 0xFD5D_0000_0000_0000, lo: 1)
    let me: IPAddress = .v6(hi: 0xFD5D_0000_0000_0000, lo: 2)
    let c = classify(flow([(proc("heartbeatd"), 3)], remote: hb, local: me))
    #expect(c == Classification(category: .deviceLink, rule: "deviceLink.process"))
}

@Test func lockdowndIsDeviceLinkEvenToPublicAddress() {
    let c = classify(flow([(proc("lockdownd"), 3)], remote: publicAddress))
    #expect(c == Classification(category: .deviceLink, rule: "deviceLink.process"))
}

@Test func linkLocalWithoutAppEvidenceIsDeviceLink() {
    let c = classify(flow([(.none, 3)], remote: v4(169, 254, 100, 1), local: v4(169, 254, 100, 2)))
    #expect(c == Classification(category: .deviceLink, rule: "deviceLink.linkLocal"))
    // a system process there is moved too
    let s = classify(flow([(proc("apsd"), 3)], remote: v4(169, 254, 100, 1), local: v4(169, 254, 100, 2)))
    #expect(s.rule == "deviceLink.linkLocal")
    // one link-local side is not enough: this one is local-only by address instead
    let one = classify(flow([(.none, 3)], remote: v4(169, 254, 100, 1)))
    #expect(one == Classification(category: .localNetwork, rule: "localNetwork.address"))
}

@Test func mdnsMulticastIsLocalNetwork() {
    let c4 = classify(flow([(.none, 2)], remote: v4(224, 0, 0, 251)))
    #expect(c4 == Classification(category: .localNetwork, rule: "localNetwork.address"))
    let c6 = classify(flow([(.none, 2)], remote: .v6(hi: 0xFF02_0000_0000_0000, lo: 0xFB)))
    #expect(c6 == Classification(category: .localNetwork, rule: "localNetwork.address"))
}

@Test func ssdpAndBroadcastAreLocalNetwork() {
    #expect(classify(flow([(.none, 1)], remote: v4(239, 255, 255, 250))).category == .localNetwork)
    #expect(classify(flow([(.none, 1)], remote: v4(255, 255, 255, 255))).category == .localNetwork)
}

@Test func systemProcessToPrivateAddressIsLocalNetwork() {
    let c = classify(flow([(proc("rapportd"), 4)], remote: v4(192, 168, 1, 5)))
    #expect(c == Classification(category: .localNetwork, rule: "localNetwork.address"))
}

@Test func appToPrivateAddressStaysApp() {
    let c = classify(flow([(proc("Notes"), 4)], remote: v4(10, 0, 0, 8)))
    #expect(c == Classification(category: .app, rule: "app.process"))
}

@Test func helperToLinkLocalStaysHelper() {
    let c = classify(flow([(proc("mDNSResponder", eproc: "TikTok"), 4)], remote: v4(169, 254, 1, 1)))
    #expect(c == Classification(category: .helper, rule: "helper.eproc"))
    // also with both addresses link-local
    let both = classify(
        flow([(proc("mDNSResponder", eproc: "TikTok"), 4)], remote: v4(169, 254, 1, 1), local: v4(169, 254, 1, 2)))
    #expect(both.category == .helper)
}

@Test func appNamedLikeDeviceLinkProcessOnlyIfAllowlisted() {
    #expect(classify(flow([(proc("heartbeat"), 4)])).category == .app)
    #expect(classify(flow([(proc("lockdown"), 4)])).category == .app)
}

@Test func deviceLinkProcessWinsOverAddressAndEprocOnlyAsWinningRow() {
    // an app-heavy flow with a little heartbeatd stays app
    let c = classify(flow([(proc("TikTok"), 50), (proc("heartbeatd"), 1)]))
    #expect(c.category == .app)
}

@Test func cgnatAddressIsNotLocal() {
    let c = classify(flow([(.none, 2)], remote: v4(100, 64, 0, 1)))
    #expect(c == Classification(category: .unknown, rule: "unknown.noProcess"))
}

@Test func addressRangeEdges() {
    #expect(!v4(172, 15, 255, 255).isLocalOnly)
    #expect(v4(172, 16, 0, 0).isLocalOnly)
    #expect(v4(172, 31, 255, 255).isLocalOnly)
    #expect(!v4(172, 32, 0, 0).isLocalOnly)
    #expect(v4(169, 254, 0, 0).isLinkLocal && v4(169, 254, 255, 255).isLinkLocal)
    #expect(!v4(169, 253, 255, 255).isLinkLocal && !v4(169, 255, 0, 0).isLinkLocal)
    #expect(v4(10, 0, 0, 0).isLocalOnly && v4(10, 255, 255, 255).isLocalOnly)
    #expect(!v4(9, 255, 255, 255).isLocalOnly && !v4(11, 0, 0, 0).isLocalOnly)
    #expect(v4(192, 168, 0, 0).isLocalOnly && v4(192, 168, 255, 255).isLocalOnly)
    #expect(!v4(192, 167, 255, 255).isLocalOnly && !v4(192, 169, 0, 0).isLocalOnly)
    #expect(v4(127, 0, 0, 1).isLocalOnly && !v4(126, 255, 255, 255).isLocalOnly && !v4(128, 0, 0, 0).isLocalOnly)
    #expect(v4(224, 0, 0, 0).isLocalOnly && v4(239, 255, 255, 255).isLocalOnly)
    #expect(!v4(223, 255, 255, 255).isLocalOnly && !v4(240, 0, 0, 0).isLocalOnly)
    #expect(v4(255, 255, 255, 255).isLocalOnly && !v4(255, 255, 255, 254).isLocalOnly)
    #expect(!v4(100, 64, 0, 1).isLocalOnly && !v4(192, 0, 2, 1).isLocalOnly)

    func v6(_ hi: UInt64, _ lo: UInt64 = 1) -> IPAddress { .v6(hi: hi, lo: lo) }
    #expect(v6(0xFE80_0000_0000_0000).isLinkLocal)
    #expect(v6(0xFEBF_0000_0000_0000).isLinkLocal)
    #expect(!v6(0xFEC0_0000_0000_0000).isLinkLocal && !v6(0xFEC0_0000_0000_0000).isLocalOnly)
    #expect(!v6(0xFE7F_FFFF_FFFF_FFFF).isLinkLocal)
    #expect(v6(0xFF02_0000_0000_0000, 0xFB).isLocalOnly && v6(0xFF00_0000_0000_0000, 0).isLocalOnly)
    #expect(v6(0, 1).isLocalOnly && !v6(0, 2).isLocalOnly && !v6(0, 0).isLocalOnly)
    #expect(v6(0xFC00_0000_0000_0000).isLocalOnly && v6(0xFD5D_0000_0000_0000).isLocalOnly)
    #expect(!v6(0xFB00_0000_0000_0000).isLocalOnly && !v6(0xFE00_0000_0000_0000).isLocalOnly)
    #expect(!v6(0x2001_0DB8_0000_0000, 5).isLocalOnly)
}

@Test func everyCategoryHasLabelAndFlag() {
    let labels: [TrafficCategory: String] = [
        .app: "From app", .helper: "Helper for an app", .system: "iOS system",
        .deviceLink: "USB link to this Mac", .localNetwork: "Local network only", .unknown: "No process info",
    ]
    #expect(TrafficCategory.allCases.count == 6)
    for c in TrafficCategory.allCases { #expect(c.label == labels[c]) }
    let phoneTraffic = Set(TrafficCategory.allCases.filter(\.isPhoneTraffic))
    #expect(phoneTraffic == [.app, .helper, .system, .unknown])
    #expect(TrafficCategory.allCases.map(\.rawValue) == ["app", "helper", "system", "deviceLink", "localNetwork", "unknown"])
}

@Test func ruleNamesAreStable() {
    #expect(
        [
            ClassifierRule.deviceLinkProcess, ClassifierRule.appProcess, ClassifierRule.helperEproc,
            ClassifierRule.deviceLinkLinkLocal, ClassifierRule.localNetworkAddress,
            ClassifierRule.systemProcess, ClassifierRule.unknownNoProcess,
        ] == [
            "deviceLink.process", "app.process", "helper.eproc", "deviceLink.linkLocal",
            "localNetwork.address", "system.process", "unknown.noProcess",
        ])
}

@Test func neverMovesAppTaggedFlow() {
    let remotes: [IPAddress] = [
        v4(10, 0, 0, 8), v4(169, 254, 1, 1), v4(224, 0, 0, 251), v4(127, 0, 0, 1), v4(255, 255, 255, 255),
        .v6(hi: 0xFE80_0000_0000_0000, lo: 1), .v6(hi: 0xFF02_0000_0000_0000, lo: 0xFB),
        .v6(hi: 0xFD00_0000_0000_0000, lo: 1),
    ]
    for remote in remotes {
        for local in [phone, v4(169, 254, 1, 2), .v6(hi: 0xFE80_0000_0000_0000, lo: 2)] {
            let app = classify(flow([(proc("Notes"), 3)], remote: remote, local: local))
            #expect(app.category == .app)
            let helper = classify(flow([(proc("mDNSResponder", eproc: "Notes"), 3)], remote: remote, local: local))
            #expect(helper.category == .helper)
        }
    }
}

@Test func corpusHeartbeatAndMdnsFlows() {
    // mirrors F4 (heartbeatd to fd5d::1) and F5 (no process to 224.0.0.251) of the synthetic corpus
    let f4 = flow(
        [(ProcessPair("heartbeatd", 98, nil, nil), 3)],
        remote: .v6(hi: 0xFD5D_0000_0000_0000, lo: 1), local: .v6(hi: 0xFD5D_0000_0000_0000, lo: 2))
    #expect(classify(f4).category == .deviceLink)
    let f5 = flow([(.none, 2)], remote: v4(224, 0, 0, 251))
    #expect(classify(f5).category == .localNetwork)
}

// evidence 2026-11-18, see md/milestone2/BASELINE.md
@Test func allowlist_attributionkitd() {
    #expect(classify(flow([(proc("attributionkitd"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("attributionkit"), 5)])).category == .app)
}

// evidence 2026-11-18, see md/milestone2/BASELINE.md
@Test func allowlist_mapspushd() {
    #expect(classify(flow([(proc("mapspushd"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("mapspush"), 5)])).category == .app)
}

// evidence 2026-11-18, see md/milestone2/BASELINE.md
@Test func allowlist_fitcored() {
    #expect(classify(flow([(proc("fitcored"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("fitcore"), 5)])).category == .app)
}

// evidence 2026-11-18, see md/milestone2/BASELINE.md
@Test func allowlist_mobileassetd() {
    #expect(classify(flow([(proc("mobileassetd"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("mobileasset"), 5)])).category == .app)
}

// evidence 2026-11-18 (PH-5), see md/milestone2/BASELINE.md
@Test func allowlist_mdmd() {
    #expect(classify(flow([(proc("mdmd"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("mdm"), 5)])).category == .app)
}

// evidence 2026-11-18 (PH-5), see md/milestone2/BASELINE.md
@Test func allowlist_webprivacyd() {
    #expect(classify(flow([(proc("webprivacyd"), 5)])) == Classification(category: .system, rule: "system.process"))
    // the name never matches as a prefix or in an app's cut form
    #expect(classify(flow([(proc("webprivacy"), 5)])).category == .app)
}
