import Attribution
import Companies
import Domains
import Flows
import Foundation
import Summary
import WorldMap

/// where every line starts. until Part 5 brings the user's own location, the default point is used and always labelled
/// as the default (owner, 2026-11-25)
struct MapStart: Equatable {
    let point: GeoPoint
    let isDefault: Bool

    /// the default start: the city centre of Colorado Springs (owner's choice; only the city centre, never an address)
    static let fallback = MapStart(point: GeoPoint(latitude: 38.8339, longitude: -104.8214), isDefault: true)
}

/// the words under every map
enum MapText {
    static let notServers = "Lines go to company head offices, not to the servers the data went to."
    static let defaultStart = "Default location: Colorado Springs. Allow location in System Settings to start from your place."

    static func notDrawn(_ n: Int) -> String? {
        n == 0 ? nil : n == 1 ? "1 connection is not on the map (company or head office unknown)."
            : "\(n) connections are not on the map (company or head office unknown)."
    }

    static func notDrawnApps(_ n: Int) -> String? {
        n == 0 ? nil : n == 1 ? "1 company is not on the map (head office unknown)." : "\(n) companies are not on the map (head office unknown)."
    }
}

/// turns connections into map lines, off the packet path: it reads the same snapshots the Live tables read, every
/// refresh, and labels names the same way (`FlowLabels`)
@MainActor
final class MapFeed: ObservableObject {
    /// the live capture's lines
    @Published private(set) var live = MapLines()
    /// when each line first appeared, for drawing it in
    @Published private(set) var firstSeen: [String: Date] = [:]
    /// every connection's moment on the map, for its spark; older than a few seconds are dropped
    @Published private(set) var events: [(id: String, time: Date)] = []
    private var seen: Set<UUID> = []
    /// remote ports of name lookups and network set-up, never drawn or counted: DNS, multicast DNS, DHCP
    static let lookupPorts: Set<UInt16> = [53, 5353, 67, 68]
    /// how long a connection with no name yet is tried again before it counts as not drawn
    static let nameWait: TimeInterval = 10

    /// the bundled head offices; nil when they cannot be read (then every connection counts as not drawn)
    nonisolated static let offices: HeadOfficeTable? = try? HeadOfficeTable.loadBundled()

    func reset() {
        live = MapLines()
        firstSeen = [:]
        events = []
        seen = []
    }

    /// the connections new since the last refresh: one line or one spark each. their sparks are spread over the
    /// refresh interval (`spread` seconds from `now`), so they arrive as a stream, not in a burst every 2 seconds
    func ingest(flows: [Flow], dns: [DomainObservation], now: Date, spread: TimeInterval = 2) {
        let fresh = flows.filter { !seen.contains($0.id) }.sorted { $0.firstSeen < $1.firstSeen }
        guard !fresh.isEmpty else { return }
        let index = HostnameIndex(dns, flows: flows)
        var cache = LabelCache()
        for (i, flow) in fresh.enumerated() {
            // link and local traffic is not phone traffic and never goes on the map; nor are name lookups and network
            // set-up (DNS, multicast DNS, DHCP): they ask for a name or an address, they do not reach a company. found in
            // the owner's phone test 2026-11-25: in a test capture 108 of 147 "not on the map" were DNS lookups
            guard Classifier.classify(flow).category.isPhoneTraffic, !Self.lookupPorts.contains(flow.key.remotePort) else {
                seen.insert(flow.id)
                continue
            }
            let label = FlowLabels.label(for: flow, index: index, cache: &cache)
            // a connection can reach the snapshot before its name is read from its first packets: it is tried again
            // at the next refresh, and counted as not drawn only once it is closed or `nameWait` old (found in the
            // owner's phone test 2026-11-25: lines appeared only after Stop)
            if label == nil, flow.endReason == nil, now.timeIntervalSince(flow.firstSeen) < Self.nameWait { continue }
            seen.insert(flow.id)
            let time = now.addingTimeInterval(spread * Double(i) / Double(fresh.count))
            let place = Self.place(for: label)
            live.add(company: place?.company, place: place?.point, city: place?.city ?? "", country: place?.country ?? "")
            guard let place else { continue }
            let id = MapLines.key(place.point)
            if firstSeen[id] == nil { firstSeen[id] = time }
            events.append((id, time))
        }
        // kept past the camera's quiet time, so it knows when the last connection was
        events.removeAll { now.timeIntervalSince($0.time) > 12 }
    }

    /// the head office behind a connection's label: confirmed names only (owner, 2026-11-25, as in the Summary), the
    /// parent company's office
    nonisolated static func place(for label: FlowLabel?) -> (company: String, point: GeoPoint, city: String, country: String)? {
        guard let label, !label.isPossible else { return nil }
        guard let parent = label.label.parent ?? label.label.company, let office = offices?.office(forParent: parent) else { return nil }
        return (parent, GeoPoint(latitude: office.latitude, longitude: office.longitude), office.city, office.country)
    }

    /// the Summary's lines: one per head office, brighter the more apps contacted it (owner, 2026-11-25). the merged
    /// Apple apps card counts each app inside it
    /// demo screenshots only (`TATTLE_DEMO_MAP=1`): made-up apps contacting real public companies, so the map has
    /// lines; the demo Summary's own companies are made up and have no head office
    nonisolated static func demoLines() -> (lines: MapLines, notDrawn: Int) {
        let apps: [[String]] = [
            ["Alphabet", "Meta Platforms", "AppLovin", "Criteo"], ["Alphabet", "Amazon", "Cloudflare"], ["Apple", "Alphabet"],
            ["ByteDance", "Alphabet", "AppLovin"], ["Spotify", "Alphabet", "Amazon"], ["Snap", "Adform", "Alphabet"],
            ["Microsoft", "Atlassian"], ["Tencent", "Yandex"],
        ]
        func row(_ i: Int, _ parents: [String]) -> SummaryRow {
            SummaryRow(id: "demo.app\(i)", kind: .app, title: "App \(i)", subtitle: "", description: nil, trackingCompanies: [],
                       otherCompanies: parents.map { CompanyLine(parent: $0, text: $0, brands: [], seenIn: "") }, untraced: "",
                       traced: [], possible: nil, children: [])
        }
        return summaryLines(SummaryScreen(overview: [], rows: apps.enumerated().map { row($0.offset, $0.element) }, noProcess: nil))
    }

    nonisolated static func summaryLines(_ screen: SummaryScreen?) -> (lines: MapLines, notDrawn: Int) {
        var lines = MapLines()
        var unknown: Set<String> = []
        guard let screen else { return (lines, 0) }
        let apps = screen.rows.flatMap { $0.children.isEmpty ? [$0] : $0.children }
        for app in apps {
            for company in Set((app.trackingCompanies + app.otherCompanies).map(\.parent)) {
                guard let office = offices?.office(forParent: company) else { unknown.insert(company); continue }
                lines.add(company: company, place: GeoPoint(latitude: office.latitude, longitude: office.longitude),
                          city: office.city, country: office.country)
            }
        }
        return (lines, unknown.count)
    }
}
