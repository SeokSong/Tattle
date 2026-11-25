import Attribution
import Companies
import Domains
import Flows
import Foundation
import Storage
import Summary

enum SummaryLoader {
    /// builds the summary of everything within retention, off the main thread. `excluding` is a capture in progress
    static func load(storePath: URL, retentionDays: Int, now: Date, excluding: UUID?, demo: Bool) throws -> SummaryScreen {
        if demo { return SummaryDemo.screen(now: now) }
        let store = try Store(path: storePath)
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86400)

        // one hostname index per capture: a name seen in one capture never names a flow of another (review of PR #10)
        var sessions: [(flows: [Flow], index: HostnameIndex)] = []
        for session in try store.sessions() where session.id != excluding && (session.endedAt ?? session.startedAt) >= cutoff {
            let flows = try store.flows(session: session.id)
            guard !flows.isEmpty else { continue }
            sessions.append((flows, HostnameIndex(try store.domains(session: session.id), flows: flows)))
        }
        let capture: CaptureSummary? = sessions.isEmpty ? nil : SummaryBuilder.build(sessions: sessions)

        let contacts = try store.contacts(since: cutoff).map {
            ReportContactInput(
                appId: $0.appId, domain: $0.domain, domainOwner: $0.domainOwner, hits: $0.hits,
                firstSeen: $0.firstSeen, lastSeen: $0.lastSeen)
        }
        let report: ReportSummary? = contacts.isEmpty ? nil : ReportSummaryBuilder.build(contacts: contacts)

        return SummaryScreenBuilder.build(
            CombinedSummaryBuilder.build(capture: capture, report: report), timeZone: .current, now: now)
    }
}
