import Foundation
import SwiftUI
import AppKit
import X68Core
import os.log

/// Shared application state for settings, launch mode, and mounts.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private let log = Logger(subsystem: "app.x68drv.x68drv", category: "AppModel")
    private let mountService = MountService.shared

    @Published private(set) var launchMode: LaunchMode = .interactive
    @Published var pendingDocumentURLs: [URL] = []
    @Published var lastDocumentMessage: String?
    @Published var lastError: String?

    @Published private(set) var mounts: [MountRecord] = []
    @Published var fuseStatusText: String = ""

    @Published var openAtLogin: Bool = false {
        didSet {
            guard !suppressLoginItemWrite, openAtLogin != oldValue else { return }
            applyLoginItem(enabled: openAtLogin)
        }
    }

    @Published var loginItemStatusText: String = ""
    @Published var loginItemError: String?

    @Published var wantsSettingsWindow: Bool = false

    private var didFinishRouting = false
    private var launchedAsLoginItem = false
    private var suppressLoginItemWrite = false

    private init() {
        launchedAsLoginItem = LaunchRouter.isExplicitLoginLaunch()
        refreshLoginItemState()
        refreshFuseStatus()
        mounts = mountService.mounts
    }

    func finalizeLaunchRouting() {
        guard !didFinishRouting else { return }
        didFinishRouting = true

        if LaunchRouter.isExplicitLoginLaunch() {
            launchedAsLoginItem = true
        } else if LoginItemService.isEnabled && isSparseArgvLaunch() && !NSApp.isActive {
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
            mountPendingDocuments()
        }
    }

    func openSettings() {
        refreshFuseStatus()
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
            mountPendingDocuments()
        }
    }

    func mountPendingDocuments() {
        let urls = pendingDocumentURLs
        pendingDocumentURLs.removeAll()
        for url in urls {
            mount(url: url, revealInFinder: true)
        }
    }

    func mount(url: URL, partitionIndex: Int = 0, revealInFinder: Bool = true) {
        lastError = nil
        do {
            if let existing = mountService.existingMount(for: url, partitionIndex: partitionIndex) {
                lastDocumentMessage = "Already mounted: \(existing.displayName)"
                mounts = mountService.mounts
                if revealInFinder {
                    NSWorkspace.shared.open(existing.mountURL)
                }
                return
            }
            let record = try mountService.mount(url: url, partitionIndex: partitionIndex)
            mounts = mountService.mounts
            switch record.backend {
            case .fuse:
                lastDocumentMessage = "Mounted \(record.displayName) as volume \(record.mountURL.path)"
            case .snapshot:
                lastDocumentMessage = "Opened \(record.displayName) as temporary folder (install FUSE-T for /Volumes mount)"
            }
            log.info("Mounted \(record.displayName, privacy: .public) backend=\(record.backend.rawValue, privacy: .public)")
            if revealInFinder {
                NSWorkspace.shared.open(record.mountURL)
            }
        } catch {
            lastError = error.localizedDescription
            lastDocumentMessage = nil
            log.error("Mount failed: \(error.localizedDescription, privacy: .public)")
            presentMountError(error, url: url)
        }
    }

    func eject(id: UUID) {
        do {
            try mountService.eject(id: id)
            mounts = mountService.mounts
            lastDocumentMessage = "Ejected"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func ejectAll() {
        do {
            try mountService.ejectAll()
            mounts = mountService.mounts
        } catch {
            lastError = error.localizedDescription
            mounts = mountService.mounts
        }
    }

    func revealInFinder(id: UUID) {
        guard let record = mounts.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(record.mountURL)
    }

    func refreshFuseStatus() {
        let helper = mountService.helperExecutable()?.path ?? "helper not built (swift build --product x68mount-helper)"
        switch mountService.fuseStatus() {
        case let .available(detail):
            fuseStatusText = "FUSE: available (\(detail)); helper: \(helper)"
        case let .unavailable(reason):
            fuseStatusText = "FUSE: not installed — temporary folders. \(reason)"
        }
    }

    private func presentMountError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Could not open \(url.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if case .unavailable = mountService.fuseStatus() {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "FUSE-T Website")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(FuseAvailability.fuseTInstallURL)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
