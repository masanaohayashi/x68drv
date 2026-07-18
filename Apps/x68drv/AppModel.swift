import Foundation
import SwiftUI
import AppKit
import X68Core
import os.log

/// Shared application state for settings, launch mode, and mounts.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private let log = Logger(subsystem: "tokyo.studio-r.x68drv", category: "AppModel")
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

    /// Settings: opt-in experimental FUSE write (HDS/HDF). Default off.
    @Published var experimentalWriteMount: Bool {
        didSet {
            UserDefaults.standard.set(experimentalWriteMount, forKey: Self.experimentalWriteKey)
        }
    }

    @Published var loginItemStatusText: String = ""
    @Published var loginItemError: String?

    @Published var wantsSettingsWindow: Bool = false

    private static let experimentalWriteKey = "experimentalWriteMount"

    private var didFinishRouting = false
    private var launchedAsLoginItem = false
    private var suppressLoginItemWrite = false

    private init() {
        experimentalWriteMount = UserDefaults.standard.bool(forKey: Self.experimentalWriteKey)
        launchedAsLoginItem = LaunchRouter.isExplicitLoginLaunch()
        // Previous crash / force-quit / quit-without-eject can leave FUSE mounts
        // and snapshot folders under Application Support — reclaim before UI work.
        let cleaned = mountService.reclaimOrphans()
        if cleaned > 0 {
            log.info("Reclaimed \(cleaned) orphan mount leftover(s)")
        }
        refreshLoginItemState()
        refreshFuseStatus()
        mounts = mountService.mounts
    }

    /// Called on normal app quit (Quit menu, terminate, logout when allowed).
    func prepareForTermination() {
        do {
            try mountService.ejectAll()
            mounts = []
        } catch {
            log.error("ejectAll on quit: \(error.localizedDescription, privacy: .public)")
            // Still try a full reclaim so disks don't stay mounted.
            _ = mountService.reclaimOrphans()
            mounts = []
        }
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
            let record = try mountService.mount(
                url: url,
                partitionIndex: partitionIndex,
                experimentalWrite: experimentalWriteMount
            )
            mounts = mountService.mounts
            switch (record.backend, record.experimentalWrite) {
            case (.fuse, true):
                lastDocumentMessage =
                    "Mounted \(record.displayName) writable (experimental) — image is modified; backup .x68drv-bak"
            case (.fuse, false) where experimentalWriteMount:
                lastDocumentMessage =
                    "Mounted \(record.displayName) read-only (write not available for this format)"
            case (.fuse, false):
                lastDocumentMessage = "Mounted \(record.displayName) as live volume (read-only)"
            case (.snapshot, _):
                lastDocumentMessage =
                    "Opened \(record.displayName) as temporary folder (install FUSE-T + rebuild for live volume)"
            }
            log.info(
                "Mounted \(record.displayName, privacy: .public) backend=\(record.backend.rawValue, privacy: .public) write=\(record.experimentalWrite)"
            )
            if revealInFinder {
                NSWorkspace.shared.open(record.mountURL)
            }
        } catch {
            let msg = Self.errorMessage(error)
            lastError = msg
            lastDocumentMessage = nil
            log.error("Mount failed: \(msg, privacy: .public)")
            presentMountError(error, url: url)
        }
    }

    func eject(id: UUID) {
        lastError = nil
        lastDocumentMessage = "Ejecting…"
        // Detach immediately in the service; run slow umount/kill off the main thread
        // so the menu bar does not freeze (looked like "cannot eject").
        let service = mountService
        Task.detached(priority: .userInitiated) {
            do {
                try service.eject(id: id)
                await MainActor.run {
                    self.mounts = service.mounts
                    self.lastDocumentMessage = "Ejected"
                    self.lastError = nil
                }
            } catch {
                let msg = Self.errorMessage(error)
                await MainActor.run {
                    self.mounts = service.mounts
                    self.lastError = msg
                    self.lastDocumentMessage = nil
                }
            }
        }
    }

    func ejectAll() {
        lastError = nil
        lastDocumentMessage = "Ejecting all…"
        let service = mountService
        Task.detached(priority: .userInitiated) {
            do {
                try service.ejectAll()
            } catch {
                // ejectAll is best-effort; still refresh UI
            }
            // Also reclaim any stuck NFS leftovers Finder left behind.
            _ = service.reclaimOrphans()
            await MainActor.run {
                self.mounts = service.mounts
                self.lastDocumentMessage = "Ejected"
                self.lastError = nil
            }
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
        alert.informativeText = Self.errorMessage(error)
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

    nonisolated private static func errorMessage(_ error: Error) -> String {
        if let e = error as? X68Error { return e.message }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
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
