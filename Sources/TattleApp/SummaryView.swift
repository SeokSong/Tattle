import Companies
import Summary
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHowTo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Summary").font(.largeTitle.bold())
                if model.summaryLoading && model.summaryScreen == nil {
                    ProgressView()
                }
                if let screen = model.summaryScreen {
                    if screen.isEmpty {
                        Text(SummaryScreen.emptyText).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(screen.overview, id: \.self) { Bullet(text: $0).font(.title3) }
                        }
                        if !screen.tips.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(SummaryScreen.tipsHeading).font(.caption.bold()).foregroundStyle(.secondary)
                                ForEach(Array(screen.tips.enumerated()), id: \.offset) { Bullet(text: $0.element) }
                            }
                        }
                        HStack(spacing: 16) {
                            Button(SummaryScreen.howToReadHeading) { showHowTo = true }
                            if screen.hasCaptures {
                                Toggle(SummaryScreen.dataAmountsToggle, isOn: $model.showDataAmounts)
                            }
                        }
                        ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            SummaryRowView(row: row, showData: model.showDataAmounts && screen.hasCaptures)
                        }
                        if let noProcess = screen.noProcess {
                            Text(noProcess).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button { model.refreshSummary() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.summaryLoading)
            }
        }
        .onAppear { model.refreshSummary() }
        .sheet(isPresented: $showHowTo) { HowToReadView() }
    }
}

/// one bullet: a dot and the text, wrapping under the text
struct Bullet: View {
    let text: String
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).help(help ?? "")
        }
    }
}

/// a bullet with an (i) button that opens its explanation
struct InfoBullet: View {
    let text: String
    let detail: String?
    @State private var show = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Bullet(text: text)
            if let detail {
                Button { show.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(detail)
                    .popover(isPresented: $show) { Text(detail).padding(12).frame(width: 300) }
            }
        }
    }
}

/// grouped bullets (owner, 2026-11-24): a reader spends 10 to 20 seconds per app at most
struct SummaryRowView: View {
    let row: SummaryRow
    /// 5.2: show each company's share of the app's captured data
    var showData = false
    @State private var expanded = false

    /// screenshots without clicking (6.1): in demo mode only, TATTLE_DEMO_OPEN names a row to open at launch
    private var openedForDemo: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TATTLE_DEMO_SUMMARY"] == "1" && env["TATTLE_DEMO_OPEN"] == row.title
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let description = row.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if !row.trackingCompanies.isEmpty {
                    group(SummaryScreen.trackingHeading) { companies(row.trackingCompanies) }
                }
                if !row.otherCompanies.isEmpty {
                    group(SummaryScreen.otherHeading) { companies(row.otherCompanies) }
                }
                group(SummaryScreen.untracedHeading) { Bullet(text: row.untraced) }
                if !row.traced.isEmpty {
                    group(SummaryScreen.tracedHeading) {
                        ForEach(row.traced) { InfoBullet(text: $0.text, detail: $0.detail) }
                    }
                }
                if let possible = row.possible {
                    InfoBullet(text: possible, detail: SummaryScreen.possibleExplanation)
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !row.children.isEmpty {
                    Text(SummaryScreen.appleAppsBreakdownHeading).font(.caption.bold())
                    ForEach(row.children) { SummaryRowView(row: $0, showData: showData) }
                        .padding(.leading, 12)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
            // the details start under the app name, not centred in the row
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Text(row.title).fontWeight(.semibold)
                    Spacer()
                    Text(row.subtitle).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onAppear { if openedForDemo { expanded = true } }
    }

    private func group<Content: View>(_ heading: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heading).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    /// "where it was seen" is on hover only (owner, 2026-11-24); brands stay visible under the company
    private func companies(_ lines: [CompanyLine]) -> some View {
        ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 1) {
                Bullet(text: showData ? [line.text, line.dataShare].compactMap { $0 }.joined(separator: " · ") : line.text,
                       help: line.seenIn)
                ForEach(line.brands, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).padding(.leading, 14) }
            }
        }
    }
}

struct HowToReadView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SummaryScreen.howToReadHeading).font(.title2.bold())
            ForEach(Glossary.howToRead, id: \.self) { Text($0) }
            ForEach(Glossary.terms, id: \.term) { term in
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.term).fontWeight(.medium)
                    Text(term.text).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
