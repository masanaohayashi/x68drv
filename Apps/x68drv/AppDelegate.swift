import AppKit
import SwiftUI
import os.log

/// Handles document open and single-instance style routing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.x68drv.x68drv", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allow .onOpenURL / open-file events to queue first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AppModel.shared.finalizeLaunchRouting()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("application open \(urls.count) urls")
        Task { @MainActor in
            AppModel.shared.handleOpenDocuments(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click while running → show settings (Mode A behavior).
        Task { @MainActor in
            AppModel.shared.openSettings()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app stays alive after settings OK.
        false
    }
}
