// head offices for the company map (Milestone 4, Part 1). developer-only: the app never fetches anything.
//
// usage: swift scripts/hq-data.swift fetch   asks Wikidata (CC0) for each parent company's head office; saves the raw
//                                            answers outside the repo (network: query.wikidata.org only)
//        swift scripts/hq-data.swift build   offline: picks one head office per parent, writes
//                                            Sources/Companies/Resources/hq.tsv (curated parents, MIT) and
//                                            tracker/hq.tsv (AdGuard companies, CC BY-SA), and a review list outside the repo
// env:   TATTLE_HQ_DIR       raw answers and the review list (default ~/dev/tattle-fixtures/hq, mode 700)
//        TATTLE_TRACKER_LIST the pinned AdGuard copy with companies.json (default ~/dev/tattle-fixtures/tracker-list)
//
// which parents: every curated parent, and every AdGuard company that is not an alias of a curated parent
// (the same parent names the Summary counts). matching: curated parents are pinned by hand to a Wikidata item or a
// place (Resources/hq-pins.tsv; `suggest` lists candidates); AdGuard companies only by their website (AdGuard's
// websiteUrl) against Wikidata's official website (P856). name matching was dropped: it found Apple Records for Apple.
// head office: P159, its own coordinates qualifier (P625) or else the place's coordinates; country is the place's P17.
// a parent goes to the review list (owner checks) when: no head office, several current head offices, several
// Wikidata items, a head office that started in the last 2 years, a match whose name differs, or a hand place.
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)   // progress shows at once when written to a file

let fm = FileManager.default
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let res = repo.appendingPathComponent("Sources/Companies/Resources")
let env = ProcessInfo.processInfo.environment
let home = fm.homeDirectoryForCurrentUser.path
let hqDir = URL(fileURLWithPath: env["TATTLE_HQ_DIR"] ?? "\(home)/dev/tattle-fixtures/hq")
let trackerDir = URL(fileURLWithPath: env["TATTLE_TRACKER_LIST"] ?? "\(home)/dev/tattle-fixtures/tracker-list")

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func tsv(_ name: String) -> [[String]] {
    guard let text = try? String(contentsOf: res.appendingPathComponent(name), encoding: .utf8) else { fail("no \(name)") }
    return text.split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
}

// MARK: the parents and their websites
struct Parent { let name: String; let curated: Bool; var websites: [String] }

func parents() -> [Parent] {
    let curated = Set(tsv("curated.tsv").map { $0[2] })
    let aliased = Set(tsv("tracker-owner-aliases.tsv").map { $0[0] })
    let adguard = Set(tsv("tracker/tracker.tsv").map { $0[1] }.filter { !$0.isEmpty && !aliased.contains($0) && !curated.contains($0) })
    guard let data = try? Data(contentsOf: trackerDir.appendingPathComponent("companies.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let companies = json["companies"] as? [String: [String: Any]] else { fail("no companies.json in \(trackerDir.path)") }
    var site: [String: [String]] = [:]
    for c in companies.values {
        guard let name = (c["name"] as? String)?.trimmingCharacters(in: .whitespaces), let url = c["websiteUrl"] as? String, !url.isEmpty else { continue }
        site[name, default: []].append(url)
    }
    // a curated parent's website: AdGuard's entry under the same name or one of its aliases
    // a curated parent uses only the AdGuard entry with its own exact name: a brand's website finds the brand, not the
    // parent (an alias's site matched Intuit to Mailchimp)
    return curated.sorted().map { Parent(name: $0, curated: true, websites: site[$0] ?? []) }
        + adguard.sorted().map { Parent(name: $0, curated: false, websites: site[$0] ?? []) }
}

/// hq-pins.tsv: parent, wikidata, city, country, latitude, longitude, note. a hand place (city filled) wins over
/// Wikidata: used when Wikidata has no head office, gives only a legal registration address, or has no item
struct Pin { let item: String; let city: String; let country: String; let lat: Double?; let lon: Double?; let note: String }
func pins() -> [String: Pin] {
    var out: [String: Pin] = [:]
    for (i, f) in tsv("hq-pins.tsv").enumerated() {
        guard f.count == 7, !f[0].isEmpty, out[f[0]] == nil else { fail("hq-pins.tsv line \(i + 2): wrong columns or a repeated parent") }
        guard f[1].isEmpty || f[1].range(of: "^Q[0-9]+$", options: .regularExpression) != nil else { fail("hq-pins.tsv line \(i + 2): not a Wikidata item") }
        let hand = !f[2].isEmpty
        guard hand || !f[1].isEmpty, !hand || (Double(f[4]) != nil && Double(f[5]) != nil) else { fail("hq-pins.tsv line \(i + 2): needs an item or a place with coordinates") }
        out[f[0]] = Pin(item: f[1], city: f[2], country: f[3], lat: Double(f[4]), lon: Double(f[5]), note: f[6])
    }
    return out
}

/// the spellings of one website that Wikidata may hold as P856
func variants(_ url: String) -> [String] {
    guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return [] }
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    // only plain host names can go into the query as IRIs
    guard bare.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return [] }
    return ["http", "https"].flatMap { scheme in [bare, "www." + bare].flatMap { h in ["\(scheme)://\(h)", "\(scheme)://\(h)/"] } }
}

