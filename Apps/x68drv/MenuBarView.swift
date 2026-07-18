import SwiftUI
import AppKit
import X68Core

/// Menu bar content (PRD-4 + Phase 6 mounts).
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsWindowPresenter()
            .environmentObject(model)

        Button("Settings…") {
            model.openSettings()
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Open Image…") {
            presentOpenPanel()
        }

        Divider()

        if model.mounts.isEmpty {
            Text("No mounted images")
                .disabled(true)
        } else {
            ForEach(model.mounts) { mount in
                Menu(mount.displayName) {
                    Button("Show in Finder") {
                        model.revealInFinder(id: mount.id)
                    }
                    Button("Eject") {
                        model.eject(id: mount.id)
                    }
                    Text(mount.backend == .snapshot ? "Temporary folder" : "FUSE")
                        .disabled(true)
                }
            }
            if model.mounts.count > 1 {
                Button("Eject All") {
                    model.ejectAll()
                }
            }
        }

        if let msg = model.lastDocumentMessage {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        if let err = model.lastError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }

        Divider()

        Button("Quit x68drv") {
            model.ejectAll()
            NSApp.terminate(nil)
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose X68000 disk images (.xdf, .hds, .hdf, .dim)"
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    model.mount(url: url, revealInFinder: true)
                }
            }
        }
    }
}
