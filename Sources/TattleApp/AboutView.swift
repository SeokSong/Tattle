import Companies
import Storage
import SwiftUI

/// one line per bundled dataset, read from the manifest so a new dataset appears without a code change
struct AboutDataset: Identifiable, Equatable {
    var name: String
    var version: String
    var licence: String
    var sourceURL: String
    var id: String { name }
}

func aboutDatasets(_ manifest: DatasetManifest?) -> [AboutDataset] {
    (manifest?.datasets ?? []).map {
        AboutDataset(name: $0.name, version: $0.version, licence: $0.licence, sourceURL: $0.sourceURL)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let datasets = aboutDatasets(try? DatasetManifest.load())

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About \(AppIdentity.name)").font(.title2.bold())
            Text("Company names on connections come from the lists below, shipped with the app. A name that no list knows is shown as Not identified. A site on a shared hosting service is shown as a website we couldn't identify, never as the service's company.")
                .font(.callout).foregroundStyle(.secondary)
            if datasets.isEmpty {
                Text("The bundled lists could not be read.").foregroundStyle(.secondary)
            }
            ForEach(datasets) { dataset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataset.name).fontWeight(.medium)
                    Text("Version \(dataset.version) · \(dataset.licence)").font(.caption).foregroundStyle(.secondary)
                    if !dataset.sourceURL.isEmpty {
                        Text(dataset.sourceURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Text("The Public Suffix List is used to find the registrable part of a hostname. It is published under the Mozilla Public License 2.0.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Tracker company names come from AdGuard companiesdb, based on Whotracks.me. That data is published under the Creative Commons Attribution-ShareAlike 4.0 licence.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}
