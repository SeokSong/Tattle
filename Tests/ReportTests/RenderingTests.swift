import Foundation
import Testing

@testable import Report

private func report(detail: Bool = false, failing: Bool = false) -> QualityReport {
    QualityReport(
        reportVersion: 1, watchVersion: "test",
        totals: .init(flows: 3, packets: 10, ipBytes: 400),
        byInterface: ["en0": 400],
        attribution: .init(
            attributedShare: Ratio(numerator: 300, denominator: 400),
            noProcessShare: Ratio(numerator: 100, denominator: 400),
            mixedFlowShare: Ratio(numerator: 0, denominator: 0)),
        hostnames: .init(hostnameCoverageSniOnly: Ratio(numerator: 200, denominator: 300)),
        reconciliation: .init(
            ok: !failing,
            checks: [
                .init(name: "interfaceBytes", expected: 400, actual: 400, ok: true),
                .init(name: "flowTimes", expected: 3, actual: failing ? 2 : 3, ok: !failing),
            ]),
        detail: detail ? .init(topProcesses: [.init(name: "Secretapp", flows: 2, ipBytes: 300)]) : nil)
}

@Test func textRenderingShowsDenominators() {
    let text = ReportRendering.text(report())
    #expect(text.contains("300 / 400"))
    #expect(text.contains("n/a"))
    #expect(!text.contains("Secretapp"))
    #expect(ReportRendering.text(report(detail: true)).contains("Secretapp"))
}

@Test func failedCheckShowsFail() {
    let text = ReportRendering.text(report(failing: true))
    #expect(text.contains("FAIL  flowTimes"))
    #expect(text.contains("PASS  interfaceBytes"))
    #expect(!ReportRendering.text(report()).contains("FAIL"))
}

@Test func jsonAndTextAgree() throws {
    let r = report()
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(r.json().utf8)) as? [String: Any])
    let text = ReportRendering.text(r)
    func value(_ group: String, _ key: String) throws -> (Int, Int) {
        let g = try #require(json[group] as? [String: Any])
        let m = try #require(g[key] as? [String: Any])
        return (try #require(m["numerator"] as? Int), try #require(m["denominator"] as? Int))
    }
    for (group, key) in [("attribution", "attributedShare"), ("attribution", "noProcessShare"),
        ("attribution", "mixedFlowShare"), ("hostnames", "hostnameCoverageSniOnly")]
    {
        let (n, d) = try value(group, key)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix(key + "  ") })
        #expect(line.hasSuffix("(\(n) / \(d))"))
    }
}
