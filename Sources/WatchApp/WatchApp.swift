import AppKit
import SwiftUI

// the Mac app shell, see md/APP.md. run with `swift run WatchApp` as the normal user

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // needed when launched from `swift run`: there is no app bundle to make it a regular app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Watch") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 560)
        }
    }
}
