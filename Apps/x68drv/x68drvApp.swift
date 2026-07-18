import SwiftUI
import X68Core

@main
struct X68drvApp: App {
    var body: some Scene {
        // Mode A (interactive): settings window on launch.
        // Mode B/C routing lands in later phases (LaunchRouter).
        WindowGroup("x68drv") {
            SettingsView()
        }
        .defaultSize(width: 360, height: 220)

        MenuBarExtra("x68drv", systemImage: "externaldrive.fill") {
            MenuBarView()
        }
    }
}
