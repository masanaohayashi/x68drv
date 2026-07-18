import Foundation
import SwiftUI
import AppKit
import X68Core
import os.log

/// Shared application state for settings, launch mode, and (later) mounts.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private let log = Logger(subsystem: "app.x68drv.x68drv", category: "AppModel")

    @Published private(set) var launchMode: LaunchMode = .interactive
    @Published var pendingDocumentURLs: [URL] = []
    @Published var lastDocumentMessage: String?

    @Published var openAtLogin: Bool = false {
        didSet {
            guard !suppressLoginItemWrite, openAtLogin != oldValue else { return }
            applyLoginItem(enabled: openAtLogin)
        }
    }

    @Published var loginItemStatusText: String = ""
    @Published var loginItemError: String?

    /// When true, the settings window should be visible (Mode A or user request).
    @Published var wantsSettingsWindow: Bool = false

    private var didFinishRouting = false
    private var launchedAsLoginItem = false
    private var suppressLoginItemWrite = false

    private init() {
        launchedAsLoginItem = LaunchRouter.isExplicitLoginLaunch()
        refreshLoginItemState()
    }

    /// Call once after launch once document open events have had a chance to arrive.
    func finalizeLaunchRouting() {
        guard !didFinishRouting else { return }
        didFinishRouting = true

        if LaunchRouter.isExplicitLoginLaunch() {
            launchedAsLoginItem = true
        } else if LoginItemService.isEnabled && isSparseArgvLaunch() && !NSApp.isActive {
            // Heuristic: login items often start without user activation.
            launchedAsLoginItem = true
        }

        launchMode = LaunchRouter.mode(
            launchedAsLoginItem: launchedAsLoginItem,
            documentURLs: pendingDocumentURLs
        )
        log.info("Launch mode=\(self.launchMode.rawValue, privacy: .public) docs=\(self.pendingDocumentURLs.count)")

        switch launchMode {
        case .interactive:
            wantsSettingsWindow = true
        case .silent:
            wantsSettingsWindow = false
        case .document:
            wantsSettingsWindow = false
            handlePendingDocumentsStub()
        }
    }

    func openSettings() {
        wantsSettingsWindow = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSettings() {
        wantsSettingsWindow = false
    }

    func handleOpenDocuments(_ urls: [URL]) {
        let diskURLs = urls.filter { isDiskImage($0) }
        guard !diskURLs.isEmpty else { return }
        pendingDocumentURLs.append(contentsOf: diskURLs)
        if didFinishRouting {
            launchMode = .document
            handlePendingDocumentsStub()
        }
    }

    private func handlePendingDocumentsStub() {
        let names = pendingDocumentURLs.map(\.lastPathComponent).joined(separator: ", ")
        lastDocumentMessage = "Open requested (mount in Phase 6): \(names)"
        log.info("Document open stub: \(names, privacy: .public)")
    }

    private func isDiskImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["xdf", "hds", "hdf", "dim"].contains(ext)
    }

    private func isSparseArgvLaunch() -> Bool {
        ProcessInfo.processInfo.arguments.count <= 2
    }

    func refreshLoginItemState() {
        suppressLoginItemWrite = true
        openAtLogin = LoginItemService.isEnabled
        suppressLoginItemWrite = false
        loginItemStatusText = LoginItemService.statusDescription
    }

    private func applyLoginItem(enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        suppressLoginItemWrite = true
        openAtLogin = LoginItemService.isEnabled
        suppressLoginItemWrite = false
        loginItemStatusText = LoginItemService.statusDescription
    }
}
