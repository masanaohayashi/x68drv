import AppKit
import SwiftUI
import os.log

/// Handles document open and single-instance style routing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "tokyo.studio-r.x68drv", category: "AppDelegate")

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Eject FUSE volumes + delete snapshot folders before process exit.
        // Force-quit (SIGKILL) skips this — orphans are cleaned on next launch.
        Task { @MainActor in
            AppModel.shared.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders if ShouldTerminate path was skipped.
        Task { @MainActor in
            AppModel.shared.prepareForTermination()
        }
    }
}
