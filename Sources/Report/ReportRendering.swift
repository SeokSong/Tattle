import Attribution
import Foundation

// text form of a report. same numbers as the JSON; names only when the report has detail.
public enum ReportRendering {
    public static func text(_ report: QualityReport) -> String {
        var lines: [String] = []
        lines.append("Quality report (version \(report.reportVersion), Watch \(report.watchVersion))")
        lines.append("")
        lines.append("flows \(report.totals.flows)  packets \(report.totals.packets)  ip bytes \(report.totals.ipBytes)")
        for (name, bytes) in report.byInterface.sorted(by: { $0.key < $1.key }) {
            lines.append("interface \(name)  \(bytes) bytes")
        }
        lines.append("")
        lines.append("Metrics")
        lines.append(metric("attributedShare", report.attribution.attributedShare))
        lines.append(metric("noProcessShare", report.attribution.noProcessShare))
        lines.append(metric("unknownShare", report.categories.unknownShare))
        lines.append("  (unknownShare can be lower because rules reclassify)")
        lines.append(metric("mixedFlowShare", report.attribution.mixedFlowShare))
        lines.append(metric("hostnameCoverageSniOnly", report.hostnames.hostnameCoverageSniOnly))
        lines.append("")
        lines.append("Categories")
        for cat in TrafficCategory.allCases {
            guard let l = report.categories.byCategory[cat.rawValue] else { continue }
            let value = l.share.value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
            lines.append("\(cat.rawValue)  \(cat.label)  \(l.ipBytes) bytes  \(value)  \(l.packets) packets  \(l.flows) flows")
        }
        lines.append(metric("phoneTrafficShare", report.categories.phoneTrafficShare))
        lines.append(metric("systemTopProcessShare", report.categories.systemTopProcessShare))
        for (rule, bytes) in report.categories.rules.sorted(by: { $0.key < $1.key }) {
            lines.append("rule \(rule)  \(bytes) bytes")
        }
        for (cat, bytes) in report.categories.movedOutOfAppBytes.sorted(by: { $0.key < $1.key }) {
            lines.append("movedOutOfAppBytes \(cat)  \(bytes) bytes")
        }
        lines.append("")
        lines.append("Checks: \(report.reconciliation.ok ? "all passed" : "FAILED")")
        for c in report.reconciliation.checks {
            lines.append("\(c.ok ? "PASS" : "FAIL")  \(c.name)  (expected \(c.expected), actual \(c.actual))")
        }
        if let detail = report.detail {
            lines.append("")
            lines.append("Top processes")
            for p in detail.topProcesses {
                lines.append("\(p.name)  \(p.ipBytes) bytes  \(p.flows) flows")
            }
            for (title, group) in [("System processes", detail.systemProcesses), ("Device link processes", detail.deviceLinkProcesses)]
            where !group.isEmpty {
                lines.append("")
                lines.append(title)
                for p in group { lines.append("\(p.name)  \(p.ipBytes) bytes  \(p.flows) flows") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `name  value%  (numerator / denominator)`; value is n/a when the denominator is 0
    static func metric(_ name: String, _ r: Ratio) -> String {
        let value = r.value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        return "\(name)  \(value)  (\(r.numerator) / \(r.denominator))"
    }
}
