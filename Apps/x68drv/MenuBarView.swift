import SwiftUI
import AppKit

/// Menu bar content (PRD-4 skeleton). Mount list arrives in Phase 6.
struct MenuBarView: View {
    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            // Bring the settings window forward if present.
            if let window = NSApp.windows.first(where: { $0.title == "x68drv" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                // Fallback: open a new settings window via open.
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }

        Divider()

        Text("No mounted images")
            .disabled(true)

        Divider()

        Button("Quit x68drv") {
            NSApp.terminate(nil)
        }
    }
}
