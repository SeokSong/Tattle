import CryptoKit
import Foundation
import Testing
import Companies

// plain import (no @testable) so these also run under `swift test -c release`

@Test func ordinaryDomain() {
    #expect(registrableDomain(of: "a.b.example.com") == "example.com")
    #expect(registrableDomain(of: "example.com") == "example.com")
}

@Test func multiLabelSuffix() {
    #expect(registrableDomain(of: "x.example.co.uk") == "example.co.uk")
    #expect(registrableDomain(of: "example.co.uk") == "example.co.uk")
}

@Test func wildcardAndException() {
    // *.ck makes "b.ck" a suffix; !www.ck carves www.ck back out
    #expect(registrableDomain(of: "a.b.ck") == "a.b.ck")
    #expect(registrableDomain(of: "b.ck") == nil)
    #expect(registrableDomain(of: "www.ck") == "www.ck")
    #expect(registrableDomain(of: "x.www.ck") == "www.ck")
    // *.kawasaki.jp with !city.kawasaki.jp
    #expect(registrableDomain(of: "x.foo.kawasaki.jp") == "x.foo.kawasaki.jp")
    #expect(registrableDomain(of: "a.city.kawasaki.jp") == "city.kawasaki.jp")
}

@Test func icannOnly() {
    // github.io is in the private section; the answer comes from the icann rule for io
    #expect(registrableDomain(of: "x.github.io") == "github.io")
    #expect(registrableDomain(of: "a.b.blogspot.com") == "blogspot.com")
    #expect(registrableDomain(of: "github.io") == "github.io")
}

@Test func unknownSuffixUsesDefaultRule() {
    #expect(registrableDomain(of: "a.b.example.notatld") == "example.notatld")
}

@Test func ipLiteralAndSingleLabelAreNil() {
    for name in ["192.168.1.1", "10.0.0.1.", "::1", "[2001:db8::1]", "fe80::1%en0", "localhost", "com", "", ".", "1.2"] {
        #expect(registrableDomain(of: name) == nil, "\(name)")
    }
}

@Test func emptyLabelsAndLongNamesAreNil() {
    #expect(registrableDomain(of: "a..example.com") == nil)
    #expect(registrableDomain(of: ".example.com") == nil)
    #expect(registrableDomain(of: "example.com..") == nil)
    #expect(registrableDomain(of: String(repeating: "a.", count: 130) + "com") == nil)
}

@Test func trailingDotAndCaseNormalised() {
    #expect(registrableDomain(of: "WWW.Example.COM.") == "example.com")
    #expect(registrableDomain(of: "A.B.Example.Co.UK") == "example.co.uk")
}

@Test func suffixItselfIsNil() {
    #expect(registrableDomain(of: "co.uk") == nil)
    #expect(registrableDomain(of: "uk") == nil)
    #expect(registrableDomain(of: "co.uk.") == nil)
}

@Test func internationalised() {
    // the list holds 公司.cn in unicode; its punycode form must match it
    #expect(registrableDomain(of: "shop.example.xn--55qx5d.cn") == "example.xn--55qx5d.cn")
    #expect(registrableDomain(of: "xn--55qx5d.cn") == nil)
    #expect(registrableDomain(of: "shop.example.公司.cn") == "example.公司.cn")
    // a punycode label that is not a suffix is returned as given
    #expect(registrableDomain(of: "www.xn--bcher-kva.example") == "xn--bcher-kva.example")
    // malformed punycode does not crash and falls back to the label as written
    #expect(registrableDomain(of: "a.xn--.example.com") == "example.com")
}

@Test func manifestMatchesFile() throws {
    let manifest = try DatasetManifest.load()
    let entry = try #require(manifest.datasets.first { $0.file == "psl.dat" })
    let url = try #require(DatasetManifest.resourceURL("psl.dat"))
    let data = try Data(contentsOf: url)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(hash == entry.sha256)
    #expect(entry.licence == "MPL-2.0")
    #expect(entry.sourceURL.hasPrefix("https://publicsuffix.org/"))
    #expect(PublicSuffixList.bundled.ruleCount == entry.rules)
    let notices = try #require(DatasetManifest.resourceURL("NOTICES.txt"))
    let text = try String(contentsOf: notices, encoding: .utf8)
    #expect(text.contains("Mozilla Public License") && text.contains(entry.sourceURL))
}

@Test func bundledListIsLoaded() {
    #expect(PublicSuffixList.bundled.isLoaded)
}

// resident footprint in bytes (phys_footprint); information only
private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

@Test func loadCostIsPrinted() throws {
    let url = try #require(DatasetManifest.resourceURL("psl.dat"))
    let before = footprint()
    let start = DispatchTime.now().uptimeNanoseconds
    // parse a fresh copy: the shared one may already be loaded by another test
    let text = try String(contentsOf: url, encoding: .utf8)
    let list = PublicSuffixList(contents: text)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    let added = max(0, footprint() - before)
    print("companies: psl cold load \(String(format: "%.1f", ms)) ms, \(list.ruleCount) rules, added memory \(added) bytes, data \(text.utf8.count) bytes")
    #expect(list.isLoaded)
    #expect(ms < 200)
    // data budget from md/COMPANIES.md. memory is printed, not asserted: the footprint is
    // process-wide and other tests running in parallel inflate it
    #expect(text.utf8.count <= 3_000_000)
}