// MARK: fetch
let fields = """
  OPTIONAL { ?item p:P159 ?st . ?st ps:P159 ?hq ; wikibase:rank ?rank .
    OPTIONAL { ?st pq:P625 ?qcoord } OPTIONAL { ?st pq:P580 ?start } OPTIONAL { ?st pq:P582 ?end }
    OPTIONAL { ?hq wdt:P625 ?coord } OPTIONAL { ?hq wdt:P17 ?country } }
  OPTIONAL { ?item wikibase:sitelinks ?links }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
"""
let select = "SELECT ?key ?item ?itemLabel ?hq ?hqLabel ?country ?countryLabel ?coord ?qcoord ?start ?end ?rank ?links WHERE {"

/// each answer is cached under the hash of its query, so a rerun after a timeout only asks what is missing
func query(_ sparql: String) -> Data {
    let cache = hqDir.appendingPathComponent("cache", isDirectory: true)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = cache.appendingPathComponent(SHA256.hash(data: Data(sparql.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    if let saved = try? Data(contentsOf: file) { return saved }
    let answer = ask(sparql)
    try? answer.write(to: file, options: .atomic)
    return answer
}

func ask(_ sparql: String) -> Data {
    var c = URLComponents(string: "https://query.wikidata.org/sparql")!
    c.queryItems = [URLQueryItem(name: "query", value: sparql), URLQueryItem(name: "format", value: "json")]
    var req = URLRequest(url: c.url!, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.httpBody = c.percentEncodedQuery!.data(using: .utf8)
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    // a generic client name: no personal details in requests to outside services
    req.setValue("TattleHQBuild/1.0 (developer script for an offline company map)", forHTTPHeaderField: "User-Agent")
    req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
    for attempt in 1...(Int(env["TATTLE_HQ_ATTEMPTS"] ?? "") ?? 4) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?) = (nil, nil)
        var failure = ""
        URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r); failure = e.map { ($0 as NSError).localizedDescription } ?? ""; sem.signal() }.resume()
        sem.wait()
        if let d = out.0, (out.1 as? HTTPURLResponse)?.statusCode == 200 { return d }
        let code = (out.1 as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write(Data("query failed (HTTP \(code)) \(failure), attempt \(attempt)\n".utf8))
        Thread.sleep(forTimeInterval: Double(attempt * 10))
    }
    fail("Wikidata did not answer; nothing was overwritten")
}

func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

func fetch() {
    try? fm.createDirectory(at: hqDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let all = parents()
    var byURL: [(String, String)] = []   // (variant, parent)
    // websites for AdGuard companies only: curated parents are pinned by hand (hq-pins.tsv)
    for p in all where !p.curated { for w in p.websites { for v in variants(w) { byURL.append((v, p.name)) } } }
    var batches: [Data] = []
    let size = Int(env["TATTLE_HQ_BATCH"] ?? "") ?? 40
    for start in stride(from: 0, to: byURL.count, by: size) {
        let chunk = byURL[start..<min(start + size, byURL.count)]
        let values = chunk.map { "(<\($0.0)> \"\(esc($0.1))\")" }.joined(separator: " ")
        batches.append(query("\(select) VALUES (?url ?key) { \(values) } ?item wdt:P856 ?url .\n\(fields) }"))
        print("websites: \(min(start + size, byURL.count)) of \(byURL.count)")
        Thread.sleep(forTimeInterval: 1)
    }
    // the pinned items of curated parents (owner, 2026-11-25: matching by name picked Apple Records for Apple)
    let pinned = pins().filter { !$0.value.item.isEmpty }.sorted { $0.key < $1.key }
    for start in stride(from: 0, to: pinned.count, by: 40) {
        let chunk = pinned[start..<min(start + 40, pinned.count)]
        let values = chunk.map { "(wd:\($0.value.item) \"\(esc($0.key))\")" }.joined(separator: " ")
        batches.append(query("\(select) VALUES (?item ?key) { \(values) }\n\(fields) }"))
        print("pins: \(min(start + 40, pinned.count)) of \(pinned.count)")
        Thread.sleep(forTimeInterval: 1)
    }
    // websites first, then pins; build tells them apart by the order recorded here
    let out = hqDir.appendingPathComponent("wikidata.json")
    let wrapped: [String: Any] = [
        "fetched": ISO8601DateFormatter().string(from: Date()).prefix(10).description,
        "websiteBatches": (0..<(byURL.isEmpty ? 0 : (byURL.count + size - 1) / size)).count,
        "batches": batches.map { String(decoding: $0, as: UTF8.self) },
    ]
    let data = try! JSONSerialization.data(withJSONObject: wrapped)
    try! data.write(to: out, options: .atomic)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
    print("saved \(out.path)")
}

// MARK: build
struct Statement { let item: String; let itemLabel: String; let hq: String; let hqLabel: String; let country: String
    let lat: Double?; let lon: Double?; let start: String?; let ended: Bool; let rank: String; let links: Int }

func point(_ wkt: String?) -> (Double, Double)? {
    guard let wkt, wkt.hasPrefix("Point(") else { return nil }
    let n = wkt.dropFirst(6).dropLast().split(separator: " ").compactMap { Double($0) }
    return n.count == 2 ? (n[1], n[0]) : nil
}

/// writes one head-office file and its manifest entry, the same way scripts/build-tracker-list.sh writes its own
/// (jq keeps the manifest's layout)
func write(_ lines: [String], file: String, name: String, licence: String, fetched: String) {
    let out = res.appendingPathComponent(file)
    try! (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    let sha = Process()
    sha.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    sha.arguments = ["-a", "256", out.path]
    let pipe = Pipe()
    sha.standardOutput = pipe
    try! sha.run(); sha.waitUntilExit()
    let hash = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    let manifest = res.appendingPathComponent("manifest.json")
    let jq = Process()
    jq.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    jq.arguments = ["jq", "--arg", "d", fetched, "--arg", "sha", hash, "--arg", "file", file, "--arg", "name", name,
                    "--arg", "licence", licence, "--argjson", "rows", String(lines.count - 1), """
      .datasets = (.datasets | map(select(.file != $file))) + [{
        name: $name, file: $file, version: $d, commit: "",
        sourceURL: "https://query.wikidata.org", licence: $licence, fetched: $d,
        sha256: $sha, sourceSHA256: $sha, rules: $rows }]
    """, manifest.path]
    let jqOut = Pipe()
    jq.standardOutput = jqOut
    try! jq.run()
    let updated = jqOut.fileHandleForReading.readDataToEndOfFile()
    jq.waitUntilExit()
    guard jq.terminationStatus == 0, !updated.isEmpty else { fail("jq could not update manifest.json") }
    try! updated.write(to: manifest, options: .atomic)
    print("wrote \(out.path): \(lines.count - 1) head offices")
}

func build() {
    guard let data = try? Data(contentsOf: hqDir.appendingPathComponent("wikidata.json")),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let batches = root["batches"] as? [String], let fetched = root["fetched"] as? String,
          let websiteBatches = root["websiteBatches"] as? Int else { fail("run fetch first") }
    var byWebsite: [String: [Statement]] = [:], byPin: [String: [Statement]] = [:]
    for (i, text) in batches.enumerated() {
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let rows = (j["results"] as? [String: Any])?["bindings"] as? [[String: [String: String]]] else { fail("batch \(i) is not SPARQL JSON") }
        for r in rows {
            guard let key = r["key"]?["value"], let item = r["item"]?["value"] else { continue }
            let c = point(r["qcoord"]?["value"]) ?? point(r["coord"]?["value"])
            let s = Statement(item: String(item.split(separator: "/").last ?? ""), itemLabel: r["itemLabel"]?["value"] ?? "",
                              hq: r["hq"]?["value"] ?? "", hqLabel: r["hqLabel"]?["value"] ?? "", country: r["countryLabel"]?["value"] ?? "",
                              lat: c?.0, lon: c?.1, start: r["start"]?["value"], ended: r["end"] != nil,
                              rank: String((r["rank"]?["value"] ?? "").split(separator: "#").last ?? ""), links: Int(r["links"]?["value"] ?? "") ?? 0)
            if i < websiteBatches { byWebsite[key, default: []].append(s) } else { byPin[key, default: []].append(s) }
        }
    }
    let recent = Calendar(identifier: .gregorian).date(byAdding: .year, value: -2, to: Date())!
    func norm(_ s: String) -> String {
        var t = s.lowercased()
        for suffix in [", inc.", " inc.", " inc", " ltd.", " ltd", " llc", " corporation", " corp.", " gmbh", " s.a.", " ag", " plc", " limited", " co."] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t.filter { $0.isLetter || $0.isNumber }
    }
    // two files (owner, 2026-11-25): curated parents in hq.tsv (our selection, MIT); AdGuard companies in tracker/hq.tsv,
    // because which companies are listed comes from AdGuard, so that file stays CC BY-SA with the rest of the folder
    let header = "parent\tcity\tcountry\tlatitude\tlongitude\twikidata\tmatch"
    var curatedLines = [header], adguardLines = [header]
    var review = ["parent\tlist\treason\twikidata\tchosen head office"]
    var counts = (curated: 0, curatedHQ: 0, adguard: 0, adguardHQ: 0)
    let allPins = pins()
    for p in parents() {
        if p.curated { counts.curated += 1 } else { counts.adguard += 1 }
        let list = p.curated ? "curated" : "AdGuard"
        // statements with a head office that has not ended; the website match first, the name when it gives none
        // a head office that is a whole country (Wikidata lists one beside the city sometimes) is too coarse for a line
        func usable(_ list: [Statement]) -> [Statement] {
            list.filter { !$0.hq.isEmpty && !$0.ended && $0.rank != "DeprecatedRank" && $0.hqLabel != $0.country }
        }
        // curated: the pinned item, or the hand place; AdGuard: website matches only (owner, 2026-11-25)
        if p.curated {
            guard let pin = allPins[p.name] else {
                review.append("\(p.name)\t\(list)\tnot pinned: no Wikidata item found\t\t")
                continue
            }
            if !pin.city.isEmpty, let lat = pin.lat, let lon = pin.lon {
                counts.curatedHQ += 1
                curatedLines.append([p.name, pin.city, pin.country, String(format: "%.4f", lat), String(format: "%.4f", lon),
                                     pin.item.isEmpty ? "none" : pin.item, "hand"].joined(separator: "\t"))
                review.append("\(p.name)\t\(list)\tplace entered by hand: \(pin.note)\t\(pin.item)\t\(pin.city), \(pin.country)")
                continue
            }
        }
        let current = usable(p.curated ? byPin[p.name] ?? [] : byWebsite[p.name] ?? [])
        let how = p.curated ? "pinned" : "website"
        let statements = p.curated ? byPin[p.name] ?? [] : byWebsite[p.name] ?? []
        var reasons: [String] = []
        // several items: the best-known one (most Wikipedia sitelinks) wins; reviewed only when another comes close
        var links: [String: Int] = [:]
        for st in current { links[st.item] = max(links[st.item] ?? 0, st.links) }
        let ranked = links.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if ranked.count > 1, ranked[1].value * 2 >= ranked[0].value {
            reasons.append("several Wikidata items (\(ranked.prefix(4).map { "\($0.key) \($0.value) links" }.joined(separator: ", ")))")
        }
        let item = ranked.first?.key
        let mine = current.filter { $0.item == item }
        let preferred = mine.filter { $0.rank == "PreferredRank" }
        let pick = (preferred.isEmpty ? mine : preferred).filter { $0.lat != nil }
        // several head offices: reviewed only when they are more than 50 km apart (a city and its district are one place)
        func km(_ a: Statement, _ b: Statement) -> Double {
            let r = Double.pi / 180, (la1, la2) = (a.lat! * r, b.lat! * r), dl = (b.lon! - a.lon!) * r
            return 6371 * acos(min(1, sin(la1) * sin(la2) + cos(la1) * cos(la2) * cos(dl)))
        }
        if pick.contains(where: { a in pick.contains { km(a, $0) > 50 } }) {
            reasons.append("several head offices (\(Set(pick.map(\.hqLabel)).sorted().joined(separator: ", ")))")
        }
        guard let hq = pick.sorted(by: { $0.hq < $1.hq }).first ?? mine.first else {
            // no head office: every curated one is reviewed; AdGuard ones are only counted (there are too many small ones)
            if p.curated { review.append("\(p.name)\t\(list)\tno head office in Wikidata\t\(statements.first?.item ?? "")\t") }
            continue
        }
        if let start = hq.start, let d = ISO8601DateFormatter().date(from: start), d > recent { reasons.append("head office since \(start.prefix(10))") }
        let (ours, theirs) = (norm(p.name), norm(hq.itemLabel))
        // an item with no English name shows as its id; that alone is not a doubt about the match
        if hq.itemLabel.range(of: "^Q[0-9]+$", options: .regularExpression) == nil, !(theirs.contains(ours) || ours.contains(theirs)) { reasons.append("Wikidata calls it \(hq.itemLabel)") }
        guard let lat = hq.lat, let lon = hq.lon else {
            review.append("\(p.name)\t\(list)\thead office has no coordinates\t\(hq.item)\t\(hq.hqLabel)")
            continue
        }
        if p.curated { counts.curatedHQ += 1 } else { counts.adguardHQ += 1 }
        let line = [p.name, hq.hqLabel, hq.country, String(format: "%.4f", lat), String(format: "%.4f", lon), hq.item, how].joined(separator: "\t")
        if p.curated { curatedLines.append(line) } else { adguardLines.append(line) }
        if !reasons.isEmpty { review.append("\(p.name)\t\(list)\t\(reasons.joined(separator: "; "))\t\(hq.item)\t\(hq.hqLabel), \(hq.country)") }
    }
    let rev = hqDir.appendingPathComponent("review.tsv")
    try! (review.joined(separator: "\n") + "\n").write(to: rev, atomically: true, encoding: .utf8)
    write(curatedLines, file: "hq.tsv", name: "Company head offices, curated parents (Wikidata)",
          licence: "MIT (own selection; head offices from Wikidata, CC0-1.0)", fetched: fetched)
    write(adguardLines, file: "tracker/hq.tsv", name: "Company head offices, AdGuard companies (Wikidata)",
          licence: "CC-BY-SA-4.0", fetched: fetched)
    print("curated parents with a head office: \(counts.curatedHQ) of \(counts.curated)")
    print("AdGuard companies with a head office: \(counts.adguardHQ) of \(counts.adguard)")
    print("Wikidata answers fetched \(fetched)")
    print("review list: \(review.count - 1) rows in \(rev.path)")
}

// MARK: suggest
/// candidates for pinning curated parents: Wikidata's own search, top 4 per parent with label and description,
/// written outside the repo for a person to choose from. it never writes the pin file
func suggest() {
    try? fm.createDirectory(at: hqDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var out = ["parent\tcandidates (item: label, description)"]
    for p in parents() where p.curated {
        var c = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        c.queryItems = [URLQueryItem(name: "action", value: "wbsearchentities"), URLQueryItem(name: "search", value: p.name),
                        URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "type", value: "item"),
                        URLQueryItem(name: "limit", value: "4"), URLQueryItem(name: "format", value: "json")]
        var req = URLRequest(url: c.url!, timeoutInterval: 60)
        req.setValue("TattleHQBuild/1.0 (developer script for an offline company map)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in body = d; sem.signal() }.resume()
        sem.wait()
        let hits = ((body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["search"] as? [[String: Any]]) ?? []
        let text = hits.map { "\($0["id"] ?? ""): \($0["label"] ?? ""), \($0["description"] ?? "")" }.joined(separator: " | ")
        out.append("\(p.name)\t\(text)")
        Thread.sleep(forTimeInterval: 0.3)
    }
    let file = hqDir.appendingPathComponent("suggestions.tsv")
    try! (out.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    print("wrote \(file.path): \(out.count - 1) parents")
}

switch CommandLine.arguments.dropFirst().first {
case "fetch": fetch()
case "build": build()
case "suggest": suggest()
default: fail("usage: swift scripts/hq-data.swift fetch|build|suggest")
}
