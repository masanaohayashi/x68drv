import SwiftUI
import AppKit

/// Menu bar content (PRD-4). Mount list arrives in Phase 6.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Keeps settings window presentation hooked while menu bar is alive.
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

        Text("No mounted images")
            .disabled(true)

        if let msg = model.lastDocumentMessage {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }

        Divider()

        Button("Quit x68drv") {
            NSApp.terminate(nil)
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose X68000 disk images (.xdf, .hds, .hdf, .dim)"
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                model.handleOpenDocuments(panel.urls)
            }
        }
    }
}
