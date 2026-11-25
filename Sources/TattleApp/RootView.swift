import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.sidebarItems, selection: Binding(
                get: { Optional(model.selection) }, set: { if let item = $0 { model.selection = item } })
            ) { item in
                Label {
                    Text(item.rawValue)
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item == .live && model.isCapturing ? Color.red : Color.primary)
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch model.selection {
            case .summary: SummaryView()
            case .connect: ConnectView()
            case .live: LiveView()
            case .map: MapScreen()
            case .sessions: SessionsView()
            case .importReport: ImportView(model: model.importModel)
            case .settings: SettingsView()
            }
        }
        .alert("Problem", isPresented: Binding(
            get: { model.storeError != nil }, set: { if !$0 { model.storeError = nil } })
        ) {
            Button("OK") { model.storeError = nil }
        } message: {
            Text(model.storeError ?? "")
        }
    }
}
