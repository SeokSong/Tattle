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
                        Text(screen.overview.joined(separator: " ")).font(.title3)
                        Button(SummaryScreen.howToReadHeading) { showHowTo = true }
                        ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            SummaryRowView(row: row)
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

struct SummaryRowView: View {
    let row: SummaryRow
    @State private var expanded = false
    @State private var showDetail = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let description = row.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if !row.sentences.isEmpty {
                    Text(row.sentences.joined(separator: " "))
                }
                if let line = row.captureLine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line).font(.callout)
                        if let detail = row.captureDetail {
                            Button { showDetail.toggle() } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless)
                                .help(detail)
                                .popover(isPresented: $showDetail) {
                                    Text(detail).padding(12).frame(width: 300)
                                }
                        }
                    }
                }
                if let line = row.reportLine {
                    Text(line).font(.callout)
                }
                ForEach(row.companies) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                        ForEach(line.brands, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Text(line.seenIn).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !row.possibleNames.isEmpty {
                    Text(SummaryScreen.possibleHeading).font(.caption.bold())
                    Text(row.possibleNames.joined(separator: ", "))
                    Text(SummaryScreen.possibleExplanation).font(.caption).foregroundStyle(.secondary)
                }
                if !row.children.isEmpty {
                    Text(SummaryScreen.appleAppsBreakdownHeading).font(.caption.bold())
                    ForEach(row.children) { SummaryRowView(row: $0) }
                        .padding(.leading, 12)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
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
