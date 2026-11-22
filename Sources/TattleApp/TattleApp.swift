import AppKit
import Storage
import SwiftUI

// the Mac app shell, see md/APP.md. run with `swift run TattleApp` as the normal user

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // needed when launched from `swift run`: there is no app bundle to make it a regular app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TattleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(AppIdentity.name) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 560)
        }
    }
}
